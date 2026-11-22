def name: "octelium-rscstore-backup";
def repository: "homelab";
def env_address: "github_repository_environment.this[\"homelab.octelium-rscstore-backup\"]";
def policy_address: "github_repository_environment_deployment_policy.this[\"homelab.octelium-rscstore-backup\"]";
def branch_policy: {protected_branches: false, custom_branch_policies: true};

def environment_ok:
  .repository == repository and .environment == name
  and .can_admins_bypass == false and .prevent_self_review == false
  and (.wait_timer // 0) == 0 and (.reviewers // []) == []
  and .deployment_branch_policy == [branch_policy];

def policy_ok:
  .repository == repository and .environment == name
  and .branch_pattern == "main" and .tag_pattern == null;

def target($address; $type):
  [.[] | select(.address == $address and .type == $type)]
  | if length == 1 then .[0] else error("target missing or duplicated in saved plan") end;

def safe_change:
  (.previous_address == null and .change.importing == null)
  and ((.change.actions == ["create"] and .change.before == null)
       or (.change.actions == ["no-op"] and .change.before == .change.after));

def state($environment; $policy):
  if $policy and ($environment | not) then error("branch policy has no environment")
  else {environment: $environment, branch_policy: $policy} end;

if $source == "plan" and ($phase == "before" or $phase == "after") then
  [.resource_changes[] | select(.mode == "managed")] as $changes
  | ($changes | target(env_address; "github_repository_environment")) as $environment
  | ($changes | target(policy_address; "github_repository_environment_deployment_policy")) as $policy
  | if ($changes | length) == 2 and ($environment | safe_change) and ($policy | safe_change)
       and ($environment.change.after | environment_ok) and ($policy.change.after | policy_ok)
    then state($environment.change[$phase] != null; $policy.change[$phase] != null)
    else error("saved plan must only create the exact main-only backup environment and its branch policy")
    end
elif $source == "live" then
  .environment as $environment
  | .policies as $policies
  | if $environment == null and $policies == [] then state(false; false)
    elif $environment.name == name and $environment.can_admins_bypass == false
      and $environment.protection_rules == [] and $environment.deployment_branch_policy == branch_policy
      and ($policies == [] or ($policies | length == 1 and .[0].name == "main" and .[0].type == "branch"))
    then state(true; $policies != [])
    else error("live backup environment does not match the expected protections")
    end
else error("unsupported policy input")
end
