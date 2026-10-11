include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/cordium_runners"
}

generate "provider" {
  path      = "github-provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
  provider "github" {
    owner = "Stuhlmuller"
  }
  EOF
}

inputs = {
  installation_id = "170148721"
}
