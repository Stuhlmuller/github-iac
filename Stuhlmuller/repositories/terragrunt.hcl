locals {
  org_vars = read_terragrunt_config(find_in_parent_folders("org.hcl")).locals
  public_repository_config = {
    visibility                = "public"
    delete_branch_on_merge    = true
    allow_update_branch       = true
    allow_auto_merge          = true
    allow_merge_commit        = false
    allow_squash_merge        = true
    squash_merge_commit_title = "COMMIT_OR_PR_TITLE"
    allow_rebase_merge        = false
  }
}

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/github_repositories"
}

generate "provider" {
  path      = "github-provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
  provider "github" {
    owner = "${local.org_vars.organization}"
  }
  EOF
}

inputs = {
  organization                      = local.org_vars.organization
  default_repository_config         = local.org_vars.default_repository_config
  default_repository_ruleset_config = local.org_vars.default_repository_ruleset_config
  organization_rulesets             = local.org_vars.organization_rulesets
  repositories = {
    ".github" = {
      visibility = "public"
    }
    "ai-pr-reviewer" = {
      visibility                  = "public"
      has_downloads               = true
      has_projects                = true
      has_wiki                    = true
      homepage_url                = "https://coderabbit.ai"
      squash_merge_commit_message = "BLANK"
      squash_merge_commit_title   = "PR_TITLE"
    }
    "github-iac" = {
      visibility = "public"
      environments = [
        {
          name                = "github-iac-plan"
          can_admins_bypass   = false
          prevent_self_review = false
          reviewers = {
            users = [57728706]
            teams = []
          }
          deployment_branch_policy = {
            protected_branches     = true
            custom_branch_policies = false
          }
        },
        {
          name                = "github-iac-production"
          can_admins_bypass   = false
          prevent_self_review = false
          reviewers = {
            users = [57728706]
            teams = []
          }
          deployment_branch_policy = {
            protected_branches     = true
            custom_branch_policies = false
          }
        }
      ]
    }
    "grafana-iac" = {
      visibility = "public"
    }
    "homelab" = {
      visibility = "public"
      environments = [
        {
          name                = "homelab-plan"
          can_admins_bypass   = false
          prevent_self_review = false
          reviewers = {
            users = [57728706]
            teams = []
          }
          deployment_branch_policy = {
            protected_branches     = true
            custom_branch_policies = false
          }
        },
        {
          name                = "homelab-production"
          can_admins_bypass   = false
          prevent_self_review = false
          reviewers = {
            users = [57728706]
            teams = []
          }
          deployment_branch_policy = {
            protected_branches     = true
            custom_branch_policies = false
          }
        }
      ]
      ruleset = [
        {
          name                       = "main"
          creation                   = true
          deletion                   = true
          non_fast_forward           = true
          required_linear_history    = true
          require_signed_commits     = true
          update                     = false
          require_code_owner_reviews = false
          bypass_actors              = []
          pull_requests = [
            {
              allowed_merge_methods           = ["squash"]
              required_approving_review_count = 0
              require_code_owner_reviews      = false
            }
          ]
          required_status_checks = [
            {
              strict_required_status_checks_policy = true
              do_not_enforce_on_create             = false
              required_check = [
                {
                  context        = "policy-bot: main"
                  integration_id = 3280987
                },
                {
                  context        = "Lint"
                  integration_id = 15368
                },
                {
                  context        = "repo"
                  integration_id = 15368
                },
                {
                  context        = "Analyze (python)"
                  integration_id = 15368
                },
                {
                  context        = "analyze-actions"
                  integration_id = 15368
                },
                {
                  context        = "release-dry-run"
                  integration_id = 15368
                },
                {
                  context        = "Terragrunt Gate"
                  integration_id = 15368
                }
              ]
            }
          ]
        }
      ]
    }
    "hivemind" = {
      visibility = "public"
    }
    "octobot-deploy" = {
      archived = true
    }
    "personal-website" = {
      visibility = "public"
    }
    "policies" = {
      visibility = "public"
    }
    "renovate" = {
      visibility = "public"
    }
    "terragrunt-catalog" = {
      visibility = "public"
    }
    "workflows" = {
      visibility = "public"
    }
  }
}
