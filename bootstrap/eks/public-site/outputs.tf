output "docs_staging_bucket_name" {
  description = "Bucket the docs-site publish workflow syncs a pre-release build into."
  value       = module.docs_staging.bucket_name
}

output "docs_staging_distribution_id" {
  description = "Distribution to invalidate after a pre-release docs publish."
  value       = module.docs_staging.distribution_id
}
