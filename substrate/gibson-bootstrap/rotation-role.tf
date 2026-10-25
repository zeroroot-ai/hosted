# ----------------------------------------------------------------------------
# The key rotation role (ADR-0083, amendment of 2026-10-21).
#
# The access keys of the stage 0 IAM users rotate in one workflow:
# .github/workflows/rotate-credentials.yml, workflow_dispatch only, off main,
# in the GitHub environment of the env. The environment needs an approval for
# each run. The job assumes this role through GitHub OIDC. No long-lived AWS
# credential exists for it.
#
# The role can do three things, and nothing else:
#
#   1. Write the access keys of the users platform, smtp, dns and
#      setec-disk-builder: create, delete and disable. It cannot change a
#      policy, a user, a role or any other resource.
#   2. Read each stage 0 resource, so `terraform plan` can refresh the state.
#      It reads the configuration of the buckets and never an object, except
#      under tfstate/stage0/.
#   3. Reach the cluster the way the other workflows do (scripts/with-cluster.sh):
#      find the instance by its Name tag, run a shell command on it to read the
#      kubeconfig, and open a port forward to the API. This is more than a key
#      write: a command on the node. It is limited to the one instance tagged
#      Name=zeroroot-ai-<env>, and the rotation needs the cluster to restart
#      the readers of each credential. Prod is EKS: the role reads the cluster
#      description for `aws eks update-kubeconfig`.
#   4. Read and write the Terraform state, the key slots and the rotation
#      record under tfstate/stage0/ of the durable bucket (scripts/
#      stage0-store.sh). The bucket policy denies every other principal that
#      prefix (bucket.tf).
#
# One role for each environment. It exists only where var.rotation_role_enabled
# is true. The repository variable of the environment that names it is
# KEY_ROTATION_ROLE_ARN (the output rotation_role_arn).
# ----------------------------------------------------------------------------

locals {
  rotation_role_name = "zeroroot-ai-${var.environment}-key-rotation"
  # The only workflow that may assume the role, and the only ref.
  rotation_job_workflow_refs = [
    "${var.github_repository}/.github/workflows/rotate-credentials.yml@refs/heads/main",
  ]
  rotation_user_names = [
    "zeroroot-ai-${var.environment}-platform",
    "zeroroot-ai-${var.environment}-smtp",
    "zeroroot-ai-${var.environment}-dns",
    "zeroroot-ai-${var.environment}-setec-disk-builder",
  ]
  state_prefix = "tfstate/stage0"
  # Every role that stage 0 looks up by name, and the rotation role.
  stage0_role_names = distinct(concat(
    var.keyring_principal_role_names,
    var.edge_cert_principal_role_names,
    [var.inbox_reader_role_name, local.rotation_role_name, local.keyring_reader_role_name],
  ))
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.rotation_role_enabled || var.keyring_reader_role_enabled ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "rotation_trust" {
  count = var.rotation_role_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # A job that declares `environment: <env>` gets the environment-shaped sub.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/main"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = local.rotation_job_workflow_refs
    }
  }
}

data "aws_iam_policy_document" "rotation" {
  count = var.rotation_role_enabled ? 1 : 0

  # 1. The write: the access keys of the four stage 0 users.
  statement {
    sid     = "WriteTheAccessKeys"
    effect  = "Allow"
    actions = ["iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:UpdateAccessKey"]
    resources = [for n in local.rotation_user_names :
    "arn:aws:iam::${var.aws_account_id}:user/substrate/${n}"]
  }

  # GetAccessKeyLastUsed has no resource type in IAM.
  statement {
    sid       = "ReadWhenAKeyWasUsed"
    effect    = "Allow"
    actions   = ["iam:GetAccessKeyLastUsed"]
    resources = ["*"]
  }

  # The keyring of this environment (keyring-secret.tf): read and write, and no
  # other secret.
  statement {
    sid       = "ReadAndWriteTheKeyring"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.keyring.arn]
  }

  # 3. The state, the key slots and the rotation record.
  statement {
    sid       = "StateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.durable.arn}/${local.state_prefix}/*"]
  }

  # 3. The cluster. EC2 describe calls have no resource scope.
  statement {
    sid       = "FindTheInstance"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances", "ssm:DescribeInstanceInformation", "ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  statement {
    sid       = "RunACommandOnTheNodeDocuments"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "RunACommandOnTheNode"
    effect    = "Allow"
    actions   = ["ssm:SendCommand", "ssm:StartSession"]
    resources = ["arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["zeroroot-ai-${var.environment}"]
    }
  }

  statement {
    sid       = "ForwardTheApiPort"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession"]
  }

  statement {
    sid       = "EndItsOwnSession"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:session/$${aws:userid}-*"]
  }

  statement {
    sid       = "DescribeTheEksCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/zeroroot-ai-${var.environment}"]
  }

  # 2. The read of each stage 0 resource, for the refresh of `terraform plan`.
  statement {
    sid     = "ReadTheBucketConfiguration"
    effect  = "Allow"
    actions = ["s3:GetBucket*", "s3:GetLifecycleConfiguration", "s3:GetEncryptionConfiguration", "s3:GetAccelerateConfiguration", "s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.durable.arn,
      aws_s3_bucket.inbox.arn,
    ]
  }

  statement {
    sid     = "ReadTheUsers"
    effect  = "Allow"
    actions = ["iam:GetUser", "iam:GetUserPolicy", "iam:ListUserPolicies", "iam:ListAttachedUserPolicies", "iam:ListAccessKeys", "iam:ListGroupsForUser", "iam:ListUserTags"]
    resources = [for n in local.rotation_user_names :
    "arn:aws:iam::${var.aws_account_id}:user/substrate/${n}"]
  }

  # The roles that stage 0 reads by name (data.aws_iam_role in keyring-secret.tf,
  # inbox.tf and edge-cert.tf) and this role itself. No other role.
  statement {
    sid     = "ReadTheStage0Roles"
    effect  = "Allow"
    actions = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags"]
    resources = [for n in local.stage0_role_names :
    "arn:aws:iam::${var.aws_account_id}:role/${n}"]
  }

  # The data source finds the provider by its URL: a list, then a get.
  statement {
    sid       = "ListTheOidcProviders"
    effect    = "Allow"
    actions   = ["iam:ListOpenIDConnectProviders"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadTheOidcProvider"
    effect    = "Allow"
    actions   = ["iam:GetOpenIDConnectProvider"]
    resources = [data.aws_iam_openid_connect_provider.github[0].arn]
  }

  statement {
    sid       = "ReadTheZones"
    effect    = "Allow"
    actions   = ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ListTagsForResource", "route53:GetChange", "route53:ListHostedZones", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadTheRegistries"
    effect    = "Allow"
    actions   = ["ecr:DescribeRepositories", "ecr:ListTagsForResource", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy"]
    resources = ["arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/zeroroot-ai-${var.environment}-*"]
  }

  statement {
    sid    = "ReadTheMailRules"
    effect = "Allow"
    # The SES v2 API uses the ses: prefix in IAM.
    actions   = ["ses:DescribeActiveReceiptRuleSet", "ses:DescribeReceiptRuleSet", "ses:DescribeReceiptRule", "ses:GetEmailIdentity"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadTheSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy"]
    resources = ["arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:zeroroot-ai/${var.environment}/*"]
  }
}

resource "aws_iam_role" "rotation" {
  count = var.rotation_role_enabled ? 1 : 0

  name                 = local.rotation_role_name
  description          = "Rotates the access keys of the stage 0 IAM users of ${var.environment} (ADR-0083). Assumed by ${var.github_repository} rotate-credentials.yml, workflow_dispatch only, off main, in the ${var.environment} GitHub environment."
  assume_role_policy   = data.aws_iam_policy_document.rotation_trust[0].json
  permissions_boundary = local.identity_permissions_boundary_arn
  max_session_duration = 21600
}

resource "aws_iam_role_policy" "rotation" {
  count = var.rotation_role_enabled ? 1 : 0

  name   = "key-rotation"
  role   = aws_iam_role.rotation[0].id
  policy = data.aws_iam_policy_document.rotation[0].json
}
