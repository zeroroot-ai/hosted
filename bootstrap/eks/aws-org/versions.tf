# ----------------------------------------------------------------------------
# Terraform + provider version constraints for the aws-org workspace.
#
# This workspace owns:
#   - AWS Organizations + workload OU + zeroroot-ai-prod member account
#   - Service Control Policies (DenyRootUserActions,
#     DenyRegionsExceptUSEast1)
#   - IAM Identity Center permission sets (no upstream IdP)
#   - Cross-account role into zeroroot-ai-prod (with permission boundary)
#   - Org-wide CloudTrail in zeroroot-ai-mgmt
#   - mgmt-account state bucket + DynamoDB lock table for THIS workspace's
#     own state (NOT the zeroroot-ai-prod workspace's state, which lives in the
#     workload account per design.md)
#   - Security findings bucket in zeroroot-ai-mgmt for GuardDuty exports from
#     zeroroot-ai-prod
#   - GitHub Actions OIDC trust + tf-plan/tf-apply roles for the gitops repo
#
# Lifecycle: applied once at org bootstrap, then once or twice per year as
# SCPs / permission sets evolve. Owned by the org-management role; never
# applied from CI in the per-app pipeline.
# ----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
