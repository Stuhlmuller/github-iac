output "configured_repository_names" {
  description = "Repositories explicitly configured through var.repositories."
  value       = sort(keys(local.configured_repositories))
}

output "defaulted_repository_names" {
  description = "Repositories discovered in the organization that inherited var.default_repository_config."
  value       = local.repositories_using_default_config
}

output "discovered_repository_names" {
  description = "Repositories discovered in the organization through the github_repositories data source."
  value       = sort(tolist(local.discovered_repository_names))
}

output "managed_repository_names" {
  description = "All repositories managed by this module after merging configured and discovered repositories."
  value       = sort(keys(local.effective_repositories))
}

output "repositories_to_create" {
  description = "Configured repositories that were not discovered in the organization and will be created."
  value       = local.repositories_to_create
}

output "effective_repositories" {
  description = "Effective repository settings after merging defaults with repository-specific overrides."
  value       = local.effective_repositories
}
