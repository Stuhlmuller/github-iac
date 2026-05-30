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
  provider "aws" {
    region = "us-east-1"
  }

  data "aws_ssm_parameter" "personal_access_token" {
    name = "/github-iac/personal_access_token"
  }

  provider "github" {
    owner = "${local.org_vars.organization}"
    token = data.aws_ssm_parameter.personal_access_token.value
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
    }
    "grafana-iac" = {
      visibility = "public"
    }
    "homelab" = {
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
