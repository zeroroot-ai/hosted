# ----------------------------------------------------------------------------
# Outputs consumed by:
# - the zeroroot-ai-prod-bootstrap workspace (prod_account_id flows into its
#   provider config)
# - the zeroroot-ai-prod workspace (cloudtrail bucket arn is referenced by the
#   guardduty-config module's findings export)
# - operators who paste prod_account_id into the cross-account assume-role
#   flow
# ----------------------------------------------------------------------------

output "workload_ou_id" {
  description = "OU ID for the workload OU. SCPs attach here; future workload accounts (e.g. gibson-staging) land here."
  value       = aws_organizations_organizational_unit.workload.id
}

output "prod_account_id" {
  description = "12-digit AWS account ID for zeroroot-ai-prod."
  value       = aws_organizations_account.prod.id
}

output "cloudtrail_bucket_name" {
  description = "Name of the org-wide CloudTrail destination bucket."
  value       = aws_s3_bucket.cloudtrail.id
}

output "state_bucket_name" {
  description = "Name of the aws-org workspace's own state bucket. Used in the local→s3 backend migration step."
  value       = aws_s3_bucket.state.id
}

output "state_lock_table_name" {
  description = "Name of the aws-org workspace's DynamoDB state-lock table."
  value       = aws_dynamodb_table.state_lock.name
}

output "state_kms_key_arn" {
  description = "ARN of the KMS key encrypting the aws-org state bucket."
  value       = aws_kms_key.state.arn
}

# The ArgoCD admins Identity Center group (and its outputs) were removed with
# identity-center-argocd-sso.tf: ops SSO moved to a pluggable github|gitlab|oidc
# Dex connector configured per-cluster in bootstrap/modules/argocd
# (reworks deploy#1332). Admin is now granted by the provider's own group.

output "exit_test_node_access_role_arn" {
  description = "ARN of exit-test-node-access. Set it as the hosted repository variable EXIT_TEST_NODE_ROLE_ARN."
  value       = length(var.prod_account_id) > 0 ? aws_iam_role.exit_test_node_access[0].arn : null
}
