[
  "github_repository_ruleset.this[\".github.main\"]",
  "github_repository_ruleset.this[\"ai-pr-reviewer.main\"]",
  "github_repository_ruleset.this[\"github-iac.main\"]",
  "github_repository_ruleset.this[\"grafana-iac.main\"]",
  "github_repository_ruleset.this[\"hivemind.main\"]",
  "github_repository_ruleset.existing[\"homelab.main\"]",
  "github_repository_ruleset.this[\"personal-website.main\"]",
  "github_repository_ruleset.this[\"policies.main\"]",
  "github_repository_ruleset.this[\"renovate.main\"]",
  "github_repository_ruleset.this[\"terragrunt-catalog.main\"]",
  "github_repository_ruleset.this[\"workflows.main\"]"
] as $expected
| [.resource_changes[]? | select(.mode == "managed")] as $managed
| [$managed[] | select(.type == "github_repository_ruleset")] as $rulesets
| ($rulesets | map(.address) | sort) == ($expected | sort)
and all($expected_metadata[];
  . as $expected_ruleset
  | [$rulesets[] | select(.address == $expected_ruleset.address)] as $matches
  | ($matches | length) == 1
  and all(["before", "after"][];
    . as $phase
    | $matches[0].change[$phase].repository == $expected_ruleset.repository
    and $matches[0].change[$phase].ruleset_id == $expected_ruleset.ruleset_id
    and (($matches[0].change[$phase].id | tostring) == ($expected_ruleset.ruleset_id | tostring))))
and all($managed[];
  ((.change.importing // null) == null)
  and ((.previous_address // null) == null)
  and (if .type == "github_repository_ruleset" then
    (.change.actions == ["no-op"] or .change.actions == ["update"])
  else
    .change.actions == ["no-op"]
  end))
and all($rulesets[]; (.change.after.bypass_actors // []) == [])
and all($rulesets[];
  if (.address == $homelab or .address == $github_iac) then true
  elif .change.actions == ["no-op"] then
    .change.before == .change.after
    and (.change.after.bypass_actors // []) == []
  else
    (.change.before.bypass_actors | length) == 1
    and .change.before.bypass_actors[0].actor_type == "Integration"
    and .change.before.bypass_actors[0].bypass_mode == "pull_request"
    and ((.change.before | del(.bypass_actors)) == (.change.after | del(.bypass_actors)))
  end)
