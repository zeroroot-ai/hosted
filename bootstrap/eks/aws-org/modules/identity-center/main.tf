# ----------------------------------------------------------------------------
# IAM Identity Center operator users + permission-set assignments.
#
# Previously operators were created BY HAND in the AWS console after the first
# apply (see the comment block this module replaces in the root
# identity-center.tf, and Step 7 of the README). That left no IaC audit trail
# and cost ~1h wall-clock per onboarding (deploy#539).
#
# This module declares each operator as an aws_identitystore_user and assigns
# the named permission sets against the management account via
# aws_ssoadmin_account_assignment. Onboarding a new operator is now a one-line
# append to the root `users` variable followed by `terraform apply`.
#
# The SSO instance ARN, identity store ID, and permission-set ARNs are resolved
# in the root workspace (data.aws_ssoadmin_instances + the
# aws_ssoadmin_permission_set resources) and passed in — this module owns no
# data sources of its own.
# ----------------------------------------------------------------------------

locals {
  # Key users by email (the unique user_name) so for_each gets stable,
  # human-readable addresses (e.g. module.identity_center.aws_identitystore_user.this["jane@example.com"]).
  users_by_email = { for u in var.users : u.email => u }

  # Flatten (user, permission_set) pairs into one assignment per pair. Each
  # assignment key is "<email>|<permission_set>" so the plan address is stable
  # and adding/removing a single grant does not churn the others.
  assignments = merge([
    for email, u in local.users_by_email : {
      for ps in u.permission_sets : "${email}|${ps}" => {
        email          = email
        permission_set = ps
      }
    }
  ]...)
}

resource "aws_identitystore_user" "this" {
  for_each = local.users_by_email

  identity_store_id = var.identity_store_id

  display_name = "${each.value.given_name} ${each.value.family_name}"
  user_name    = each.value.email

  name {
    given_name  = each.value.given_name
    family_name = each.value.family_name
  }

  emails {
    value   = each.value.email
    primary = true
  }
}

resource "aws_ssoadmin_account_assignment" "this" {
  for_each = local.assignments

  instance_arn       = var.sso_instance_arn
  permission_set_arn = var.permission_set_arns[each.value.permission_set]

  principal_id   = aws_identitystore_user.this[each.value.email].user_id
  principal_type = "USER"

  target_id   = var.target_account_id
  target_type = "AWS_ACCOUNT"
}
