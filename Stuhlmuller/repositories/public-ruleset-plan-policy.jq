def n8n_bypass: [{actor_id: 5015161, actor_type: "Integration", bypass_mode: "pull_request"}];

[
  "github_repository_ruleset.existing[\".github.main\"]",
  "github_repository_ruleset.existing[\"ai-pr-reviewer.main\"]",
  "github_repository_ruleset.existing[\"github-iac.main\"]",
  "github_repository_ruleset.existing[\"grafana-iac.main\"]",
  "github_repository_ruleset.existing[\"hivemind.main\"]",
  "github_repository_ruleset.existing[\"homelab.main\"]",
  "github_repository_ruleset.existing[\"personal-website.main\"]",
  "github_repository_ruleset.existing[\"policies.main\"]",
  "github_repository_ruleset.existing[\"renovate.main\"]",
  "github_repository_ruleset.existing[\"terragrunt-catalog.main\"]",
  "github_repository_ruleset.existing[\"workflows.main\"]"
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
  .type == "github_repository_ruleset"
  and ((.change.importing // null) == null)
  and ((.previous_address // null) == null)
  and (.change.actions == ["no-op"] or .change.actions == ["update"]))
and all($rulesets[]; .change.after.bypass_actors == n8n_bypass)
and all($rulesets[];
  if .change.actions == ["no-op"] then
    .change.before == .change.after
  else
    ((.change.before.bypass_actors // []) as $before
      | $before == []
      or $before == n8n_bypass
      or $before == [{actor_id: 2145192, actor_type: "Integration", bypass_mode: "pull_request"}]
      or (.change.before.repository == "personal-website"
        and $before == (n8n_bypass | .[0].bypass_mode = "always")))
    and (.address == $homelab or .address == $github_iac
      or (.change.before | del(.bypass_actors)) == (.change.after | del(.bypass_actors)))
  end)
