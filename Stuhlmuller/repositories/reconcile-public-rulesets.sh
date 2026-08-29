#!/usr/bin/env bash
set -euo pipefail

mode="${1:---check}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest_file="$script_dir/public-rulesets.json"
homelab_address='github_repository_ruleset.existing["homelab.main"]'
github_iac_address='github_repository_ruleset.existing["github-iac.main"]'
homelab_policy_file="$script_dir/homelab-ruleset-policy.jq"
github_iac_live_policy_file="$script_dir/github-iac-live-ruleset-policy.jq"

case "$mode" in
  --apply | --check | --self-test) ;;
  *)
    echo "usage: $0 [--check|--apply|--self-test]" >&2
    exit 2
    ;;
esac

command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}
jq -e '
  type == "array"
  and length == 11
  and ([.[].repository] | unique | length) == length
  and ([.[].ruleset_id] | unique | length) == length
  and all(.[];
    (.repository | type) == "string"
    and (.repository | test("^[A-Za-z0-9._-]+$"))
    and (.ruleset_id | type) == "number"
    and (.ruleset_id | floor) == .ruleset_id
    and .ruleset_id > 0)
' "$manifest_file" >/dev/null
rulesets=()
while IFS='|' read -r repository ruleset_id; do
  rulesets+=("$repository|$ruleset_id|github_repository_ruleset.existing[\"$repository.main\"]")
done < <(jq -r '.[] | [.repository, (.ruleset_id | tostring)] | join("|")' "$manifest_file")
rulesets_json="$(jq -cn --args '
  $ARGS.positional
  | map(split("|") as $parts | {
      repository: $parts[0],
      ruleset_id: ($parts[1] | tonumber),
      address: $parts[2]
    })
  ' "${rulesets[@]}")"
plan_policy_file="$script_dir/public-ruleset-plan-policy.jq"

if [[ "$mode" == "--self-test" ]]; then
  plan_fixture="$(jq -cn --argjson metadata "$rulesets_json" '
    {
      resource_changes: [
        $metadata[]
        | (.ruleset_id | tostring) as $id
        | {
            address,
            mode: "managed",
            type: "github_repository_ruleset",
            change: {
              actions: ["no-op"],
              before: {repository, ruleset_id, id: $id, name: "main", target: "branch", enforcement: "active", bypass_actors: []},
              after: {repository, ruleset_id, id: $id, name: "main", target: "branch", enforcement: "active", bypass_actors: []}
            }
          }
      ]
    }
  ')"
  jq -e \
    --arg homelab "$homelab_address" \
    --arg github_iac "$github_iac_address" \
    --argjson expected_metadata "$rulesets_json" \
    -f "$plan_policy_file" <<<"$plan_fixture" >/dev/null
  update_fixture="$(jq '
    .resource_changes[0].change.actions = ["update"]
    | .resource_changes[0].change.before.bypass_actors = [{
        actor_id: 2145192,
        actor_type: "Integration",
        bypass_mode: "pull_request"
      }]
  ' <<<"$plan_fixture")"
  jq -e \
    --arg homelab "$homelab_address" \
    --arg github_iac "$github_iac_address" \
    --argjson expected_metadata "$rulesets_json" \
    -f "$plan_policy_file" <<<"$update_fixture" >/dev/null
  if jq '(.resource_changes[]
      | select(.address == "github_repository_ruleset.existing[\".github.main\"]")
      | .change.before.bypass_actors[0].actor_id) = 1' <<<"$update_fixture" |
    jq -e \
      --arg homelab "$homelab_address" \
      --arg github_iac "$github_iac_address" \
      --argjson expected_metadata "$rulesets_json" \
      -f "$plan_policy_file" >/dev/null; then
    echo "wrong bypass actor fixture unexpectedly passed" >&2
    exit 1
  fi
  if jq '.resource_changes[0].change.after.enforcement = "evaluate"' <<<"$update_fixture" |
    jq -e \
      --arg homelab "$homelab_address" \
      --arg github_iac "$github_iac_address" \
      --argjson expected_metadata "$rulesets_json" \
      -f "$plan_policy_file" >/dev/null; then
    echo "tampered bypass-removal fixture unexpectedly passed" >&2
    exit 1
  fi
  if jq '.resource_changes[0].change.after.ruleset_id = -1' <<<"$plan_fixture" |
    jq -e \
      --arg homelab "$homelab_address" \
      --arg github_iac "$github_iac_address" \
      --argjson expected_metadata "$rulesets_json" \
      -f "$plan_policy_file" >/dev/null; then
    echo "ruleset identity negative fixture unexpectedly passed" >&2
    exit 1
  fi
  if jq '.resource_changes += [{
      address: "github_repository.this[\"unrelated\"]",
      mode: "managed",
      type: "github_repository",
      change: {actions: ["no-op"], before: {}, after: {}}
    }]' <<<"$plan_fixture" |
    jq -e \
      --arg homelab "$homelab_address" \
      --arg github_iac "$github_iac_address" \
      --argjson expected_metadata "$rulesets_json" \
      -f "$plan_policy_file" >/dev/null; then
    echo "unrelated resource negative fixture unexpectedly passed" >&2
    exit 1
  fi

  homelab_live_fixture="$(
    jq -n -c \
      --arg source self-test \
      --arg phase after \
      --arg expect any \
      -f "$homelab_policy_file" |
      jq -c '
        . as $expected
        | {
            id: ($expected.id | tonumber),
            name: $expected.name,
            target: $expected.target,
            enforcement: $expected.enforcement,
            conditions: $expected.conditions,
            bypass_actors: [],
            rules: [
              $expected.rule_types[] as $type
              | if $type == "pull_request" then {
                  type: $type,
                  parameters: ($expected.pull_request + {
                    require_extra_approval_for_unattributed_changes: true
                  })
                }
                elif $type == "required_status_checks" then {
                  type: $type,
                  parameters: {
                    strict_required_status_checks_policy: $expected.required_status_checks.strict_required_status_checks_policy,
                    do_not_enforce_on_create: $expected.required_status_checks.do_not_enforce_on_create,
                    required_status_checks: $expected.required_status_checks.checks
                  }
                }
                else {type: $type} end
            ]
          }
      '
  )"
  jq -e \
    --arg source live \
    --arg phase after \
    --arg expect desired \
    -f "$homelab_policy_file" <<<"$homelab_live_fixture" >/dev/null
  for invalid_value in false missing; do
    if [[ "$invalid_value" == false ]]; then
      invalid_fixture="$(jq '(.rules[] | select(.type == "pull_request") | .parameters.require_extra_approval_for_unattributed_changes) = false' <<<"$homelab_live_fixture")"
    else
      invalid_fixture="$(jq '(.rules[] | select(.type == "pull_request") | .parameters) |= del(.require_extra_approval_for_unattributed_changes)' <<<"$homelab_live_fixture")"
    fi
    if jq -e \
      --arg source live \
      --arg phase after \
      --arg expect desired \
      -f "$homelab_policy_file" <<<"$invalid_fixture" >/dev/null 2>&1; then
      echo "homelab $invalid_value extra-approval fixture unexpectedly passed" >&2
      exit 1
    fi
  done

  github_iac_live_fixture="$(jq -cn '{rules: [
    {type: "creation"},
    {type: "deletion"},
    {type: "non_fast_forward"},
    {type: "pull_request", parameters: {
      allowed_merge_methods: ["squash"],
      required_approving_review_count: 0,
      require_code_owner_review: false,
      require_extra_approval_for_unattributed_changes: true
    }},
    {type: "required_linear_history"},
    {type: "required_signatures"},
    {type: "required_status_checks", parameters: {
      strict_required_status_checks_policy: true,
      do_not_enforce_on_create: false,
      required_status_checks: [
        {context: "policy-bot: main", integration_id: 3280987},
        {context: "check / merge-checks", integration_id: 15368},
        {context: "checks", integration_id: 15368},
        {context: "release", integration_id: 15368},
        {context: "analyze-actions", integration_id: 15368}
      ]
    }}
  ]}')"
  jq -e -f "$github_iac_live_policy_file" <<<"$github_iac_live_fixture" >/dev/null
  for invalid_value in false missing; do
    if [[ "$invalid_value" == false ]]; then
      invalid_fixture="$(jq '(.rules[] | select(.type == "pull_request") | .parameters.require_extra_approval_for_unattributed_changes) = false' <<<"$github_iac_live_fixture")"
    else
      invalid_fixture="$(jq '(.rules[] | select(.type == "pull_request") | .parameters) |= del(.require_extra_approval_for_unattributed_changes)' <<<"$github_iac_live_fixture")"
    fi
    if jq -e -f "$github_iac_live_policy_file" <<<"$invalid_fixture" >/dev/null; then
      echo "github-iac $invalid_value extra-approval fixture unexpectedly passed" >&2
      exit 1
    fi
  done
  echo "public ruleset plan policy fixtures passed"
  exit 0
fi

for command_name in cmp gh terragrunt; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required" >&2
    exit 1
  }
done
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required for the GitHub provider}"
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"

github_api() {
  gh api \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "$@"
}

snapshot_live_rulesets() {
  local destination="$1"
  local entry repository remainder ruleset_id

  mkdir -p "$destination"
  for entry in "${rulesets[@]}"; do
    repository="${entry%%|*}"
    remainder="${entry#*|}"
    ruleset_id="${remainder%%|*}"
    github_api "repos/Stuhlmuller/$repository/rulesets/$ruleset_id" |
      jq -S -c . >"$destination/$repository.json"
  done
}

cd "$script_dir"
bash migrate-public-ruleset-state.sh --check
terragrunt --log-disable init -reconfigure -input=false >/dev/null

plan_dir="$(mktemp -d "${TMPDIR:-/tmp}/github-iac-public-rulesets.XXXXXX")"
cleanup() {
  if [[ -d "$plan_dir" ]]; then
    rm -rf -- "$plan_dir"
  fi
}
trap cleanup EXIT
plan_file="$plan_dir/plan.out"
target_args=()
for entry in "${rulesets[@]}"; do
  address="${entry##*|}"
  target_args+=("-target=$address")
done

snapshot_live_rulesets "$plan_dir/live-before"
terragrunt --log-disable plan -input=false -no-color \
  "${target_args[@]}" -out="$plan_file" >/dev/null
plan_json="$(terragrunt --log-disable show -json "$plan_file")"

jq -e \
  --arg homelab "$homelab_address" \
  --arg github_iac "$github_iac_address" \
  --argjson expected_metadata "$rulesets_json" \
  -f "$plan_policy_file" <<<"$plan_json" >/dev/null

jq --arg address "$homelab_address" '
  {resource_changes: [.resource_changes[] | select(.address == $address)]}
  ' <<<"$plan_json" |
  jq -e -S -c --arg source plan --arg phase after --arg expect desired \
    -f "$homelab_policy_file" >/dev/null

jq -e --arg address "$github_iac_address" '
  [.resource_changes[] | select(.address == $address)]
  | . as $matches
  | ($matches | length) == 1
  and ($matches[0].change.after as $value
  | $value.repository == "github-iac"
  and $value.name == "main"
  and $value.target == "branch"
  and $value.enforcement == "active"
  and $value.conditions == [{ref_name: [{exclude: [], include: ["~DEFAULT_BRANCH"]}]}]
  and ($value.bypass_actors // []) == []
  and ($value.rules | length) == 1
  and $value.rules[0].creation == true
  and $value.rules[0].deletion == true
  and $value.rules[0].non_fast_forward == true
  and $value.rules[0].required_linear_history == true
  and $value.rules[0].required_signatures == true
  and $value.rules[0].update == false
  and $value.rules[0].update_allows_fetch_and_merge == false
  and ([
    "branch_name_pattern",
    "commit_author_email_pattern",
    "commit_message_pattern",
    "committer_email_pattern",
    "copilot_code_review",
    "file_extension_restriction",
    "file_path_restriction",
    "max_file_path_length",
    "max_file_size",
    "merge_queue",
    "required_code_scanning",
    "required_deployments",
    "tag_name_pattern"
  ] | all(.[]; ($value.rules[0][.] // []) == []))
  and ($value.rules[0].pull_request | length) == 1
  and ($value.rules[0].pull_request[0] as $pull_request
    | {
        allowed_merge_methods: ($pull_request.allowed_merge_methods // []),
        dismiss_stale_reviews_on_push: ($pull_request.dismiss_stale_reviews_on_push // false),
        required_reviewers: ($pull_request.required_reviewers // []),
        require_code_owner_review: ($pull_request.require_code_owner_review // false),
        require_last_push_approval: ($pull_request.require_last_push_approval // false),
        required_review_thread_resolution: ($pull_request.required_review_thread_resolution // false),
        required_approving_review_count: ($pull_request.required_approving_review_count // 0)
      } == {
        allowed_merge_methods: ["squash"],
        dismiss_stale_reviews_on_push: false,
        required_reviewers: [],
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: false,
        required_approving_review_count: 0
      })
  and ($value.rules[0].required_status_checks | length) == 1
  and $value.rules[0].required_status_checks[0].strict_required_status_checks_policy == true
  and $value.rules[0].required_status_checks[0].do_not_enforce_on_create == false
  and ([$value.rules[0].required_status_checks[0].required_check[] | {context, integration_id}] | sort_by(.context)) == ([
    {context: "policy-bot: main", integration_id: 3280987},
    {context: "check / merge-checks", integration_id: 15368},
    {context: "checks", integration_id: 15368},
    {context: "release", integration_id: 15368},
    {context: "analyze-actions", integration_id: 15368}
  ] | sort_by(.context)))
  ' <<<"$plan_json" >/dev/null

snapshot_live_rulesets "$plan_dir/live-preapply"
for entry in "${rulesets[@]}"; do
  repository="${entry%%|*}"
  cmp -s \
    "$plan_dir/live-before/$repository.json" \
    "$plan_dir/live-preapply/$repository.json" || {
    echo "$repository ruleset changed while planning; refusing to apply stale state" >&2
    exit 1
  }
done

if [[ "$mode" == "--check" ]]; then
  jq -e '
    all(.resource_changes[]? | select(.mode == "managed"); .change.actions == ["no-op"])
  ' <<<"$plan_json" >/dev/null || {
    echo "public ruleset drift exists; review and run --apply" >&2
    exit 1
  }
else
  terragrunt --log-disable apply -input=false "$plan_file"
  set +e
  terragrunt --log-disable plan -input=false -no-color -detailed-exitcode \
    "${target_args[@]}" >/dev/null
  post_apply_plan_status=$?
  set -e
  if [[ "$post_apply_plan_status" -ne 0 ]]; then
    echo "public rulesets still differ from the declared state after apply" >&2
    exit 1
  fi
fi

for entry in "${rulesets[@]}"; do
  repository="${entry%%|*}"
  remainder="${entry#*|}"
  ruleset_id="${remainder%%|*}"
  live="$(github_api "repos/Stuhlmuller/$repository/rulesets/$ruleset_id")"
  jq -e --arg repository "$repository" --argjson id "$ruleset_id" '
    .id == $id
    and .name == "main"
    and .target == "branch"
    and .enforcement == "active"
    and .source_type == "Repository"
    and .source == "Stuhlmuller/\($repository)"
    and .conditions == {ref_name: {exclude: [], include: ["~DEFAULT_BRANCH"]}}
    and .bypass_actors == []
  ' <<<"$live" >/dev/null

  if [[ "$repository" == "homelab" ]]; then
    jq -e -S -c --arg source live --arg phase after --arg expect desired \
      -f "$homelab_policy_file" <<<"$live" >/dev/null
  elif [[ "$repository" == "github-iac" ]]; then
    jq -e -f "$github_iac_live_policy_file" <<<"$live" >/dev/null
  fi
done

echo "all 11 public repository rulesets match the declared no-bypass policy"
