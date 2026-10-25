# ----------------------------------------------------------------------------
# drill-bringup: the role of the drill (ADR-0095), and of the drill only.
#
# Staging, prod and drill share one AWS account. Before this role, the drill ran
# as eks-bringup, the role of the prod verbs. The drill GitHub environment has
# no required reviewer, so a drill run had the access of the prod verbs without
# the prod approval. Now eks-bringup trusts only staging and prod
# (github-oidc.tf), and drill.yml assumes this role.
#
# The trust: GitHub OIDC, the drill environment only, off main, from drill.yml
# only.
#
# The access: AdministratorAccess inside the permission boundary
# PB-DrillBringup. The drill applies stage 1 (a VPC, an instance, its node role)
# and rotates the access keys of the drill IAM users through stage 0, so it
# needs wide access to the resources of drill. The boundary takes away each
# resource of another environment and each path out of the boundary:
#
#   - every statement of PB-OperatorMaxPermissions;
#   - an IAM write on anything but the drill names (zeroroot-ai-drill-*, the
#     drill users under /substrate/, and the service-linked roles). So the role
#     cannot change itself, its boundary, eks-bringup or any role of staging
#     or prod, and it cannot pass another role to a service;
#   - a role or user that the role creates, or a policy that it puts on one,
#     must carry this boundary. The boundary cannot be removed;
#   - an assume of any role but the drill roles;
#   - each S3 bucket but the drill buckets;
#   - the secrets, registries and clusters of staging and prod, by name;
#   - each resource tagged with another Environment, in the services that
#     authorize by tag (EC2, SSM and the rest);
#   - a DNS record outside the drill zone, and a delete of a hosted zone;
#   - a write of the SES identities and of the receipt rules, which every
#     environment shares.
#
# scripts/check-role-callers.py fails when a workflow assumes
# DRILL_BRINGUP_ROLE_ARN and gh_drill_bringup_job_workflow_refs does not name
# it, or the reverse, and when eks-bringup trusts the drill environment.
# ----------------------------------------------------------------------------

locals {
  drill_environment = "drill"
  drill_bringup_env_sub = (
    "repo:${var.github_org}@*/${var.github_deploy_repo}@*:environment:${local.drill_environment}"
  )
  gh_drill_bringup_job_workflow_refs = [
    for w in ["drill.yml"] :
    "${var.github_org}/${var.github_deploy_repo}/.github/workflows/${w}@refs/heads/main"
  ]

  drill_boundary_name = "PB-DrillBringup"
  drill_boundary_arn  = "arn:aws:iam::${var.prod_account_id}:policy/${local.drill_boundary_name}"
  # The ARN patterns of every resource of staging, prod and the organization
  # that carries its name. "*" also matches the empty region and account of an
  # S3 ARN.
  drill_denied_name_patterns = [
    "arn:aws:*:*:*:*zeroroot-ai-staging*",
    "arn:aws:*:*:*:*zeroroot-ai-prod*",
    "arn:aws:*:*:*:*zeroroot-ai/staging/*",
    "arn:aws:*:*:*:*zeroroot-ai/prod/*",
    "arn:aws:*:*:*:*zero-day-ai-*",
    "arn:aws:*:*:*:*gibson-org*",
  ]
  # The AWS buckets that the SSM agent reads (the policy
  # AmazonSSMManagedInstanceCore, the documentation of the SSM agent).
  drill_node_aws_buckets = [
    "aws-ssm-${var.aws_region}", "aws-windows-downloads-${var.aws_region}",
    "amazon-ssm-${var.aws_region}", "amazon-ssm-packages-${var.aws_region}",
    "${var.aws_region}-birdwatcher-prod", "aws-ssm-distributor-file-${var.aws_region}",
    "aws-ssm-document-attachments-${var.aws_region}", "patch-baseline-snapshot-${var.aws_region}",
  ]
}

data "aws_iam_policy_document" "drill_bringup_trust" {
  count = length(var.prod_account_id) > 0 ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.drill_bringup_env_sub]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:environment"
      values   = [local.drill_environment]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/main"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = local.gh_drill_bringup_job_workflow_refs
    }
  }
}

data "aws_iam_policy_document" "drill_boundary" {
  count = length(var.prod_account_id) > 0 ? 1 : 0

  # A boundary allows nothing by itself. The statements below take away.
  statement {
    sid       = "AllowEverythingByDefault"
    actions   = ["*"]
    resources = ["*"]
  }

  # The denies of PB-OperatorMaxPermissions that are not covered below. Its
  # bucket and IAM user statements are: the drill touches only drill buckets
  # and drill users.
  statement {
    sid    = "DenyTheOperatorBoundaryActions"
    effect = "Deny"
    actions = [
      "kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:DisableKeyRotation",
      "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors", "cloudtrail:PutInsightSelectors",
      "organizations:*", "account:*",
      "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount",
      "guardduty:DisassociateMembers", "guardduty:UpdateDetector",
      "config:DeleteConfigurationRecorder", "config:DeleteDeliveryChannel",
      "config:StopConfigurationRecorder", "config:DeleteConfigRule",
      "iam:CreateLoginProfile", "iam:UpdateLoginProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyIamWritesOutsideDrill"
    effect = "Deny"
    actions = [
      "iam:Add*", "iam:Attach*", "iam:Change*", "iam:Create*", "iam:Deactivate*",
      "iam:Delete*", "iam:Detach*", "iam:Enable*", "iam:PassRole", "iam:Put*",
      "iam:Remove*", "iam:Reset*", "iam:Resync*", "iam:Set*", "iam:Tag*",
      "iam:Untag*", "iam:Update*", "iam:Upload*",
    ]
    not_resources = [
      "arn:aws:iam::${var.prod_account_id}:role/zeroroot-ai-drill-*",
      "arn:aws:iam::${var.prod_account_id}:instance-profile/zeroroot-ai-drill-*",
      "arn:aws:iam::${var.prod_account_id}:policy/zeroroot-ai-drill-*",
      "arn:aws:iam::${var.prod_account_id}:user/substrate/zeroroot-ai-drill-*",
      "arn:aws:iam::${var.prod_account_id}:role/aws-service-role/*",
    ]
  }

  # Each IAM user and role of drill carries this boundary (stage 0 and stage 1
  # set it), so a policy on one of them cannot reach past it.
  statement {
    sid    = "DenyAnIdentityWithoutThisBoundary"
    effect = "Deny"
    actions = [
      "iam:CreateRole", "iam:CreateUser", "iam:PutRolePermissionsBoundary",
      "iam:PutUserPermissionsBoundary", "iam:PutRolePolicy", "iam:AttachRolePolicy",
      "iam:PutUserPolicy", "iam:AttachUserPolicy",
    ]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.drill_boundary_arn]
    }
  }

  statement {
    sid       = "DenyRemovingTheBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:DeleteUserPermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    sid           = "DenyAssumingAnotherRole"
    effect        = "Deny"
    actions       = ["sts:AssumeRole"]
    not_resources = ["arn:aws:iam::${var.prod_account_id}:role/zeroroot-ai-drill-*"]
  }

  # The drill buckets, and the AWS buckets that the SSM agent of the drill node
  # reads (AmazonSSMManagedInstanceCore).
  statement {
    sid     = "DenyBucketsOutsideDrill"
    effect  = "Deny"
    actions = ["s3:*"]
    not_resources = concat(
      # The bucket pattern also matches each object of a drill bucket.
      ["arn:aws:s3:::zeroroot-ai-drill-*"],
      [for b in local.drill_node_aws_buckets : "arn:aws:s3:::${b}/*"],
    )
  }

  # Every resource of another environment or of the organization whose ARN
  # carries its name, in every service: a bucket, a table, a key alias, a
  # secret, a registry, a cluster, a function.
  statement {
    sid       = "DenyResourcesNamedForAnotherEnvironment"
    effect    = "Deny"
    actions   = ["*"]
    resources = local.drill_denied_name_patterns
  }

  # Every resource tagged with another Environment, in every service that
  # authorizes by tag. Route 53 reads the apex zone (Environment=prod) for the
  # drill delegation, so it is fenced by record name below instead.
  statement {
    sid         = "DenyResourcesTaggedWithAnotherEnvironment"
    effect      = "Deny"
    not_actions = ["route53:*"]
    resources   = ["*"]
    condition {
      test     = "Null"
      variable = "aws:ResourceTag/Environment"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [local.drill_environment]
    }
  }

  # A volume or snapshot with no Environment tag is not the drill's. The drill
  # makes its volumes with RunInstances and never acts on one by itself.
  statement {
    sid    = "DenyVolumesAndSnapshotsOutsideDrill"
    effect = "Deny"
    actions = [
      "ec2:AttachVolume", "ec2:DetachVolume", "ec2:DeleteVolume", "ec2:ModifyVolume*",
      "ec2:CreateVolume", "ec2:CreateSnapshot*", "ec2:CopySnapshot", "ec2:DeleteSnapshot",
      "ec2:ModifySnapshot*", "ec2:ResetSnapshotAttribute", "ec2:EnableFastSnapshotRestores",
      "ebs:*",
    ]
    resources = ["arn:aws:ec2:*:*:volume/*", "arn:aws:ec2:*::snapshot/*", "arn:aws:ebs:*:*:snapshot/*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [local.drill_environment]
    }
  }

  # SSM names the tags of a target instance with its own key.
  statement {
    sid       = "DenyCommandsOnInstancesOutsideDrill"
    effect    = "Deny"
    actions   = ["ssm:SendCommand", "ssm:StartSession"]
    resources = ["arn:aws:ec2:*:${var.prod_account_id}:instance/*"]
    condition {
      test     = "StringNotEquals"
      variable = "ssm:resourceTag/Environment"
      values   = [local.drill_environment]
    }
  }

  statement {
    sid       = "DenyRecordsOutsideTheDrillZone"
    effect    = "Deny"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringNotLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = [var.drill_zone_name, "*.${var.drill_zone_name}"]
    }
  }

  statement {
    sid    = "DenyZoneDeletes"
    effect = "Deny"
    actions = [
      "route53:DeleteHostedZone", "route53:DisableHostedZoneDNSSEC",
      "route53:DeactivateKeySigningKey", "route53:DeleteKeySigningKey", "route53domains:*",
    ]
    resources = ["*"]
  }

  # The SES identities and the one active receipt rule set are shared by every
  # environment, and substrate/apex-zone owns the rule set.
  statement {
    sid    = "DenySharedMailWrites"
    effect = "Deny"
    actions = [
      "ses:Clone*", "ses:Create*", "ses:Delete*", "ses:Put*", "ses:Reorder*",
      "ses:Set*", "ses:Update*", "ses:Verify*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "drill_boundary" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name        = local.drill_boundary_name
  description = "Permission boundary of drill-bringup and of each identity it makes: the operator boundary, and no resource of staging or prod (ADR-0095)."
  policy      = data.aws_iam_policy_document.drill_boundary[0].json

  # Environment=drill: the tag fence of the boundary lets the drill read its
  # own role and boundary. The IAM fence still keeps it from changing them.
  tags = merge(local.common_tags, { Environment = local.drill_environment })
}

resource "aws_iam_role" "drill_bringup" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "drill-bringup"
  description          = "The role of zeroroot-ai/hosted drill.yml, workflow_dispatch off main, in the drill GitHub environment only. Bounded by PB-DrillBringup: no resource of staging or prod."
  assume_role_policy   = data.aws_iam_policy_document.drill_bringup_trust[0].json
  permissions_boundary = aws_iam_policy.drill_boundary[0].arn
  # 6 hours, the GitHub limit of one job, as eks-bringup (github-oidc.tf).
  max_session_duration = 21600

  tags = merge(local.common_tags, { Environment = local.drill_environment })
}

resource "aws_iam_role_policy_attachment" "drill_bringup_admin" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  role       = aws_iam_role.drill_bringup[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
