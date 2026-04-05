variable "organization" {
  type        = string
  description = "GitHub organization name to reconcile."

  validation {
    condition     = trimspace(var.organization) != ""
    error_message = "organization must not be empty."
  }
}

variable "repositories" {
  description = "Repository-specific overrides keyed by repository name. Existing repositories that are not listed here inherit default_repository_config."
  type = map(object({
    description                = optional(string)
    visibility                 = optional(string)
    homepage_url               = optional(string)
    gitignore_template         = optional(string)
    default_branch             = optional(string)
    rename_default_branch      = optional(bool)
    require_code_owner_reviews = optional(bool)
    is_template                = optional(bool)
    repository_template = optional(object({
      owner                = string
      repository           = string
      include_all_branches = optional(bool)
    }))
    ruleset                     = optional(list(any))
    delete_branch_on_merge      = optional(bool)
    has_downloads               = optional(bool)
    has_issues                  = optional(bool)
    has_projects                = optional(bool)
    has_wiki                    = optional(bool)
    allow_update_branch         = optional(bool)
    allow_auto_merge            = optional(bool)
    allow_merge_commit          = optional(bool)
    allow_squash_merge          = optional(bool)
    squash_merge_commit_message = optional(string)
    squash_merge_commit_title   = optional(string)
    allow_rebase_merge          = optional(bool)
    archived                    = optional(bool)
    auto_init                   = optional(bool)
    vulnerability_alerts        = optional(bool)
  }))
  default = {}
}

variable "default_repository_config" {
  description = "Default repository configuration applied to repositories omitted from var.repositories and used as the baseline for configured repositories."
  type = object({
    description                = optional(string, "")
    visibility                 = optional(string, "private")
    homepage_url               = optional(string)
    gitignore_template         = optional(string)
    default_branch             = optional(string)
    rename_default_branch      = optional(bool, false)
    require_code_owner_reviews = optional(bool, false)
    is_template                = optional(bool, false)
    repository_template = optional(object({
      owner                = string
      repository           = string
      include_all_branches = optional(bool)
    }))
    ruleset                     = optional(list(any), [{ name = "main" }])
    delete_branch_on_merge      = optional(bool, true)
    has_downloads               = optional(bool)
    has_issues                  = optional(bool)
    has_projects                = optional(bool)
    has_wiki                    = optional(bool)
    allow_update_branch         = optional(bool, false)
    allow_auto_merge            = optional(bool, false)
    allow_merge_commit          = optional(bool, false)
    allow_squash_merge          = optional(bool, false)
    squash_merge_commit_message = optional(string)
    squash_merge_commit_title   = optional(string, "COMMIT_OR_PR_TITLE")
    allow_rebase_merge          = optional(bool, true)
    archived                    = optional(bool, false)
    auto_init                   = optional(bool, true)
    vulnerability_alerts        = optional(bool)
  })
  default = {}
}

variable "default_repository_ruleset_config" {
  type        = any
  description = "Default settings for a repository ruleset. This is merged with each ruleset entry in repository ruleset lists."
  default     = {}
}

variable "repository_ruleset_imports" {
  description = "Repository rulesets to import, keyed by the Terraform ruleset key (<repository>.<ruleset_name>)."
  type = map(object({
    ruleset_id = number
  }))
  default = {}
}

variable "results_per_page" {
  type        = number
  default     = 100
  description = "Page size for the github_repositories search. GitHub caps this at 100."

  validation {
    condition     = var.results_per_page >= 1 && var.results_per_page <= 100
    error_message = "results_per_page must be between 1 and 100."
  }
}
