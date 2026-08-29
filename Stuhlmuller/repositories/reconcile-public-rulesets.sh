#!/usr/bin/env bash
set -euo pipefail

mode="${1:---check}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
homelab_address='github_repository_ruleset.existing["homelab.main"]'
github_iac_address='github_repository_ruleset.this["github-iac.main"]'
rulesets=(
  '.github|11493159|github_repository_ruleset.this[".github.main"]'
  'ai-pr-reviewer|14700811|github_repository_ruleset.this["ai-pr-reviewer.main"]'
  'github-iac|5660587|github_repository_ruleset.this["github-iac.main"]'
  'grafana-iac|8218990|github_repository_ruleset.this["grafana-iac.main"]'
  'hivemind|17347203|github_repository_ruleset.this["hivemind.main"]'
  'homelab|14700233|github_repository_ruleset.existing["homelab.main"]'
  'personal-website|14702864|github_repository_ruleset.this["personal-website.main"]'
  'policies|9041681|github_repository_ruleset.this["policies.main"]'
  'renovate|14702863|github_repository_ruleset.this["renovate.main"]'
  'terragrunt-catalog|7928987|github_repository_ruleset.this["terragrunt-catalog.main"]'
  'workflows|14702865|github_repository_ruleset.this["workflows.main"]'
)

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
              before: {repository, ruleset_id, id: $id, bypass_actors: []},
              after: {repository, ruleset_id, id: $id, bypass_actors: []}
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
  if jq '.resource_changes[0].change.after.ruleset_id = -1' <<<"$plan_fixture" |
    jq -e \
      --arg homelab "$homelab_address" \
      --arg github_iac "$github_iac_address" \
      --argjson expected_metadata "$rulesets_json" \
      -f "$plan_policy_file" >/dev/null; then
    echo "ruleset identity negative fixture unexpectedly passed" >&2
    exit 1
  fi
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
bash migrate-homelab-ruleset-state.sh --check
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
    -f homelab-ruleset-policy.jq >/dev/null

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
      -f homelab-ruleset-policy.jq <<<"$live" >/dev/null
  elif [[ "$repository" == "github-iac" ]]; then
    jq -e '
      ([.rules[].type] | sort) == ([
        "creation",
        "deletion",
        "non_fast_forward",
        "pull_request",
        "required_linear_history",
        "required_signatures",
        "required_status_checks"
      ] | sort)
      and ([.rules[] | select(.type == "pull_request")] | length) == 1
      and ([.rules[] | select(.type == "pull_request")][0].parameters | {
        allowed_merge_methods,
        required_approving_review_count,
        require_code_owner_review
      }) == {
        allowed_merge_methods: ["squash"],
        required_approving_review_count: 0,
        require_code_owner_review: false
      }
      and ([.rules[] | select(.type == "required_status_checks")] | length) == 1
      and ([.rules[] | select(.type == "required_status_checks")][0].parameters as $parameters
        | $parameters.strict_required_status_checks_policy == true
        and $parameters.do_not_enforce_on_create == false
        and ([$parameters.required_status_checks[] | {context, integration_id}] | sort_by(.context)) == ([
          {context: "policy-bot: main", integration_id: 3280987},
          {context: "check / merge-checks", integration_id: 15368},
          {context: "checks", integration_id: 15368},
          {context: "release", integration_id: 15368},
          {context: "analyze-actions", integration_id: 15368}
        ] | sort_by(.context)))
    ' <<<"$live" >/dev/null
  fi
done

echo "all 11 public repository rulesets match the declared no-bypass policy"
