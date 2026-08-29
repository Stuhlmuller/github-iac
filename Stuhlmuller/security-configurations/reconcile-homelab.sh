#!/usr/bin/env bash
set -euo pipefail

mode="${1:---check}"
organization="Stuhlmuller"
repository="homelab"
configuration_name="Homelab Protection"
rollback_configuration_name="Public Protection"
api_version="2026-03-10"

case "$mode" in
  --apply | --check | --rollback) ;;
  *)
    echo "usage: $0 [--check|--apply|--rollback]" >&2
    exit 2
    ;;
esac

for command_name in gh jq; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required" >&2
    exit 1
  }
done

github_api() {
  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: $api_version" \
    "$@"
}

desired_configuration="$(jq -n \
  --arg name "$configuration_name" \
  '{
    name: $name,
    description: "Enforced homelab security with dependency alerts and Renovate-owned updates.",
    advanced_security: "enabled",
    dependency_graph: "enabled",
    dependency_graph_autosubmit_action: "disabled",
    dependabot_alerts: "enabled",
    dependabot_security_updates: "disabled",
    dependabot_delegated_alert_dismissal: "disabled",
    code_scanning_default_setup: "disabled",
    code_scanning_delegated_alert_dismissal: "not_set",
    secret_scanning: "enabled",
    secret_scanning_push_protection: "enabled",
    secret_scanning_delegated_bypass: "not_set",
    secret_scanning_non_provider_patterns: "enabled",
    secret_scanning_delegated_alert_dismissal: "not_set",
    secret_scanning_validity_checks: "enabled",
    secret_scanning_extended_metadata: "enabled",
    secret_scanning_generic_secrets: "not_set",
    private_vulnerability_reporting: "disabled",
    enforcement: "enforced"
  }'
)"

configurations="$(
  github_api --method GET \
    "orgs/$organization/code-security/configurations" -f per_page=100
)"
repository_id="$(github_api "repos/$organization/$repository" --jq .id)"
current_repository_configuration="$(
  github_api "repos/$organization/$repository/code-security-configuration"
)"
current_configuration_name="$(
  jq -r '.configuration.name // empty' <<<"$current_repository_configuration"
)"
if [[ "$current_configuration_name" != "$configuration_name" &&
  "$current_configuration_name" != "$rollback_configuration_name" ]]; then
  echo "refusing to replace unexpected configuration: $current_configuration_name" >&2
  exit 1
fi

configuration_for_name() {
  local name="$1"
  local count

  count="$(jq --arg name "$name" \
    '[.[] | select(.name == $name and .target_type == "organization")] | length' \
    <<<"$configurations")"
  if [[ "$count" -ne 1 ]]; then
    echo "expected one organization $name configuration, found $count" >&2
    return 1
  fi
  jq -c --arg name "$name" \
    '.[] | select(.name == $name and .target_type == "organization")' \
    <<<"$configurations"
}

require_secret_protection() {
  jq -e '
    .target_type == "organization"
    and .enforcement == "enforced"
    and .secret_scanning == "enabled"
    and .secret_scanning_push_protection == "enabled"
  ' >/dev/null
}

wait_for_configuration() {
  local expected_id="$1"
  local live=""

  for ((attempt = 1; attempt <= 30; attempt++)); do
    live="$(github_api "repos/$organization/$repository/code-security-configuration" 2>/dev/null || true)"
    if jq -e --argjson expected_id "$expected_id" \
      '.status == "enforced" and .configuration.id == $expected_id' \
      <<<"$live" >/dev/null 2>&1; then
      printf '%s\n' "$live"
      return 0
    fi
    sleep 2
  done

  echo "timed out waiting for repository security configuration $expected_id" >&2
  return 1
}

if [[ "$mode" == "--rollback" ]]; then
  rollback_configuration="$(configuration_for_name "$rollback_configuration_name")"
  require_secret_protection <<<"$rollback_configuration" || {
    echo "$rollback_configuration_name does not preserve enforced secret protection" >&2
    exit 1
  }
  rollback_id="$(jq -r .id <<<"$rollback_configuration")"
  github_api --method POST \
    "orgs/$organization/code-security/configurations/$rollback_id/attach" \
    -f scope=selected -F "selected_repository_ids[]=$repository_id" >/dev/null
  live_configuration="$(wait_for_configuration "$rollback_id")"
  require_secret_protection <<<"$(jq -c .configuration <<<"$live_configuration")" || {
    echo "$rollback_configuration_name attached without enforced secret protection" >&2
    exit 1
  }
  echo "$organization/$repository restored to $rollback_configuration_name ($rollback_id)"
  exit 0
fi

configuration_matches="$(
  jq --arg name "$configuration_name" \
    '[.[] | select(.name == $name and .target_type == "organization")]' \
    <<<"$configurations"
)"
configuration_count="$(jq length <<<"$configuration_matches")"

if [[ "$mode" == "--check" && "$configuration_count" -ne 1 ]]; then
  echo "expected one $configuration_name configuration, found $configuration_count" >&2
  exit 1
fi
if [[ "$configuration_count" -gt 1 ]]; then
  echo "refusing to reconcile duplicate $configuration_name configurations" >&2
  exit 1
fi

configuration_id="$(jq -r '.[0].id // empty' <<<"$configuration_matches")"
if [[ "$mode" == "--apply" ]]; then
  if [[ -z "$configuration_id" ]]; then
    configuration_id="$(
      printf '%s\n' "$desired_configuration" |
        github_api --method POST \
          "orgs/$organization/code-security/configurations" \
          --input - --jq .id
    )"
  else
    github_api --method GET \
      "orgs/$organization/code-security/configurations/$configuration_id/repositories" \
      -f per_page=100 |
      jq -e --arg repository "$repository" \
        'all(.[]; (.repository.name // .repository.value.name) == $repository)' >/dev/null || {
        echo "$configuration_name is attached outside $organization/$repository" >&2
        exit 1
      }
    printf '%s\n' "$desired_configuration" |
      github_api --method PATCH \
        "orgs/$organization/code-security/configurations/$configuration_id" \
        --input - >/dev/null
  fi

  github_api --method POST \
    "orgs/$organization/code-security/configurations/$configuration_id/attach" \
    -f scope=selected -F "selected_repository_ids[]=$repository_id" >/dev/null
fi

live_configuration="$(wait_for_configuration "$configuration_id")"
jq -e --argjson desired "$desired_configuration" '
  .configuration.target_type == "organization"
  and (.configuration as $actual
    | all($desired | to_entries[]; $actual[.key] == .value))
' <<<"$live_configuration" >/dev/null

github_api --method GET \
  "orgs/$organization/code-security/configurations/$configuration_id/repositories" \
  -f per_page=100 |
  jq -e --arg repository "$repository" '
    length == 1
    and (.[0].repository.name // .[0].repository.value.name) == $repository
    and .[0].status == "enforced"
  ' >/dev/null

dependency_apis_ready=false
for ((attempt = 1; attempt <= 30; attempt++)); do
  if github_api --method GET \
    "repos/$organization/$repository/dependabot/alerts" \
    -f per_page=1 >/dev/null 2>&1 &&
    github_api "repos/$organization/$repository/dependency-graph/sbom" \
      >/dev/null 2>&1; then
    dependency_apis_ready=true
    break
  fi
  sleep 2
done
if [[ "$dependency_apis_ready" != true ]]; then
  echo "dependency alerts or SBOM API did not become available" >&2
  exit 1
fi

open_alerts="$(
  github_api --method GET --paginate --slurp \
    "repos/$organization/$repository/dependabot/alerts" \
    -f state=open -f per_page=100 |
    jq 'add // []'
)"
open_alert_count="$(jq length <<<"$open_alerts")"
if [[ "$open_alert_count" -gt 0 ]]; then
  printf 'number\tecosystem\tpackage\tseverity\tadvisory\tfixed-version\turl\n' >&2
  jq -r '
    .[]
    | [
        (.number | tostring),
        .dependency.package.ecosystem,
        .dependency.package.name,
        .security_advisory.severity,
        .security_advisory.ghsa_id,
        (.security_vulnerability.first_patched_version.identifier // "no-patch"),
        .html_url
      ]
    | @tsv
  ' <<<"$open_alerts" >&2
  echo "$open_alert_count open Dependabot alert(s) require resolution or justified dismissal" >&2
  exit 1
fi

echo "$organization/$repository uses $configuration_name ($configuration_id); no open Dependabot alerts"
