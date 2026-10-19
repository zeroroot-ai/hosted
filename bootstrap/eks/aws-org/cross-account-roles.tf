# ----------------------------------------------------------------------------
# Cross-account roles in zeroroot-ai-prod, assumed by Identity Center sessions in
# zeroroot-ai-mgmt.
#
# This file uses the `aws.prod` provider alias which assumes
# OrganizationAccountAccessRole in zeroroot-ai-prod. That alias is only configured
# when var.prod_account_id is non-empty — first apply of this workspace
# leaves these resources unset; second apply (after zeroroot-ai-prod exists)
# populates the var and provisions the roles.
#
# Roles created:
#   - ZeroDayAIProdAdmin   — admin, capped by PB-OperatorMaxPermissions.
#   - ZeroDayAIProdReadOnly — read-only, no boundary needed (AWS managed RO is
#                          inherently bounded).
#
# Session duration is 4 hours (matches Identity Center permission set).
# ----------------------------------------------------------------------------

# Permission boundary policy (lives in zeroroot-ai-prod) — referenced by every
# operator role assumed via cross-account.
resource "aws_iam_policy" "operator_permission_boundary" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name        = "PB-OperatorMaxPermissions"
  description = "Permission boundary capping the ZeroDayAIProdAdmin role. Denies KMS schedule deletion, CloudTrail disable, state-bucket delete, org leave, GuardDuty/Config disable. R0.5, R12.4."
  policy      = file("${path.module}/policies/permission-boundary-operator.json")

  tags = local.common_tags
}

# ----------------------------------------------------------------------------
# Trust policy for the cross-account roles.
# Principal: zeroroot-ai-mgmt account root (AWS resolves this to all principals
#            in the mgmt account). Conditioned on:
#   - aws:PrincipalOrgID matches our org (defence-in-depth on principal)
#   - aws:PrincipalArn matches an Identity Center permission-set role
#     (these have ARN shape arn:aws:iam::<mgmt>:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_<perm-set>_<hash>)
#
# The condition strings use StringLike with wildcards because the Identity
# Center role hash is generated and not predictable from Terraform.
# ----------------------------------------------------------------------------

data "aws_caller_identity" "mgmt" {}

data "aws_iam_policy_document" "cross_account_admin_trust" {
  count = length(var.prod_account_id) > 0 ? 1 : 0

  statement {
    sid     = "AllowIdentityCenterAdminAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.mgmt.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [aws_organizations_organization.this.id]
    }

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalArn"
      values = [
        "arn:aws:iam::${data.aws_caller_identity.mgmt.account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_ZeroDayAIProdAdmin_*",
      ]
    }
  }
}

data "aws_iam_policy_document" "cross_account_readonly_trust" {
  count = length(var.prod_account_id) > 0 ? 1 : 0

  statement {
    sid     = "AllowIdentityCenterReadOnlyAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.mgmt.account_id}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [aws_organizations_organization.this.id]
    }

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalArn"
      values = [
        "arn:aws:iam::${data.aws_caller_identity.mgmt.account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_ZeroDayAIProdReadOnly_*",
      ]
    }
  }
}

# ----------------------------------------------------------------------------
# ZeroDayAIProdAdmin role in zeroroot-ai-prod.
# ----------------------------------------------------------------------------

resource "aws_iam_role" "gibson_prod_admin" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "ZeroDayAIProdAdmin"
  description          = "Cross-account admin role in zeroroot-ai-prod. Assumed by Identity Center ZeroDayAIProdAdmin permission set in zeroroot-ai-mgmt. Capped by PB-OperatorMaxPermissions."
  assume_role_policy   = data.aws_iam_policy_document.cross_account_admin_trust[0].json
  permissions_boundary = aws_iam_policy.operator_permission_boundary[0].arn
  max_session_duration = 14400 # 4 hours

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "gibson_prod_admin_admin" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  role       = aws_iam_role.gibson_prod_admin[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ----------------------------------------------------------------------------
# ZeroDayAIProdReadOnly role in zeroroot-ai-prod.
# ----------------------------------------------------------------------------

resource "aws_iam_role" "gibson_prod_readonly" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "ZeroDayAIProdReadOnly"
  description          = "Cross-account read-only role in zeroroot-ai-prod. Assumed by Identity Center ZeroDayAIProdReadOnly permission set in zeroroot-ai-mgmt."
  assume_role_policy   = data.aws_iam_policy_document.cross_account_readonly_trust[0].json
  max_session_duration = 14400

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "gibson_prod_readonly_ro" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  role       = aws_iam_role.gibson_prod_readonly[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
