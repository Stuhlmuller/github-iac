locals {
  organization = "rstuhlmuller"

  default_repository_config = {
    description                = ""
    visibility                 = "private"
    gitignore_template         = null
    default_branch             = "main"
    require_code_owner_reviews = false
    is_template                = false
    ruleset                    = [{ name = "main" }]
    delete_branch_on_merge     = true
    allow_update_branch        = false
    allow_auto_merge           = true
    allow_merge_commit         = false
    allow_squash_merge         = false
    squash_merge_commit_title  = "COMMIT_OR_PR_TITLE"
    allow_rebase_merge         = false
    allow_update_branch        = true
    allow_squash_merge         = true
    archived                   = false
  }
  default_repository_ruleset_config = {
    name                       = ""
    target                     = "branch"
    enforcement                = "active"
    require_code_owner_reviews = true
    require_signed_commits     = true
    conditions = [
      {
        include = ["~DEFAULT_BRANCH"]
        exclude = []
      }
    ]
    creation                = true
    update                  = false
    deletion                = true
    required_linear_history = true
    required_signatures     = true
    bypass_actors           = []
    required_deployments    = []
    required_status_checks = [
      {
        strict_required_status_checks_policy = true
        required_check = [{
          context = "check / merge-checks"
        }]
      }
    ]
    pull_requests = [{
      required_approving_review_count = 0
      require_code_owner_reviews      = true
    }]
  }
}
