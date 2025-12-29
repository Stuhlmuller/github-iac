locals {
  org_vars     = read_terragrunt_config(find_in_parent_folders("organization.hcl"))
  organization = local.org_vars.locals.organization
}

generate "provider" {
  path      = "tg-provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
  provider "aws" {region = "us-east-1"}
  data "aws_ssm_parameter" "personal_access_token" {
    name = "/github-iac/personal_access_token"
  }

  provider "github" {
    owner = "${local.organization}"
    token = data.aws_ssm_parameter.personal_access_token.value
  }
  EOF
}
