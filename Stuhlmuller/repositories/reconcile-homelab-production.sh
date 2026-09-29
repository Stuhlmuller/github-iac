#!/usr/bin/env bash
set -euo pipefail

# Homelab main deploys without a second approval; PR plans still need review.
mode="${1:---check}"
case "$mode" in
  --check | --apply | --self-test) ;;
  *) echo "usage: $0 [--check|--apply|--self-test]" >&2; exit 2 ;;
esac

require_main_only() {
  jq -e '
    .environment.deployment_branch_policy == {
      protected_branches: false, custom_branch_policies: true
    } and .branches.total_count == 1 and
    [.branches.branch_policies[] | {name, type}] == [{name: "main", type: "branch"}]
  ' >/dev/null
}

if [[ "$mode" == --self-test ]]; then
  valid='{"environment":{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}},"branches":{"total_count":1,"branch_policies":[{"name":"main","type":"branch"}]}}'
  require_main_only <<<"$valid"
  for mutation in \
    '.branches.branch_policies[0].name = "*"' \
    '.branches.branch_policies[0].type = "tag"' \
    '.branches.total_count = 2' \
    '.environment.deployment_branch_policy = null'; do
    if jq "$mutation" <<<"$valid" | require_main_only; then
      echo "unsafe branch policy accepted: $mutation" >&2
      exit 1
    fi
  done
  echo "Main-only environment checks passed."
  exit 0
fi

endpoint="repos/Stuhlmuller/homelab/environments"
production="$(gh api "$endpoint/homelab-production")"
branches="$(gh api "$endpoint/homelab-production/deployment-branch-policies")"
plan="$(gh api "$endpoint/homelab-plan")"
jq -n --argjson environment "$production" --argjson branches "$branches" \
  '{environment: $environment, branches: $branches}' | require_main_only
jq -e 'any(.protection_rules[]; .type == "required_reviewers" and (.reviewers | length) > 0)' \
  <<<"$plan" >/dev/null

if [[ "$mode" == --apply ]]; then
  # Preserve branch restrictions, timers and bypass settings; change reviewers only.
  jq '{
    reviewers: [], prevent_self_review: false,
    can_admins_bypass, deployment_branch_policy,
    wait_timer: ([.protection_rules[] | select(.type == "wait_timer") | .wait_timer][0] // 0)
  }' <<<"$production" |
    gh api --method PUT "$endpoint/homelab-production" --input - >/dev/null
fi

gh api "$endpoint/homelab-production" |
  jq -e 'all(.protection_rules[]; .type != "required_reviewers")' >/dev/null
test "$(gh api "$endpoint/homelab-production/deployment-branch-policies" | jq -S .)" = \
  "$(jq -S . <<<"$branches")"
test "$(gh api "$endpoint/homelab-plan" | jq -S .protection_rules)" = \
  "$(jq -S .protection_rules <<<"$plan")"
echo "Verified: main-only production has no reviewer gate; PR-plan reviewers unchanged."
