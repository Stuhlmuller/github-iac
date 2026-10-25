mock_provider "github" {}

run "automatic_homelab_plan" {
  command = plan

  variables {
    organization = "Stuhlmuller"
    repositories = {
      homelab = {
        visibility = "public"
        ruleset    = []
        environments = [
          {
            name = "homelab-plan"
          },
          {
            name              = "homelab-production"
            deployment_branch = "main"
            deployment_branch_policy = {
              protected_branches     = false
              custom_branch_policies = true
            }
          }
        ]
      }
    }
  }

  assert {
    condition     = length(github_repository_environment.this["homelab.homelab-plan"].reviewers) == 0 && length(github_repository_environment.this["homelab.homelab-production"].reviewers) == 0
    error_message = "Homelab PR plans and main-only production deploy automatically."
  }

  assert {
    condition     = github_repository_environment_deployment_policy.this["homelab.homelab-production"].branch_pattern == "main" && length(github_repository_environment_deployment_policy.this) == 1
    error_message = "Only the exact main branch may deploy to production."
  }
}
