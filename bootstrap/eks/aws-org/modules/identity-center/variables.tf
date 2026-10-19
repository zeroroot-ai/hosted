# ----------------------------------------------------------------------------
# Inputs for the identity-center module.
#
# The SSO instance, identity store, and permission sets are owned by the root
# workspace (identity-center.tf). They are passed in so this module stays a
# pure user + assignment declaration with no data-source lookups of its own —
# the root resolves the instance once and hands the ARNs down.
# ----------------------------------------------------------------------------

variable "sso_instance_arn" {
  description = "ARN of the IAM Identity Center instance (data.aws_ssoadmin_instances.this.arns[0] in the root workspace)."
  type        = string
}

variable "identity_store_id" {
  description = "Identity store ID backing the Identity Center instance (data.aws_ssoadmin_instances.this.identity_store_ids[0] in the root workspace)."
  type        = string
}

variable "target_account_id" {
  description = "12-digit AWS account ID that permission sets are assigned against. For operator access this is the zeroroot-ai-mgmt management account (operators then cross-account assume-role into zeroroot-ai-prod)."
  type        = string
}

variable "permission_set_arns" {
  description = "Map of permission-set key -> ARN. Keys are referenced by each user's permission_sets list. Populated from the aws_ssoadmin_permission_set resources in the root identity-center.tf (e.g. { ZeroDayAIProdAdmin = aws_ssoadmin_permission_set.gibson_prod_admin.arn, ... })."
  type        = map(string)
}

variable "users" {
  description = <<-EOT
    Operator users to declare in the Identity Center identity store and the
    permission sets each is assigned against the target account.

    Each entry:
      - given_name:      first name (Identity Center "first name").
      - family_name:     last name (Identity Center "last name").
      - email:           primary email; also used as the unique user_name.
      - permission_sets: list of permission-set keys (must exist in
                         var.permission_set_arns) assigned to this user
                         against var.target_account_id. Empty list = user
                         created with no assignments yet.

    Adding an operator is a one-line append here via the root `users` variable
    plus `terraform apply`.
  EOT
  type = list(object({
    given_name      = string
    family_name     = string
    email           = string
    permission_sets = optional(list(string), [])
  }))
  default = []

  validation {
    condition     = length(var.users) == length(distinct([for u in var.users : u.email]))
    error_message = "Each user email must be unique; email is used as the Identity Center user_name."
  }
}
