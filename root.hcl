locals {
  common_vars = yamldecode(file(find_in_parent_folders("common.yml")))

  project_name = local.common_vars.project_name
  default_tags = local.common_vars.default_tags
}

terraform {
  extra_arguments "plan" {
    commands  = ["plan"]
    arguments = ["-out", "plan.out"]
  }
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    bucket       = "rstuhlmuller-aws-s3-use1-datalake"
    key          = "IaC/${lower(local.project_name)}/${path_relative_to_include()}/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

inputs = {
  project_name = local.project_name
  tags         = local.default_tags
}
