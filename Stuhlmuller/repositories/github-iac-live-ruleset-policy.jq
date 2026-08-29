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
  require_code_owner_review,
  require_extra_approval_for_unattributed_changes
}) == {
  allowed_merge_methods: ["squash"],
  required_approving_review_count: 0,
  require_code_owner_review: false,
  require_extra_approval_for_unattributed_changes: true
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
