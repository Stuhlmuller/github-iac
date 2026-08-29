#!/usr/bin/env bash
set -euo pipefail

mode="${1:---check}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
organization="Stuhlmuller"
repositories=("homelab" "github-iac")
configuration_name="Public Control Plane Protection"
rollback_configuration_name="Public Protection"
release_ruleset_name="public-release-tags"
api_version="2026-03-10"
actions_retention_days=1

case "$mode" in
  --apply | --check | --rollback | --self-test) ;;
  *)
    echo "usage: $0 [--check|--apply|--rollback|--self-test]" >&2
    exit 2
    ;;
esac

required_commands=(jq)
if [[ "$mode" != "--self-test" ]]; then
  required_commands+=(gh)
fi
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required" >&2
    exit 1
  }
done
repositories_json="$(jq -cn --args '$ARGS.positional' "${repositories[@]}")"
allowed_action_patterns="$(jq -ce . "$script_dir/allowed-actions.json")"

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
    description: "Enforced public control-plane security with dependency alerts and Renovate-owned updates.",
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
    private_vulnerability_reporting: "enabled",
    enforcement: "enforced"
  }'
)"

require_release_ruleset() {
  jq -e --arg name "$release_ruleset_name" --argjson repositories "$repositories_json" '
    .name == $name
    and .target == "tag"
    and .enforcement == "active"
    and (.bypass_actors // []) == []
    and (.conditions.ref_name.include | sort) == ["~ALL"]
    and (.conditions.ref_name.exclude // []) == []
    and (.conditions.repository_name.include | sort) == ($repositories | sort)
    and (.conditions.repository_name.exclude // []) == []
    and ([.rules[].type] | sort) == (["deletion", "update"] | sort)
  ' >/dev/null
}

verify_release_ruleset() {
  local matches=""
  local ruleset_id=""

  matches="$(
    github_api --method GET "orgs/$organization/rulesets" -f per_page=100 |
      jq -c --arg name "$release_ruleset_name" '[.[] | select(.name == $name)]'
  )"
  if [[ "$(jq length <<<"$matches")" -ne 1 ]]; then
    echo "expected one $release_ruleset_name organization ruleset" >&2
    return 1
  fi

  ruleset_id="$(jq -r '.[0].id' <<<"$matches")"
  github_api "orgs/$organization/rulesets/$ruleset_id" |
    require_release_ruleset
}

reconcile_immutable_releases() {
  local repository="$1"
  local immutable=""

  immutable="$(
    github_api "repos/$organization/$repository/immutable-releases" 2>/dev/null || true
  )"
  if ! jq -e '.enabled == true' <<<"$immutable" >/dev/null 2>&1 &&
    [[ "$mode" == "--apply" ]]; then
    github_api --method PUT \
      "repos/$organization/$repository/immutable-releases" >/dev/null || {
      echo "failed to enable immutable releases on $organization/$repository" >&2
      return 1
    }
    immutable="$(
      github_api "repos/$organization/$repository/immutable-releases" 2>/dev/null || true
    )"
  fi

  jq -e '.enabled == true' <<<"$immutable" >/dev/null || {
    echo "$organization/$repository immutable releases are not enabled" >&2
    return 1
  }
}

assert_ruleset_rejected() {
  local message="$1"

  if verify_release_ruleset >/dev/null 2>&1; then
    echo "$message unexpectedly passed" >&2
    exit 1
  fi
}

self_test_release_ruleset() {
  local valid=""
  local invalid=""

  valid="$(jq -cn --arg name "$release_ruleset_name" \
    --argjson repositories "$repositories_json" '{
      id: 123,
      name: $name,
      target: "tag",
      enforcement: "active",
      bypass_actors: [],
      conditions: {
        repository_name: {include: $repositories, exclude: []},
        ref_name: {include: ["~ALL"], exclude: []}
      },
      rules: [{type: "deletion"}, {type: "update"}]
    }')"
  mock_ruleset_list='[{"id":123,"name":"public-release-tags"}]'
  mock_ruleset_detail="$valid"
  mock_immutable_before='{"enabled":true,"enforced_by_owner":true}'
  mock_immutable_after='{"enabled":true}'
  mock_immutable_puts=0
  mock_immutable_put_fails=false
  github_api() {
    if [[ "$*" == *"orgs/$organization/rulesets/123"* ]]; then
      printf '%s\n' "$mock_ruleset_detail"
    elif [[ "$*" == *"orgs/$organization/rulesets"* ]]; then
      printf '%s\n' "$mock_ruleset_list"
    elif [[ "$*" == *"/immutable-releases"* && "$*" == *"--method PUT"* ]]; then
      [[ "$mock_immutable_put_fails" == false ]] || return 1
      ((mock_immutable_puts += 1))
    elif [[ "$*" == *"/immutable-releases"* ]]; then
      if [[ "$mock_immutable_puts" -gt 0 ]]; then
        printf '%s\n' "$mock_immutable_after"
      else
        printf '%s\n' "$mock_immutable_before"
      fi
    else
      echo "unexpected mock API call: $*" >&2
      return 1
    fi
  }

  verify_release_ruleset
  mock_ruleset_list='[{"id":123,"name":"public-release-tags"},{"id":456,"name":"public-release-tags"}]'
  assert_ruleset_rejected "duplicate ruleset fixture"
  mock_ruleset_list='[{"id":123,"name":"public-release-tags"}]'
  for invalid in \
    "$(jq '.rules += [{type: "creation"}]' <<<"$valid")" \
    "$(jq '.bypass_actors = [{actor_id: 1}]' <<<"$valid")" \
    "$(jq '.conditions.repository_name.include = ["homelab"]' <<<"$valid")" \
    "$(jq '.conditions.ref_name.include = ["refs/tags/v*"]' <<<"$valid")" \
    "$(jq '.enforcement = "evaluate"' <<<"$valid")"; do
    mock_ruleset_detail="$invalid"
    assert_ruleset_rejected "invalid ruleset fixture"
  done

  mode=--check
  mock_ruleset_detail="$valid"
  reconcile_immutable_releases homelab
  [[ "$mock_immutable_puts" -eq 0 ]]
  mock_immutable_before='{"enabled":false}'
  if reconcile_immutable_releases homelab >/dev/null 2>&1; then
    echo "disabled immutable-release fixture unexpectedly passed" >&2
    exit 1
  fi
  mock_immutable_before=''
  if reconcile_immutable_releases homelab >/dev/null 2>&1; then
    echo "missing immutable-release fixture unexpectedly passed" >&2
    exit 1
  fi
  mode=--apply
  mock_immutable_before='{"enabled":false}'
  reconcile_immutable_releases homelab
  [[ "$mock_immutable_puts" -eq 1 ]]
  mock_immutable_before='{"enabled":false}'
  mock_immutable_puts=0
  mock_immutable_put_fails=true
  if reconcile_immutable_releases homelab >/dev/null 2>&1; then
    echo "failed immutable-release PUT unexpectedly passed" >&2
    exit 1
  fi
}

if [[ "$mode" == "--self-test" ]]; then
  self_test_release_ruleset
  echo "public control-plane security reconciler self-test passed"
  exit 0
fi

if [[ "$mode" != "--rollback" ]]; then
  verify_release_ruleset
fi

configurations="$(
  github_api --method GET \
    "orgs/$organization/code-security/configurations" -f per_page=100
)"
attach_arguments=()
for repository in "${repositories[@]}"; do
  repository_id="$(github_api "repos/$organization/$repository" --jq .id)"
  attach_arguments+=(-F "selected_repository_ids[]=$repository_id")

  current_configuration_name="$(
    github_api "repos/$organization/$repository/code-security-configuration" |
      jq -r '.configuration.name // empty'
  )"
  if [[ "$current_configuration_name" != "$configuration_name" &&
    "$current_configuration_name" != "$rollback_configuration_name" ]]; then
    echo "refusing to replace unexpected configuration on $organization/$repository: $current_configuration_name" >&2
    exit 1
  fi
done

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

require_effective_secret_protection() {
  jq -e '
    .visibility == "public"
    and .security_and_analysis.secret_scanning.status == "enabled"
    and .security_and_analysis.secret_scanning_push_protection.status == "enabled"
  ' >/dev/null
}

wait_for_configuration() {
  local repository="$1"
  local expected_id="$2"
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

  echo "timed out waiting for $organization/$repository security configuration $expected_id" >&2
  return 1
}

wait_for_effective_secret_protection() {
  local repository="$1"
  local repository_security=""

  for ((attempt = 1; attempt <= 30; attempt++)); do
    repository_security="$(github_api "repos/$organization/$repository" 2>/dev/null || true)"
    if require_effective_secret_protection <<<"$repository_security" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "$organization/$repository effective secret protection did not become ready" >&2
  return 1
}

verify_configuration_scope() {
  local configuration_id="$1"

  github_api --method GET \
    "orgs/$organization/code-security/configurations/$configuration_id/repositories" \
    -f per_page=100 |
    jq -e --argjson expected "$repositories_json" '
      ([.[] | (.repository.name // .repository.value.name)] | sort) == ($expected | sort)
      and all(.[]; .status == "enforced")
    ' >/dev/null
}

wait_for_effective_security() {
  local repository="$1"
  local repository_security=""
  local private_vulnerability_reporting=""
  local default_codeql_setup=""
  local code_scanning_alerts=""
  local dependabot_alerts=""
  local sbom=""

  for ((attempt = 1; attempt <= 30; attempt++)); do
    if repository_security="$(github_api "repos/$organization/$repository" 2>/dev/null)" &&
      require_effective_secret_protection <<<"$repository_security" >/dev/null 2>&1 &&
      jq -e '
        .security_and_analysis.secret_scanning_non_provider_patterns.status == "enabled"
        and .security_and_analysis.secret_scanning_validity_checks.status == "enabled"
      ' <<<"$repository_security" >/dev/null 2>&1 &&
      private_vulnerability_reporting="$(
        github_api "repos/$organization/$repository/private-vulnerability-reporting" 2>/dev/null
      )" &&
      jq -e '.enabled == true' <<<"$private_vulnerability_reporting" >/dev/null 2>&1 &&
      default_codeql_setup="$(
        github_api "repos/$organization/$repository/code-scanning/default-setup" 2>/dev/null
      )" &&
      jq -e '.state == "not-configured"' <<<"$default_codeql_setup" >/dev/null 2>&1 &&
      code_scanning_alerts="$(
        github_api --method GET \
          "repos/$organization/$repository/code-scanning/alerts" \
          -f per_page=1 2>/dev/null
      )" &&
      jq -e 'type == "array"' <<<"$code_scanning_alerts" >/dev/null 2>&1 &&
      dependabot_alerts="$(
        github_api --method GET \
          "repos/$organization/$repository/dependabot/alerts" \
          -f per_page=1 2>/dev/null
      )" &&
      jq -e 'type == "array"' <<<"$dependabot_alerts" >/dev/null 2>&1 &&
      sbom="$(
        github_api "repos/$organization/$repository/dependency-graph/sbom" 2>/dev/null
      )" &&
      jq -e '.sbom != null' <<<"$sbom" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "$organization/$repository effective security controls did not become ready" >&2
  return 1
}

reconcile_actions() {
  local repository="$1"
  local patterns=""
  local desired_selected_actions=""

  patterns="$(
    jq -ce --arg repository "$repository" '.[$repository]' <<<"$allowed_action_patterns"
  )"
  desired_selected_actions="$(
    jq -cn --argjson patterns "$patterns" \
      '{github_owned_allowed: false, verified_allowed: false, patterns_allowed: $patterns}'
  )"

  if [[ "$mode" == "--apply" ]]; then
    github_api --method PUT \
      "repos/$organization/$repository/actions/permissions" \
      -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true >/dev/null
    printf '%s\n' "$desired_selected_actions" |
      github_api --method PUT \
        "repos/$organization/$repository/actions/permissions/selected-actions" \
        --input - >/dev/null
    github_api --method PUT \
      "repos/$organization/$repository/actions/permissions/workflow" \
      -f default_workflow_permissions=read \
      -F can_approve_pull_request_reviews=false >/dev/null
    github_api --method PUT \
      "repos/$organization/$repository/actions/permissions/fork-pr-contributor-approval" \
      -f approval_policy=all_external_contributors >/dev/null
    github_api --method PUT \
      "repos/$organization/$repository/actions/permissions/artifact-and-log-retention" \
      -F days="$actions_retention_days" >/dev/null
  fi

  github_api "repos/$organization/$repository/actions/permissions" |
    jq -e '
      .enabled == true
      and .allowed_actions == "selected"
      and .sha_pinning_required == true
    ' >/dev/null
  github_api "repos/$organization/$repository/actions/permissions/selected-actions" |
    jq -e --argjson desired "$desired_selected_actions" '
      .github_owned_allowed == $desired.github_owned_allowed
      and .verified_allowed == $desired.verified_allowed
      and ((.patterns_allowed // []) | sort) == ($desired.patterns_allowed | sort)
    ' >/dev/null
  github_api "repos/$organization/$repository/actions/permissions/workflow" |
    jq -e '
      .default_workflow_permissions == "read"
      and .can_approve_pull_request_reviews == false
    ' >/dev/null
  github_api "repos/$organization/$repository/actions/permissions/fork-pr-contributor-approval" |
    jq -e '.approval_policy == "all_external_contributors"' >/dev/null
  github_api \
    "repos/$organization/$repository/actions/permissions/artifact-and-log-retention" |
    jq -e --argjson days "$actions_retention_days" '.days == $days' >/dev/null
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
    -f scope=selected "${attach_arguments[@]}" >/dev/null
  for repository in "${repositories[@]}"; do
    live_configuration="$(wait_for_configuration "$repository" "$rollback_id")"
    require_secret_protection <<<"$(jq -c .configuration <<<"$live_configuration")" || {
      echo "$rollback_configuration_name attached to $organization/$repository without enforced secret protection" >&2
      exit 1
    }
    wait_for_effective_secret_protection "$repository"
  done
  echo "$organization public control-plane repositories restored to $rollback_configuration_name ($rollback_id)"
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
      jq -e --argjson expected "$repositories_json" '
        all(.[]; (.repository.name // .repository.value.name) as $name
          | ($expected | index($name)) != null)
      ' >/dev/null || {
        echo "$configuration_name is attached outside the public control-plane repositories" >&2
        exit 1
      }
    printf '%s\n' "$desired_configuration" |
      github_api --method PATCH \
        "orgs/$organization/code-security/configurations/$configuration_id" \
        --input - >/dev/null
  fi

  github_api --method POST \
    "orgs/$organization/code-security/configurations/$configuration_id/attach" \
    -f scope=selected "${attach_arguments[@]}" >/dev/null
fi

for repository in "${repositories[@]}"; do
  live_configuration="$(wait_for_configuration "$repository" "$configuration_id")"
  jq -e --argjson desired "$desired_configuration" '
    .configuration.target_type == "organization"
    and (.configuration as $actual
      | all($desired | to_entries[]; $actual[.key] == .value))
  ' <<<"$live_configuration" >/dev/null
done
verify_configuration_scope "$configuration_id"

for repository in "${repositories[@]}"; do
  reconcile_actions "$repository"
  reconcile_immutable_releases "$repository"
  wait_for_effective_security "$repository"

  open_alert_count="$(
    github_api --method GET --paginate --slurp \
      "repos/$organization/$repository/dependabot/alerts" \
      -f state=open -f per_page=100 |
      jq 'add // [] | length'
  )"
  if [[ "$open_alert_count" -gt 0 ]]; then
    echo "$organization/$repository has $open_alert_count open Dependabot alert(s)" >&2
    exit 1
  fi
done

echo "$organization public control-plane repositories use $configuration_name ($configuration_id); release tags are protected and future releases are immutable; Actions are restricted; no open Dependabot alerts"
