def target: "github_repository_environment.this[\"homelab.homelab-plan\"]";

def plan_state:
  {
    repository,
    name: .environment,
    can_admins_bypass,
    prevent_self_review,
    wait_timer: (.wait_timer // 0),
    deployment_branch_policy: (.deployment_branch_policy[0] // null),
    reviewers: {
      users: ([.reviewers[]?.users[]?] | sort),
      teams: ([.reviewers[]?.teams[]?] | sort)
    }
  };

def live_state:
  . as $environment
  | [.protection_rules[]? | select(.type == "required_reviewers")] as $reviewer_rules
  | {
      repository: "homelab",
      name: .name,
      can_admins_bypass,
      prevent_self_review: ($reviewer_rules[0].prevent_self_review // false),
      wait_timer: ([.protection_rules[]? | select(.type == "wait_timer") | .wait_timer][0] // 0),
      deployment_branch_policy,
      reviewers: {
        users: ([$reviewer_rules[]?.reviewers[]? | select(.reviewer.type == "User") | .reviewer.id] | sort),
        teams: ([$reviewer_rules[]?.reviewers[]? | select(.reviewer.type == "Team") | .reviewer.id] | sort)
      }
    };

if $source == "plan" then
  . as $plan
  | [.resource_changes[]? | select(.address == target and .mode == "managed" and .type == "github_repository_environment")] as $target
  | [.resource_changes[]? | select(.mode == "managed" and .change.actions != ["no-op"])] as $mutations
  | ($target | length) == 1
    and ($mutations | length) <= 1
    and all($mutations[]; .address == target and .change.actions == ["update"])
    and ($target[0].change.actions == ["no-op"] or $target[0].change.actions == ["update"])
    and (($target[0].change.before | del(.reviewers)) ==
         ($target[0].change.after | del(.reviewers)))
    and (($target[0].change.after | plan_state) == {
      repository: "homelab",
      name: "homelab-plan",
      can_admins_bypass: false,
      prevent_self_review: false,
      wait_timer: 0,
      deployment_branch_policy: null,
      reviewers: {users: [], teams: []}
    })
    and (($target[0].change.importing // null) == null)
    and (($target[0].previous_address // null) == null)
  | if . then
      ($target[0].change[if $phase == "before" then "before" else "after" end] | plan_state)
    else error("saved plan changes resources or settings outside homelab-plan approval") end
elif $source == "live" then
  live_state
else
  error("unsupported policy source")
end
