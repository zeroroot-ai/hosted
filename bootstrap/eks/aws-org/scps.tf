# ----------------------------------------------------------------------------
# Service Control Policies (ADR-0073).
#
# Two SCPs:
#   1. DenyRootUserActions       (R0.6): denies each action of the root user.
#   2. DenyRegionsExceptUSEast1  (R0.3): pins regional services to us-east-1.
#      It permits the global services.
#
# Where they attach:
#   - Directly to the workload account (aws_organizations_account.prod). The
#     account sits under the org root, outside the workload OU, so only a
#     direct attachment reaches it (deploy#1124).
#   - To aws_organizations_organizational_unit.workload, for an account that
#     joins that OU later. Neither attaches to the org root, so the
#     management account is not affected.
#
# RequireTagsOnResources and DenyNonHIPAAEligibleServices are deleted (owner
# decision of 2026-10-05, hosted#418). They attached to the OU only, and the
# OU holds no account.
#
# Each SCP body is committed under policies/ as JSON. Terraform reads it with
# file(). scripts/check-scp-attachments.py fails when the set of account
# attachments is not exactly these two, or when a policy attaches to nothing.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# 1. DenyRootUserActions
# ----------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_root_user" {
  name        = "DenyRootUserActions"
  description = "Belt-and-suspenders block on every action when the principal ARN is the root user (arn:aws:iam::*:root). R0.6."
  type        = "SERVICE_CONTROL_POLICY"

  content = file("${path.module}/policies/deny-root-user.json")

  tags = local.common_tags
}

resource "aws_organizations_policy_attachment" "deny_root_user" {
  policy_id = aws_organizations_policy.deny_root_user.id
  target_id = aws_organizations_organizational_unit.workload.id
}

# ----------------------------------------------------------------------------
# 2. DenyRegionsExceptUSEast1
# ----------------------------------------------------------------------------

resource "aws_organizations_policy" "deny_regions_except_us_east_1" {
  name        = "DenyRegionsExceptUSEast1"
  description = "Region pinning. Allows global services (iam, sts, organizations, cloudfront, route53, support, trustedadvisor, ce, budgets) and denies regional services in any region other than us-east-1. R0.3."
  type        = "SERVICE_CONTROL_POLICY"

  content = file("${path.module}/policies/deny-regions-except-us-east-1.json")

  tags = local.common_tags
}

resource "aws_organizations_policy_attachment" "deny_regions_except_us_east_1" {
  policy_id = aws_organizations_policy.deny_regions_except_us_east_1.id
  target_id = aws_organizations_organizational_unit.workload.id
}

# ----------------------------------------------------------------------------
# Direct attachments to the workload account (deploy#1124). The header states
# why. scripts/check-scp-attachments.py holds the set to exactly these two.
# ----------------------------------------------------------------------------

resource "aws_organizations_policy_attachment" "deny_root_user_prod_account" {
  policy_id = aws_organizations_policy.deny_root_user.id
  target_id = aws_organizations_account.prod.id
}

resource "aws_organizations_policy_attachment" "deny_regions_except_us_east_1_prod_account" {
  policy_id = aws_organizations_policy.deny_regions_except_us_east_1.id
  target_id = aws_organizations_account.prod.id
}
