def expected_checks:
  [
    {context: "policy-bot: main", integration_id: 3280987},
    {context: "Lint", integration_id: 15368},
    {context: "repo", integration_id: 15368},
    {context: "Analyze (python)", integration_id: 15368},
    {context: "analyze-actions", integration_id: 15368},
    {context: "release-dry-run", integration_id: 15368},
    {context: "Terragrunt Gate", integration_id: 15368}
  ] | sort_by(.context, .integration_id);

def expected:
  {
    id: "14700233",
    repository: "homelab",
    name: "main",
    target: "branch",
    enforcement: "active",
    conditions_count: 1,
    condition_keys: ["ref_name"],
    ref_name_count: 1,
    conditions: {ref_name: {exclude: [], include: ["~DEFAULT_BRANCH"]}},
    bypass_actors: [],
    rule_block_count: 1,
    rule_types: [
      "creation",
      "deletion",
      "non_fast_forward",
      "pull_request",
      "required_linear_history",
      "required_signatures",
      "required_status_checks"
    ],
    pull_request: {
      allowed_merge_methods: ["squash"],
      dismiss_stale_reviews_on_push: false,
      required_reviewers: [],
      require_code_owner_review: false,
      dismissal_restriction: {enabled: false, allowed_actors: []},
      require_last_push_approval: false,
      required_review_thread_resolution: false,
      require_extra_approval_for_unattributed_changes: false,
      required_approving_review_count: 0
    },
    required_status_checks: {
      strict_required_status_checks_policy: true,
      do_not_enforce_on_create: false,
      checks: expected_checks
    }
  };

def normalize_bypass:
  map({
    actor_type,
    bypass_mode
  }) | sort_by(.actor_type, .bypass_mode);

def field_or_null($key):
  if has($key) then .[$key] else null end;

def tf_rule_types($rules):
  [
    if $rules.creation == true then "creation" else empty end,
    if $rules.deletion == true then "deletion" else empty end,
    if $rules.non_fast_forward == true then "non_fast_forward" else empty end,
    if $rules.required_linear_history == true then "required_linear_history" else empty end,
    if $rules.required_signatures == true then "required_signatures" else empty end,
    if $rules.update == true then "update" else empty end,
    if $rules.update_allows_fetch_and_merge == true then "update_allows_fetch_and_merge" else empty end,
    if (($rules.branch_name_pattern // []) | length) > 0 then "branch_name_pattern" else empty end,
    if (($rules.commit_author_email_pattern // []) | length) > 0 then "commit_author_email_pattern" else empty end,
    if (($rules.commit_message_pattern // []) | length) > 0 then "commit_message_pattern" else empty end,
    if (($rules.committer_email_pattern // []) | length) > 0 then "committer_email_pattern" else empty end,
    if (($rules.copilot_code_review // []) | length) > 0 then "copilot_code_review" else empty end,
    if (($rules.file_extension_restriction // []) | length) > 0 then "file_extension_restriction" else empty end,
    if (($rules.file_path_restriction // []) | length) > 0 then "file_path_restriction" else empty end,
    if (($rules.max_file_path_length // []) | length) > 0 then "max_file_path_length" else empty end,
    if (($rules.max_file_size // []) | length) > 0 then "max_file_size" else empty end,
    if (($rules.merge_queue // []) | length) > 0 then "merge_queue" else empty end,
    if (($rules.pull_request // []) | length) > 0 then "pull_request" else empty end,
    if (($rules.required_code_scanning // []) | length) > 0 then "required_code_scanning" else empty end,
    if (($rules.required_deployments // []) | length) > 0 then "required_deployments" else empty end,
    if (($rules.required_status_checks // []) | length) > 0 then "required_status_checks" else empty end,
    if (($rules.tag_name_pattern // []) | length) > 0 then "tag_name_pattern" else empty end
  ] | sort;

def normalize_tf:
  . as $value
  | ($value.rules // []) as $rule_blocks
  | ($rule_blocks[0] // {}) as $rules
  | ($rules.pull_request // []) as $pull_requests
  | ($rules.required_status_checks // []) as $status_checks
  | {
      id: (($value.ruleset_id // $value.id // "") | tostring),
      repository: ($value.repository // ""),
      name: ($value.name // ""),
      target: ($value.target // ""),
      enforcement: ($value.enforcement // ""),
      conditions_count: (($value.conditions // []) | length),
      condition_keys: (if (($value.conditions // []) | length) == 1 then ["ref_name"] else [] end),
      ref_name_count: (($value.conditions[0].ref_name // []) | length),
      conditions: {
        ref_name: {
          exclude: (($value.conditions[0].ref_name[0].exclude // []) | sort),
          include: (($value.conditions[0].ref_name[0].include // []) | sort)
        }
      },
      bypass_actors: (($value.bypass_actors // []) | normalize_bypass),
      rule_block_count: ($rule_blocks | length),
      rule_types: tf_rule_types($rules),
      pull_request: (
        if ($pull_requests | length) == 1 then
          $pull_requests[0] as $pull_request
          | {
              allowed_merge_methods: (($pull_request.allowed_merge_methods // []) | sort),
              dismiss_stale_reviews_on_push: ($pull_request.dismiss_stale_reviews_on_push // false),
              required_reviewers: ($pull_request.required_reviewers // []),
              require_code_owner_review: ($pull_request.require_code_owner_review // false),
              dismissal_restriction: {enabled: false, allowed_actors: []},
              require_last_push_approval: ($pull_request.require_last_push_approval // false),
              required_review_thread_resolution: ($pull_request.required_review_thread_resolution // false),
              require_extra_approval_for_unattributed_changes: false,
              required_approving_review_count: ($pull_request.required_approving_review_count // 0)
            }
        else null end
      ),
      required_status_checks: (
        if ($status_checks | length) == 1 then
          $status_checks[0] as $status_check
          | {
              strict_required_status_checks_policy: ($status_check.strict_required_status_checks_policy // false),
              do_not_enforce_on_create: ($status_check.do_not_enforce_on_create // false),
              checks: ([($status_check.required_check // [])[] | {
                context,
                integration_id: (.integration_id // null)
              }] | sort_by(.context, .integration_id))
            }
        else null end
      )
    };

def normalize_live:
  . as $value
  | [($value.rules // [])[] | select(.type == "pull_request")] as $pull_requests
  | [($value.rules // [])[] | select(.type == "required_status_checks")] as $status_checks
  | {
      id: (($value.id // "") | tostring),
      repository: "homelab",
      name: ($value.name // ""),
      target: ($value.target // ""),
      enforcement: ($value.enforcement // ""),
      conditions_count: (if ($value.conditions | type) == "object" then 1 else 0 end),
      condition_keys: (if ($value.conditions | type) == "object" then ($value.conditions | keys | sort) else [] end),
      ref_name_count: (if ($value.conditions.ref_name | type) == "object" then 1 else 0 end),
      conditions: {
        ref_name: {
          exclude: (($value.conditions.ref_name.exclude // []) | sort),
          include: (($value.conditions.ref_name.include // []) | sort)
        }
      },
      bypass_actors: (($value.bypass_actors // []) | normalize_bypass),
      rule_block_count: 1,
      rule_types: ([($value.rules // [])[].type] | sort),
      pull_request: (
        if ($pull_requests | length) == 1 then
          $pull_requests[0].parameters as $pull_request
          | {
              allowed_merge_methods: (($pull_request.allowed_merge_methods // []) | sort),
              dismiss_stale_reviews_on_push: ($pull_request | field_or_null("dismiss_stale_reviews_on_push")),
              required_reviewers: ($pull_request.required_reviewers // null),
              require_code_owner_review: ($pull_request | field_or_null("require_code_owner_review")),
              dismissal_restriction: ($pull_request.dismissal_restriction // null),
              require_last_push_approval: ($pull_request | field_or_null("require_last_push_approval")),
              required_review_thread_resolution: ($pull_request | field_or_null("required_review_thread_resolution")),
              require_extra_approval_for_unattributed_changes: ($pull_request | field_or_null("require_extra_approval_for_unattributed_changes")),
              required_approving_review_count: ($pull_request.required_approving_review_count // null)
            }
        else null end
      ),
      required_status_checks: (
        if ($status_checks | length) == 1 then
          $status_checks[0].parameters as $status_check
          | {
              strict_required_status_checks_policy: ($status_check | field_or_null("strict_required_status_checks_policy")),
              do_not_enforce_on_create: ($status_check | field_or_null("do_not_enforce_on_create")),
              checks: ([($status_check.required_status_checks // [])[] | {
                context,
                integration_id: (.integration_id // null)
              }] | sort_by(.context, .integration_id))
            }
        else null end
      )
    };

def plan_value:
  [.resource_changes[]? | select(.mode == "managed")] as $changes
  | if ($changes | length) != 1 then error("plan must contain exactly one managed resource") else $changes[0] end
  | if .address != "github_repository_ruleset.existing[\"homelab.main\"]" then error("plan targets an unexpected resource") else . end
  | if ((.change.actions == ["no-op"]) or (.change.actions == ["update"])) then . else error("plan action must be no-op or update") end
  | if ((.change.importing // null) == null) then . else error("plan must not import") end
  | if ((.previous_address // null) == null) then . else error("state migration must finish before planning") end
  | if ($phase == "before" or $phase == "after") then .change[$phase] else error("phase must be before or after") end;

def require_desired:
  . as $actual
  | expected as $wanted
  | if $actual == $wanted then . else error("ruleset policy does not match the exact desired state") end;

if $source == "plan" then
  plan_value | normalize_tf
elif $source == "live" then
  normalize_live
elif $source == "self-test" then
  expected
else
  error("source must be plan, live, or self-test")
end
| if $expect == "desired" then require_desired else . end
