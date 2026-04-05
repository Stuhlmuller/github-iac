data "github_repositories" "organization" {
  query            = format("org:%s", var.organization)
  include_repo_id  = true
  results_per_page = var.results_per_page
}

locals {
  effective_default_repository_ruleset_config = merge(
    {
      name                       = ""
      target                     = "branch"
      enforcement                = "active"
      require_code_owner_reviews = true
      require_signed_commits     = true
      conditions = [{
        include = ["~DEFAULT_BRANCH"]
        exclude = []
      }]
      creation                = true
      update                  = false
      deletion                = true
      required_linear_history = true
      bypass_actors           = []
      required_deployments    = []
      required_status_checks  = []
      pull_requests           = []
    },
    var.default_repository_ruleset_config,
  )

  configured_repositories = {
    for name, repository in var.repositories :
    name => merge(
      var.default_repository_config,
      { for key, value in repository : key => value if value != null }
    )
  }

  discovered_repository_names = toset(data.github_repositories.organization.names)

  defaulted_repositories = {
    for name in sort(tolist(setsubtract(local.discovered_repository_names, toset(keys(local.configured_repositories))))) :
    name => var.default_repository_config
  }

  effective_repositories = merge(local.defaulted_repositories, local.configured_repositories)

  imported_repositories = {
    for name in sort(tolist(local.discovered_repository_names)) :
    name => name
    if contains(keys(local.effective_repositories), name)
  }

  repositories_with_managed_default_branch = {
    for name, repository in local.effective_repositories :
    name => repository
    if repository.default_branch != null
  }

  repository_rulesets = flatten([
    for repository_name, repository_config in local.effective_repositories : [
      for ruleset in try(repository_config.ruleset, []) :
      merge(
        local.effective_default_repository_ruleset_config,
        ruleset,
        {
          repository                 = repository_name
          require_code_owner_reviews = try(repository_config.require_code_owner_reviews, false)
          archived_repository        = try(repository_config.archived, false)
        }
      )
    ] if repository_config.visibility != "private"
  ])

  imported_repository_rulesets = {
    for ruleset in local.repository_rulesets :
    "${ruleset.repository}.${ruleset.name}" => {
      repository = ruleset.repository
      ruleset_id = var.repository_ruleset_imports["${ruleset.repository}.${ruleset.name}"].ruleset_id
    }
    if try(ruleset.archived_repository, false) == false && try(var.repository_ruleset_imports["${ruleset.repository}.${ruleset.name}"], null) != null
  }

  imported_branch_defaults = {
    for name, repository in local.repositories_with_managed_default_branch :
    name => name
    if contains(local.discovered_repository_names, name)
  }

  repositories_using_default_config = sort(keys(local.defaulted_repositories))
  repositories_to_create            = sort(tolist(setsubtract(toset(keys(local.effective_repositories)), local.discovered_repository_names)))
}

import {
  for_each = local.imported_repositories
  to       = github_repository.this[each.key]
  id       = each.value
}

resource "github_repository" "this" {
  # checkov:skip=CKV_GIT_1: The module intentionally allows public repositories through configuration.
  for_each = local.effective_repositories

  name         = each.key
  description  = each.value.description
  visibility   = each.value.visibility
  homepage_url = each.value.homepage_url

  auto_init              = each.value.repository_template == null ? each.value.auto_init : false
  gitignore_template     = each.value.repository_template == null ? each.value.gitignore_template : null
  is_template            = each.value.is_template
  delete_branch_on_merge = each.value.delete_branch_on_merge
  has_downloads          = each.value.has_downloads
  has_issues             = each.value.has_issues
  has_projects           = each.value.has_projects
  has_wiki               = each.value.has_wiki

  allow_update_branch         = each.value.allow_update_branch
  allow_auto_merge            = each.value.allow_auto_merge
  allow_merge_commit          = each.value.allow_merge_commit
  allow_squash_merge          = each.value.allow_squash_merge
  squash_merge_commit_message = each.value.squash_merge_commit_message
  squash_merge_commit_title   = each.value.squash_merge_commit_title
  allow_rebase_merge          = each.value.allow_rebase_merge
  archived                    = each.value.archived
  vulnerability_alerts        = each.value.vulnerability_alerts

  dynamic "template" {
    for_each = each.value.repository_template != null ? { selected = each.value.repository_template } : {}
    content {
      owner                = template.value.owner
      repository           = template.value.repository
      include_all_branches = template.value.include_all_branches
    }
  }

  lifecycle {
    ignore_changes = [
      auto_init,
      gitignore_template,
      template,
      description
    ]
  }
}

resource "github_repository_ruleset" "this" {
  for_each = {
    for ruleset in local.repository_rulesets :
    "${ruleset.repository}.${ruleset.name}" => ruleset
    if try(ruleset.archived_repository, false) == false
  }

  name        = each.value.name
  repository  = github_repository.this[each.value.repository].name
  target      = each.value.target
  enforcement = each.value.enforcement

  dynamic "conditions" {
    for_each = try(each.value.conditions, [])
    content {
      ref_name {
        include = try(conditions.value.include, [])
        exclude = try(conditions.value.exclude, [])
      }
    }
  }

  dynamic "bypass_actors" {
    for_each = try(each.value.bypass_actors, [])
    content {
      actor_id    = bypass_actors.value.actor_id
      actor_type  = bypass_actors.value.actor_type
      bypass_mode = bypass_actors.value.bypass_mode
    }
  }

  rules {
    creation                = try(each.value.creation, false)
    update                  = try(each.value.update, false)
    deletion                = try(each.value.deletion, false)
    required_linear_history = try(each.value.required_linear_history, false)
    required_signatures     = try(each.value.require_signed_commits, false)

    dynamic "required_deployments" {
      for_each = try(each.value.required_deployments, [])
      content {
        required_deployment_environments = required_deployments.value.required_deployment_environments
      }
    }

    dynamic "pull_request" {
      for_each = try(each.value.pull_requests, [])
      content {
        required_approving_review_count = try(pull_request.value.required_approving_review_count, null)
        require_code_owner_review       = try(pull_request.value.require_code_owner_reviews, each.value.require_code_owner_reviews)
      }
    }

    dynamic "required_status_checks" {
      for_each = try(each.value.required_status_checks, [])
      content {
        strict_required_status_checks_policy = try(required_status_checks.value.strict_required_status_checks_policy, null)
        do_not_enforce_on_create             = try(required_status_checks.value.do_not_enforce_on_create, null)

        dynamic "required_check" {
          for_each = try(required_status_checks.value.required_check, [])
          content {
            context        = required_check.value.context
            integration_id = try(required_check.value.integration_id, null)
          }
        }
      }
    }
  }

  depends_on = [github_repository.this]
}

import {
  for_each = local.imported_repository_rulesets
  to       = github_repository_ruleset.this[each.key]
  id       = format("%s:%d", each.value.repository, each.value.ruleset_id)
}

import {
  for_each = local.imported_branch_defaults
  to       = github_branch_default.this[each.key]
  id       = each.value
}

resource "github_branch_default" "this" {
  for_each = local.repositories_with_managed_default_branch

  repository = github_repository.this[each.key].name
  branch     = each.value.default_branch
  rename     = each.value.rename_default_branch
}
