# ----------------------------------------------------------------------------
# The keyring reader role (ADR-0083, amendment of 2026-10-22).
#
# One read-only role for each environment. The workflows preflight.yml,
# recreate.yml and teardown.yml read the keyring of an environment from Secrets
# Manager (keyring-secret.tf) with it, and with nothing else. GitHub OIDC assumes
# it only from the GitHub environment of the env (the sub claim names that one
# environment), only off main, and only from those three workflow files. So a
# run in another environment cannot assume it.
#
# Staging, prod and drill share one AWS account, and the bringup role trusts all
# three GitHub environments. So the bringup role is NOT a principal of the
# keyring secret of staging or prod: this role is how recreate and teardown read
# it. The role can read one secret: the keyring of this environment. It cannot
# read the state under tfstate/stage0/, which the bucket policy keeps for the
# rotation role and the operator roles.
#
# It exists only where var.keyring_reader_role_enabled is true. The variable
# KEYRING_READER_ROLE_ARN of the GitHub environment names it.
# ----------------------------------------------------------------------------

locals {
  keyring_reader_role_name = "zeroroot-ai-${var.environment}-keyring-reader"
  keyring_reader_job_workflow_refs = [
    "${var.github_repository}/.github/workflows/preflight.yml@refs/heads/main",
    "${var.github_repository}/.github/workflows/recreate.yml@refs/heads/main",
    "${var.github_repository}/.github/workflows/teardown.yml@refs/heads/main",
  ]
}

data "aws_iam_policy_document" "keyring_reader_trust" {
  count = var.keyring_reader_role_enabled ? 1 : 0

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
      values   = local.keyring_reader_job_workflow_refs
    }
  }
}

data "aws_iam_policy_document" "keyring_reader" {
  count = var.keyring_reader_role_enabled ? 1 : 0

  statement {
    sid       = "ReadTheKeyring"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.keyring.arn]
  }
}

resource "aws_iam_role" "keyring_reader" {
  count = var.keyring_reader_role_enabled ? 1 : 0

  name                 = local.keyring_reader_role_name
  description          = "Reads the keyring of ${var.environment} (ADR-0083). Assumed by ${var.github_repository} preflight.yml, recreate.yml and teardown.yml, off main, in the ${var.environment} GitHub environment only."
  assume_role_policy   = data.aws_iam_policy_document.keyring_reader_trust[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "keyring_reader" {
  count = var.keyring_reader_role_enabled ? 1 : 0

  name   = "read-the-keyring"
  role   = aws_iam_role.keyring_reader[0].id
  policy = data.aws_iam_policy_document.keyring_reader[0].json
}
