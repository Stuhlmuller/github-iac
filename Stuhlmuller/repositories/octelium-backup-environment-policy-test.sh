#!/usr/bin/env bash
set -euo pipefail

policy="$(dirname "$0")/octelium-backup-environment-policy.jq"
environment='{"name":"octelium-rscstore-backup","can_admins_bypass":false,"protection_rules":[],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
env_state='{"repository":"homelab","environment":"octelium-rscstore-backup","can_admins_bypass":false,"prevent_self_review":false,"wait_timer":0,"reviewers":[],"deployment_branch_policy":[{"protected_branches":false,"custom_branch_policies":true}]}'
branch_state='{"repository":"homelab","environment":"octelium-rscstore-backup","branch_pattern":"main","tag_pattern":null}'
env_address='github_repository_environment.this["homelab.octelium-rscstore-backup"]'
branch_address='github_repository_environment_deployment_policy.this["homelab.octelium-rscstore-backup"]'
plan="$(jq -n --arg env_address "$env_address" --arg branch_address "$branch_address" \
  --argjson environment "$env_state" --argjson branch "$branch_state" '
    def create($address; $type; $value):
      {address:$address, mode:"managed", type:$type, change:{actions:["create"], before:null, after:$value}};
    {resource_changes:[
      create($env_address; "github_repository_environment"; $environment),
      create($branch_address; "github_repository_environment_deployment_policy"; $branch)
    ]}
  ')"

verify_plan() {
  jq -ceS --arg source plan --arg phase "$1" -f "$policy"
}

verify_live() {
  jq -ceS --arg source live --arg phase "" -f "$policy"
}

[[ "$(verify_plan before <<<"$plan")" == '{"branch_policy":false,"environment":false}' ]]
[[ "$(verify_plan after <<<"$plan")" == '{"branch_policy":true,"environment":true}' ]]
existing_environment="$(jq '.resource_changes[0].change |= (.actions = ["no-op"] | .before = .after)' <<<"$plan")"
[[ "$(verify_plan before <<<"$existing_environment")" == '{"branch_policy":false,"environment":true}' ]]
[[ "$(verify_plan after <<<"$existing_environment")" == '{"branch_policy":true,"environment":true}' ]]
no_op="$(jq '.resource_changes[].change |= (.actions = ["no-op"] | .before = .after)' <<<"$plan")"
[[ "$(verify_plan before <<<"$no_op")" == "$(verify_plan after <<<"$no_op")" ]]

for change in \
  '.resource_changes += [{mode:"managed", address:"another.resource", change:{actions:["create"]}}]' \
  '.resource_changes[0].change.actions = ["update"]' \
  '.resource_changes[0].change.actions = ["delete","create"]' \
  '.resource_changes[0].change.importing.id = "homelab:octelium-rscstore-backup"' \
  '.resource_changes[0].previous_address = "other.resource"' \
  '.resource_changes[0].change.after.can_admins_bypass = true' \
  '.resource_changes[0].change.after.deployment_branch_policy[0].protected_branches = true' \
  '.resource_changes[1].change.after.branch_pattern = "*"' \
  '.resource_changes[1].change.after.tag_pattern = "main"'
do
  if jq "$change" <<<"$plan" | verify_plan after >/dev/null 2>&1; then
    echo "Accepted forbidden plan change: $change" >&2
    exit 1
  fi
done

[[ "$(verify_live <<<'{"environment":null,"policies":[]}')" == '{"branch_policy":false,"environment":false}' ]]
[[ "$(verify_live <<<"{\"environment\":$environment,\"policies\":[]}")" == '{"branch_policy":false,"environment":true}' ]]
live="{\"environment\":$environment,\"policies\":[{\"name\":\"main\",\"type\":\"branch\"}]}"
[[ "$(verify_live <<<"$live")" == '{"branch_policy":true,"environment":true}' ]]
for change in \
  '.environment.can_admins_bypass = true' \
  '.environment.protection_rules = [{type:"wait_timer"}]' \
  '.policies += [{name:"next",type:"branch"}]' \
  '.policies[0].type = "tag"'
do
  if jq "$change" <<<"$live" | verify_live >/dev/null 2>&1; then
    echo "Accepted forbidden live settings: $change" >&2
    exit 1
  fi
done

echo "Octelium backup environment plan and live policy fixtures passed."
