#!/usr/bin/env bash
set -euo pipefail
umask 077

environment="octelium-rscstore-backup"
target="homelab.$environment"
repository="Stuhlmuller/homelab"
policy="$PWD/octelium-backup-environment-policy.jq"
plan_file="$RUNNER_TEMP/octelium-backup-environment.tfplan"

verify_main() {
  [[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]]
  test "$GITHUB_REPOSITORY" = Stuhlmuller/github-iac
  test "$GITHUB_REF" = refs/heads/main
  test "$GITHUB_SHA" = "$EXPECTED_SHA"
  test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"
  git fetch --no-tags --depth=1 origin main
  test "$(git rev-parse FETCH_HEAD)" = "$EXPECTED_SHA"
}

plan_state() {
  terragrunt show -json "$plan_file" | jq -ceS --arg source plan --arg phase "$1" -f "$policy"
}

live_state() {
  local live_environment policies
  live_environment="$(
    gh api --paginate --slurp "repos/$repository/environments?per_page=100" |
      jq -c --arg name "$environment" '
        [.[].environments[] | select(.name == $name)]
        | if length <= 1 then .[0] else error("duplicate backup environment") end
      '
  )" || return
  policies='[]'
  if jq -e '. != null' <<<"$live_environment" >/dev/null; then
    policies="$(
      gh api --paginate --slurp "repos/$repository/environments/$environment/deployment-branch-policies?per_page=100" |
        jq -ce '[.[].branch_policies[]]'
    )" || return
  fi
  jq -n --argjson environment "$live_environment" --argjson policies "$policies" \
    '{environment: $environment, policies: $policies}' |
    jq -ceS --arg source live --arg phase "" -f "$policy"
}

verify_live_state() {
  local actual
  actual="$(live_state)" || return
  if [[ "$1" != "$actual" ]]; then
    echo "Live environment differs from the reviewed plan." >&2
    exit 1
  fi
}

verify_main
[[ "$GITHUB_RUN_ID" =~ ^[1-9][0-9]*$ && "$GITHUB_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]
expected_key="IaC/github-iac/saved-plans/octelium-backup-environment/$EXPECTED_SHA/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT/plan.out"

case "$1" in
  plan)
    terragrunt plan -input=false -out="$plan_file" \
      -target="github_repository_environment.this[\"$target\"]" \
      -target="github_repository_environment_deployment_policy.this[\"$target\"]"
    before="$(plan_state before)"
    after="$(plan_state after)"
    verify_live_state "$before"
    if [[ "$before" == "$after" ]]; then
      echo "changed=false" >> "$GITHUB_OUTPUT"
      exit 0
    fi
    plan_sha="$(sha256sum "$plan_file" | cut -d ' ' -f1)"
    version="$(
      aws s3api put-object --bucket "$PLAN_BUCKET" --key "$expected_key" --body "$plan_file" \
        --if-none-match '*' --server-side-encryption aws:kms --ssekms-key-id alias/homelab-opentofu \
        --metadata "commit=$EXPECTED_SHA,run-id=$GITHUB_RUN_ID,sha256=$plan_sha" |
        jq -er '.VersionId | strings | select(length > 0 and . != "null")'
    )"
    {
      echo "changed=true"
      echo "plan_key=$expected_key"
      echo "plan_sha256=$plan_sha"
      echo "plan_version_id=$version"
    } >> "$GITHUB_OUTPUT"
    ;;
  apply)
    test "$PLAN_KEY" = "$expected_key"
    [[ "$PLAN_SHA256" =~ ^[0-9a-f]{64}$ && -n "$PLAN_VERSION_ID" && "$PLAN_VERSION_ID" != null ]]
    aws s3api head-object --bucket "$PLAN_BUCKET" --key "$PLAN_KEY" --version-id "$PLAN_VERSION_ID" |
      jq -e --arg commit "$EXPECTED_SHA" --arg run_id "$GITHUB_RUN_ID" \
        --arg sha256 "$PLAN_SHA256" --arg version "$PLAN_VERSION_ID" '
          .ServerSideEncryption == "aws:kms" and .VersionId == $version
          and .Metadata == {commit: $commit, "run-id": $run_id, sha256: $sha256}
        ' >/dev/null
    aws s3api get-object --bucket "$PLAN_BUCKET" --key "$PLAN_KEY" --version-id "$PLAN_VERSION_ID" \
      "$plan_file" >/dev/null
    printf '%s  %s\n' "$PLAN_SHA256" "$plan_file" | sha256sum --check --status
    before="$(plan_state before)"
    after="$(plan_state after)"
    test "$before" != "$after"
    verify_live_state "$before"
    verify_main
    terragrunt apply "$plan_file"
    verify_live_state "$after"
    aws s3api delete-object --bucket "$PLAN_BUCKET" --key "$PLAN_KEY" --version-id "$PLAN_VERSION_ID" >/dev/null
    aws s3api list-object-versions --bucket "$PLAN_BUCKET" --prefix "$PLAN_KEY" |
      jq -e --arg key "$PLAN_KEY" '
        all(.Versions[]?, .DeleteMarkers[]?; .Key != $key)
      ' >/dev/null
    echo "Verified the octelium-rscstore-backup environment and its exact main branch policy."
    ;;
  *) exit 2 ;;
esac
