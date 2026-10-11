terraform {
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.12.0"
    }
  }
}

variable "installation_id" {
  description = "Installation ID of the private Stuhlmuller Cordium Runners App."
  type        = string
}

data "github_app" "cordium" {
  slug = "stuhlmuller-cordium-runners"
}

import {
  to = github_app_installation_repositories.cordium
  id = var.installation_id
}

resource "github_app_installation_repositories" "cordium" {
  installation_id       = var.installation_id
  selected_repositories = ["homelab"]

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = data.github_app.cordium.id == "5270069"
      error_message = "The Cordium runner App identity changed; review before granting repository access."
    }
  }
}
