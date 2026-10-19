# ----------------------------------------------------------------------------
# Common tag set applied via provider default_tags AND on resources where
# AWS does not honour default_tags (some Organizations resources).
# ----------------------------------------------------------------------------

locals {
  # Object-ARN prefixes of the per-workspace platform audit buckets, for the
  # CloudTrail S3 data-event selector (deploy#1200). The buckets live in the
  # member account and are created by eks/<workspace>/modules/s3, whose naming
  # is "<workspace_name>-audit-<account_id>" — reconstructed here rather than
  # plumbed through remote state, because a cross-workspace state read would
  # make this org-level trail depend on a workspace that may not exist yet.
  # Keep in step with modules/s3's aws_s3_bucket.this bucket name expression.
  #
  # Empty until prod_account_id is populated (first apply creates the account).
  platform_audit_bucket_object_arn_prefixes = length(var.prod_account_id) > 0 ? [
    for ws in var.platform_workspace_names :
    "arn:aws:s3:::${ws}-audit-${var.prod_account_id}/"
  ] : []

  common_tags = {
    Environment = "org"
    Project     = "zeroroot-ai"
    Owner       = "platform"
    CostCenter  = "platform-shared"
    ManagedBy   = "terraform"
    Workspace   = "aws-org"
  }
}
