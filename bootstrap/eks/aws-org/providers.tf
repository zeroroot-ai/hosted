# ----------------------------------------------------------------------------
# Provider configuration.
#
# The default `aws` provider authenticates as a principal in the zeroroot-ai-mgmt
# account (the org-management account). Operators run this workspace from a
# session that has assumed an Identity Center permission set in zeroroot-ai-mgmt
# with sufficient permissions to manage Organizations, Identity Center,
# CloudTrail, and S3 in mgmt.
#
# A second provider alias `prod` is used by the cross-account role and
# state-bucket-prep resources that need to land IN the zeroroot-ai-prod workload
# account. It assumes the ZeroDayAIProdAdmin role in zeroroot-ai-prod (created
# elsewhere in this workspace via assume_role at provider config time).
# ----------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Provider alias for resources that must land in zeroroot-ai-prod.
# Once the ZeroDayAIProdAdmin role exists, operators set the
# `prod_account_id` variable and re-init; before that, the workspace can
# still apply the mgmt-only resources by leaving prod_account_id empty
# (the prod-aliased resources are gated on length(var.prod_account_id) > 0).
provider "aws" {
  alias  = "prod"
  region = var.aws_region

  assume_role {
    role_arn     = length(var.prod_account_id) > 0 ? "arn:aws:iam::${var.prod_account_id}:role/OrganizationAccountAccessRole" : null
    session_name = "aws-org-workspace-prod-bootstrap"
  }

  default_tags {
    tags = local.common_tags
  }
}
