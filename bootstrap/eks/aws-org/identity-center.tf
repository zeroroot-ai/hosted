# ----------------------------------------------------------------------------
# IAM Identity Center — three permission sets, no upstream IdP at launch.
#
# Operator users and their permission-set assignments are declared in
# Terraform via modules/identity-center (wired from main.tf, sourced from the
# `users` variable). The deliberate non-federation posture is documented in
# design.md and runbooks/RUNBOOK-incident.md as a known limitation: "if Zitadel
# is down, you can still get into AWS to fix it" — users live directly in the
# Identity Center identity store, not behind an external IdP.
#
# Permission sets:
#   - ZeroDayAIProdAdmin   — assumes ZeroDayAIProdAdmin in zeroroot-ai-prod, capped by PB.
#   - ZeroDayAIProdReadOnly — assumes a read-only role in zeroroot-ai-prod for triage.
#   - BillingViewer     — read-only billing in zeroroot-ai-mgmt for cost reviews.
#
# Session duration is 4 hours per design (forces frequent re-auth, limits
# stolen-credential blast radius).
# ----------------------------------------------------------------------------

data "aws_ssoadmin_instances" "this" {}

locals {
  identity_store_id      = data.aws_ssoadmin_instances.this.identity_store_ids[0]
  sso_instance_arn       = data.aws_ssoadmin_instances.this.arns[0]
  permission_set_session = "PT4H"
}

# ----------------------------------------------------------------------------
# ZeroDayAIProdAdmin — full admin in zeroroot-ai-prod via the ZeroDayAIProdAdmin role
# (in cross-account-roles.tf), capped by PB-OperatorMaxPermissions.
# ----------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set" "gibson_prod_admin" {
  name             = "ZeroDayAIProdAdmin"
  description      = "Full admin in zeroroot-ai-prod via cross-account assume-role to ZeroDayAIProdAdmin (capped by PB-OperatorMaxPermissions). 4-hour session."
  instance_arn     = local.sso_instance_arn
  session_duration = local.permission_set_session

  tags = local.common_tags
}

resource "aws_ssoadmin_managed_policy_attachment" "gibson_prod_admin" {
  instance_arn       = local.sso_instance_arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  permission_set_arn = aws_ssoadmin_permission_set.gibson_prod_admin.arn
}

# ----------------------------------------------------------------------------
# ZeroDayAIProdReadOnly — read-only triage in zeroroot-ai-prod.
# ----------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set" "gibson_prod_readonly" {
  name             = "ZeroDayAIProdReadOnly"
  description      = "Read-only triage access into zeroroot-ai-prod for incident response. 4-hour session."
  instance_arn     = local.sso_instance_arn
  session_duration = local.permission_set_session

  tags = local.common_tags
}

resource "aws_ssoadmin_managed_policy_attachment" "gibson_prod_readonly" {
  instance_arn       = local.sso_instance_arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
  permission_set_arn = aws_ssoadmin_permission_set.gibson_prod_readonly.arn
}

# ----------------------------------------------------------------------------
# BillingViewer — read-only billing on zeroroot-ai-mgmt for cost reviews.
# ----------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set" "billing_viewer" {
  name             = "BillingViewer"
  description      = "Read-only billing + Cost Explorer on zeroroot-ai-mgmt. 4-hour session. Used for weekly cost reviews per R10.3."
  instance_arn     = local.sso_instance_arn
  session_duration = local.permission_set_session

  tags = local.common_tags
}

resource "aws_ssoadmin_managed_policy_attachment" "billing_viewer" {
  instance_arn       = local.sso_instance_arn
  managed_policy_arn = "arn:aws:iam::aws:policy/job-function/Billing"
  permission_set_arn = aws_ssoadmin_permission_set.billing_viewer.arn
}

# ----------------------------------------------------------------------------
# Operator users (aws_identitystore_user) and their permission-set assignments
# (aws_ssoadmin_account_assignment) are declared in modules/identity-center,
# wired from main.tf. The three permission-set ARNs above flow into that module
# as `permission_set_arns`, and the operator list comes from the `users`
# variable. Onboarding a new operator is now a Terraform PR (append to the
# `users` entry in terraform.tfvars + apply), not a console action — see
# deploy#539 and RUNBOOK-account-bootstrap.md.
# ----------------------------------------------------------------------------
