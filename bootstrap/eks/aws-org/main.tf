# ----------------------------------------------------------------------------
# AWS Organizations + workload OU + zeroroot-ai-prod member account.
#
# Apply order (within this workspace):
#   1. aws_organizations_organization (zeroroot creates the org)
#   2. aws_organizations_organizational_unit (workload OU)
#   3. aws_organizations_account (zeroroot-ai-prod, lands in workload OU)
#   4. SCPs (scps.tf) attach to the workload OU
#   5. Identity Center permission sets (identity-center.tf)
#   6. CloudTrail org trail (cloudtrail.tf) — applies once org creation completes
#   7. Cross-account role + permission boundary in zeroroot-ai-prod
#      (cross-account-roles.tf) — needs prod_account_id var populated
#
# Notes:
# - close_on_deletion = false because closing an AWS account programmatically
#   is irreversible and AWS rate-limits closes anyway.
# - iam_user_access_to_billing = "DENY" — billing in workload accounts is
#   read-only via the cross-account role (operators with BillingViewer
#   permission set in mgmt see all billing).
# - Service-access principals: only what AWS Organizations REQUIRES by
#   default. Identity Center, CloudTrail, GuardDuty get added explicitly
#   below.
# ----------------------------------------------------------------------------

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # Trusted service-access principals — minimum required for the SCP +
  # Identity Center + CloudTrail wiring this workspace owns. Adding new
  # services here is a deliberate org-policy change.
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "guardduty.amazonaws.com",
    "access-analyzer.amazonaws.com",
    "sso.amazonaws.com",
    "ram.amazonaws.com",
    # Enabled live during the 447 staging EKS standup / root-credential
    # management work (deploy#696 reconciliation): removing a trusted
    # service org-wide silently breaks that service's cross-account
    # integrations, so config declares what is live. Deliberate removals
    # only, with an operator plan review.
    "eks.amazonaws.com",
    "iam.amazonaws.com",
  ]

  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY",
    "TAG_POLICY",
  ]
}

resource "aws_organizations_organizational_unit" "workload" {
  name      = "workload"
  parent_id = aws_organizations_organization.this.roots[0].id

  tags = local.common_tags
}

resource "aws_organizations_account" "prod" {
  name      = var.prod_account_name
  email     = var.prod_account_email
  parent_id = aws_organizations_organizational_unit.workload.id

  iam_user_access_to_billing = "DENY"

  # Closing an account is a 90-day irreversible operation that breaks
  # downstream Terraform state. Always set false; manual close only with
  # explicit operator approval.
  close_on_deletion = false

  # The default OrganizationAccountAccessRole AWS provisions on account
  # creation is the bootstrap principal we use ONCE to apply
  # zeroroot-ai-prod-bootstrap. After ZeroDayAIProdAdmin is provisioned in
  # cross-account-roles.tf, that becomes the canonical operator path.
  role_name = "OrganizationAccountAccessRole"

  tags = merge(local.common_tags, {
    Environment = "prod"
    Owner       = "platform"
    CostCenter  = "platform-prod"
  })

  lifecycle {
    # Once created, do not allow Terraform to recreate the account if
    # the email or name drifts — both are change-on-AWS-side operations
    # and a recreate would orphan the workload account.
    #
    # parent_id (deploy#696): the live workload account (447184491447,
    # ADR-0073 staging/prod co-tenant) sits under the org ROOT, not the
    # workload OU. Letting Terraform "reconcile" it into the OU would
    # move the account under each policy of that OU. The OU move is a
    # deliberate operator decision, never an implicit plan side-effect.
    #
    # iam_user_access_to_billing (deploy#696): not readable via the
    # Organizations API after account creation, so on an imported
    # account the null->"DENY" diff would otherwise force a replacement.
    ignore_changes = [email, name, role_name, parent_id, iam_user_access_to_billing]
  }
}

# ============================================================================
# Budgets — created in the payer (mgmt) account. AWS Budgets API rejects
# CreateBudget calls from linked accounts; cost categories rejected the
# same way. Alarms on zeroroot-ai-prod spend are set HERE and target the
# linked account's cost via the standard 'Account' dimension.
# ============================================================================

module "budgets" {
  source = "./modules/budgets"

  alerts_email_address   = var.alerts_email_address
  soft_alert_amount      = 1000
  hard_alert_amount      = 3000
  emergency_alert_amount = 5000
}

# ============================================================================
# Identity Center operator users + permission-set assignments.
#
# The SSO instance, identity store, and the three permission sets are owned by
# identity-center.tf. This module declares each operator as an
# aws_identitystore_user and assigns the named permission sets against the
# management account (operators then cross-account assume-role into
# zeroroot-ai-prod). Onboarding an operator is a one-line append to the `users`
# variable in terraform.tfvars — no more console clicks (deploy#539).
# ============================================================================

module "identity_center" {
  source = "./modules/identity-center"

  sso_instance_arn  = local.sso_instance_arn
  identity_store_id = local.identity_store_id
  target_account_id = data.aws_caller_identity.mgmt.account_id

  permission_set_arns = {
    ZeroDayAIProdAdmin    = aws_ssoadmin_permission_set.gibson_prod_admin.arn
    ZeroDayAIProdReadOnly = aws_ssoadmin_permission_set.gibson_prod_readonly.arn
    BillingViewer         = aws_ssoadmin_permission_set.billing_viewer.arn
  }

  users = var.users
}
