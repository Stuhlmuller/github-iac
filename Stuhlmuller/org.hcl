locals {
  organization = "Stuhlmuller"
  default_repository_config = {
    has_issues                 = true
    allow_auto_merge           = true
    allow_rebase_merge         = false
    allow_squash_merge         = true
    allow_update_branch        = true
    visibility                 = "private"
    gitignore_template         = null
    default_branch             = "main"
    require_code_owner_reviews = false
    is_template                = false
    ruleset                    = [{ name = "main" }]
    delete_branch_on_merge     = true
  }
  default_repository_ruleset_config = {
    name                       = ""
    target                     = "branch"
    enforcement                = "active"
    require_code_owner_reviews = true
    require_signed_commits     = true
    conditions                 = [{ include = ["~DEFAULT_BRANCH"], exclude = [] }]
    creation                   = true
    update                     = false
    deletion                   = true
    bypass_actors = [
      {
        actor_id    = 2145192
        actor_type  = "Integration"
        bypass_mode = "pull_request"
      }
    ]
  }
}
