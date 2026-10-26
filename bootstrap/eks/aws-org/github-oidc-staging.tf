# ----------------------------------------------------------------------------
# staging-bringup: the role of the staging promotion, and of staging only.
#
# Staging, prod and drill share one AWS account. Before this role,
# promote-staging.yml ran as eks-bringup, the role of the prod verbs, in the
# staging GitHub environment. Staging has no required reviewer. Now
# eks-bringup trusts only prod (github-oidc.tf), and promote-staging.yml
# assumes this role.
#
# The trust: GitHub OIDC, the staging environment only, off main, from
# promote-staging.yml only.
#
# The access: staging is permanent (ADR-0095). Nothing applies to it from
# GitHub, so the promotion only reads. The role policy grants the calls that
# the promotion makes, and no other:
#
#   - ec2:DescribeInstances, to find the instance by its Name tag
#     (scripts/with-cluster.sh);
#   - SSM commands and the port forward on the staging instance
#     (scripts/lib/ec2-cluster-access.sh, scripts/lib/ssm-forward.sh);
#   - the SES rule of the test inbox, and the mail in the inbox bucket of
#     staging (scripts/prove-bringup.sh, test/lib/mailsource.mjs).
#
# The permission boundary PB-StagingBringup holds the same fence a second
# time, so a later grant on the role cannot reach another environment. It
# allows only EC2 reads, SSM, SES reads, S3 and STS, and in those services it
# takes away:
#
#   - an assume of any role;
#   - each S3 bucket but the staging buckets;
#   - the SSM parameters of prod and drill, by name;
#   - each resource tagged with another Environment;
#   - SSM commands and sessions on an instance without the staging tag.
#
# scripts/check-role-callers.py fails when a workflow assumes
# STAGING_BRINGUP_ROLE_ARN and gh_staging_bringup_job_workflow_refs does not
# name it, or the reverse, and when eks-bringup trusts the staging
# environment or promote-staging.yml.
# ----------------------------------------------------------------------------

locals {
  staging_environment = "staging"
  staging_bringup_env_sub = (
    "repo:${var.github_org}@*/${var.github_deploy_repo}@*:environment:${local.staging_environment}"
  )
  gh_staging_bringup_job_workflow_refs = [
    for w in ["promote-staging.yml"] :
    "${var.github_org}/${var.github_deploy_repo}/.github/workflows/${w}@refs/heads/main"
  ]

  staging_boundary_name = "PB-StagingBringup"
  staging_inbox_bucket  = "zeroroot-ai-staging-inbox-${var.prod_account_id}"
}

data "aws_iam_policy_document" "staging_bringup_trust" {
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
      values   = [local.staging_bringup_env_sub]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:environment"
      values   = [local.staging_environment]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/main"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = local.gh_staging_bringup_job_workflow_refs
    }
  }
}

# The boundary is one JSON template, policies/permission-boundary-staging.json.tftpl,
# so scripts/check-iam-arn-service.py renders it with no AWS credentials and
# fails when its compact size reaches the IAM limit. Its statements, by Sid:
#
#   AllowTheServicesOfStaging          EC2 reads, SSM, SES reads, S3, STS
#   DenyAssumingAnotherRole            no assume of any role
#   DenyBucketsOutsideStaging          the staging buckets only
#   DenyResourcesNamedForAnotherEnvironment  the SSM parameters of prod and drill
#   DenyResourcesTaggedWithAnotherEnvironment  every resource with another tag
#   DenyCommandsOnInstancesOutsideStaging  SSM on staging instances only
resource "aws_iam_policy" "staging_boundary" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name        = local.staging_boundary_name
  description = "Permission boundary of staging-bringup: EC2 reads, SSM, SES reads, S3 and STS, and no resource of prod or drill."
  policy = templatefile("${path.module}/policies/permission-boundary-staging.json.tftpl", {
    account_id = var.prod_account_id
  })

  tags = merge(local.common_tags, { Environment = local.staging_environment })
}

# What the promotion calls, and nothing else.
data "aws_iam_policy_document" "staging_bringup_access" {
  count = length(var.prod_account_id) > 0 ? 1 : 0

  statement {
    sid       = "FindTheInstance"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid     = "CommandsAndSessionsOnTheStagingInstance"
    effect  = "Allow"
    actions = ["ssm:SendCommand", "ssm:StartSession"]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${var.prod_account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Environment"
      values   = [local.staging_environment]
    }
  }

  statement {
    sid     = "TheDocumentsOfTheCommandAndTheForward"
    effect  = "Allow"
    actions = ["ssm:SendCommand", "ssm:StartSession"]
    resources = [
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
      "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession",
    ]
  }

  statement {
    sid       = "ReadTheCommandResult"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  statement {
    sid       = "EndItsOwnSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:*:${var.prod_account_id}:session/$${aws:userid}-*"]
  }

  statement {
    sid       = "ReadTheInboxRule"
    effect    = "Allow"
    actions   = ["ses:DescribeActiveReceiptRuleSet", "ses:DescribeReceiptRule"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadAndClearTheStagingInbox"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.staging_inbox_bucket}", "arn:aws:s3:::${local.staging_inbox_bucket}/*"]
  }
}

resource "aws_iam_role" "staging_bringup" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "staging-bringup"
  description          = "The role of zeroroot-ai/hosted promote-staging.yml, workflow_dispatch off main, in the staging GitHub environment only. Bounded by PB-StagingBringup: no resource of prod or drill."
  assume_role_policy   = data.aws_iam_policy_document.staging_bringup_trust[0].json
  permissions_boundary = aws_iam_policy.staging_boundary[0].arn
  # 4 hours, the role-duration-seconds of promote-staging.yml.
  max_session_duration = 14400

  tags = merge(local.common_tags, { Environment = local.staging_environment })
}

resource "aws_iam_role_policy" "staging_bringup_access" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name   = "staging-promotion"
  role   = aws_iam_role.staging_bringup[0].id
  policy = data.aws_iam_policy_document.staging_bringup_access[0].json
}
