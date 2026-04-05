# github_repositories

This module reconciles GitHub repositories for an organization from a single list of repository configurations plus an organization-wide default configuration.

It does three things:

1. Reads all repositories in the organization with `data.github_repositories`.
2. Merges explicit `repositories` entries with `default_repository_config`.
3. Imports discovered repositories into OpenTofu state and manages them with the merged configuration.
4. Applies per-repository rulesets derived from `default_repository_ruleset_config` and each repository's `ruleset` list.

## Requirements

- OpenTofu with support for iterable `import` blocks.
- `integrations/github` provider `6.6.x`.

## Inputs

- `organization`: GitHub organization name.
- `repositories`: Map of repository-specific overrides keyed by repository name.
- `default_repository_config`: Baseline settings used for all repositories and applied automatically to discovered repositories that are not explicitly configured.
- `default_repository_ruleset_config`: Baseline ruleset settings merged into every ruleset entry.
- `results_per_page`: Page size for the GitHub repository search data source.

## Example

```hcl
module "github_repositories" {
  source = "../../modules/github_repositories"

  organization = "Stuhlmuller"

  default_repository_config = {
    visibility                 = "private"
    delete_branch_on_merge     = true
    allow_merge_commit         = false
    allow_squash_merge         = false
    allow_rebase_merge         = true
    default_branch             = "main"
    rename_default_branch      = true
    ruleset                    = [{ name = "main" }]
  }

  default_repository_ruleset_config = {
    target                 = "branch"
    enforcement            = "active"
    require_signed_commits = true
    conditions = [{
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }]
    creation = true
    deletion = true
  }

  repositories = {
    github-iac = {
      description = "Infrastructure as Code for GitHub repositories"
      visibility  = "public"
    }
    workflows = {
      description = "Shared GitHub workflows"
      visibility  = "public"
    }
  }
}
```

## Notes

- Repositories returned by the GitHub search API but omitted from `repositories` inherit `default_repository_config`.
- Repositories returned by the GitHub search API but omitted from `repositories` also inherit the default `ruleset` list from `default_repository_config`.
- Each ruleset entry is merged with `default_repository_ruleset_config`, so you can define a common ruleset once and only override repo-specific differences.
- `default_branch` is only managed when it is set in the effective configuration.
- GitHub's repository search API returns a maximum of 1000 repositories for this data source.
