#!/usr/bin/env bash
set -euo pipefail

policy="$(dirname "$0")/homelab-plan-reviewer-policy.jq"
plan="$(jq -cn --arg address 'github_repository_environment.this["homelab.homelab-plan"]' '
  {resource_changes: [{
    address: $address,
    mode: "managed",
    type: "github_repository_environment",
    change: {
      actions: ["update"],
      before: {
        id: "homelab:homelab-plan", repository_id: 123,
        repository: "homelab", environment: "homelab-plan",
        can_admins_bypass: false, prevent_self_review: false,
        wait_timer: null, deployment_branch_policy: [], reviewers: []
      },
      after: {
        id: "homelab:homelab-plan", repository_id: 123,
        repository: "homelab", environment: "homelab-plan",
        can_admins_bypass: false, prevent_self_review: false,
        wait_timer: null, deployment_branch_policy: [],
        reviewers: [{users: [57728706], teams: []}]
      }
    }
  }]}
')"

before="$(jq -e -S -c --arg source plan --arg phase before -f "$policy" <<<"$plan")"
after="$(jq -e -S -c --arg source plan --arg phase after -f "$policy" <<<"$plan")"
test "$before" != "$after"
live_before="$(jq -n '
  {name: "homelab-plan", can_admins_bypass: false,
   deployment_branch_policy: null, protection_rules: []}
' | jq -e -S -c --arg source live --arg phase before -f "$policy")"
test "$before" = "$live_before"

no_op="$(jq -c '.resource_changes[0].change.actions = ["no-op"] |
  .resource_changes[0].change.before = .resource_changes[0].change.after' <<<"$plan")"
jq -e --arg source plan --arg phase after -f "$policy" <<<"$no_op" >/dev/null

reject() {
  if jq -e --arg source plan --arg phase after -f "$policy" >/dev/null 2>&1; then
    echo "out-of-scope reviewer plan was accepted" >&2
    exit 1
  fi
}
jq -c '.resource_changes += [{address: "github_repository.this[\"homelab\"]",
  mode: "managed", change: {actions: ["update"]}}]' <<<"$plan" | reject
jq -c '.resource_changes[0].change.after.deployment_branch_policy =
  [{protected_branches: true, custom_branch_policies: false}]' <<<"$plan" | reject
jq -c '.resource_changes[0].change.after.reviewers[0].users = [42]' <<<"$plan" | reject
jq -c '.resource_changes[0].change.actions = ["create"]' <<<"$plan" | reject
