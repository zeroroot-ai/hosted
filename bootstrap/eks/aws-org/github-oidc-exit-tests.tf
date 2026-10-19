# ----------------------------------------------------------------------------
# exit-test-node-access: the role of the exit tests that reach the nodes of an
# EC2 env over SSM (hosted#656).
#
# exit-test-monitoring.yml and exit-test-setec-cpu-template.yml run
# `make with-cluster ENV=<env>` (scripts/with-cluster.sh). That finds the
# instance tagged Name=zeroroot-ai-<env>, reads the k3s kubeconfig with one
# AWS-RunShellScript command, and forwards the API with
# AWS-StartPortForwardingSession. The role allows exactly those calls, on
# those instances, and nothing else. It is not eks-bringup: that role is
# AdministratorAccess, and a test job also builds and runs code.
#
# The trust is for the staging and drill environments only. A prod run of
# exit-test-monitoring cannot assume this role.
#
# scripts/check-role-callers.py fails when a workflow assumes
# EXIT_TEST_NODE_ROLE_ARN and gh_exit_test_node_job_workflow_refs does not
# name it, or the reverse.
# ----------------------------------------------------------------------------
locals {
  exit_test_node_environments = ["staging", "drill"]

  gh_exit_test_node_env_subs = [
    for e in local.exit_test_node_environments :
    "repo:${var.github_org}@*/${var.github_deploy_repo}@*:environment:${e}"
  ]

  gh_exit_test_node_job_workflow_refs = [
    for w in [
      "exit-test-monitoring.yml",
      "exit-test-setec-cpu-template.yml",
    ] :
    "${var.github_org}/${var.github_deploy_repo}/.github/workflows/${w}@refs/heads/main"
  ]

  # The Name tag of the one instance of each env (scripts/with-cluster.sh).
  exit_test_node_instance_names = [for e in local.exit_test_node_environments : "zeroroot-ai-${e}"]
}

data "aws_iam_policy_document" "exit_test_node_trust" {
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
      values   = local.gh_exit_test_node_env_subs
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:environment"
      values   = local.exit_test_node_environments
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/main"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = local.gh_exit_test_node_job_workflow_refs
    }
  }
}

data "aws_iam_policy_document" "exit_test_node_access" {
  count = length(var.prod_account_id) > 0 ? 1 : 0

  # Find the instance by tag. DescribeInstances has no resource-level scope.
  statement {
    sid       = "FindTheInstance"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # Run a command or open a session on the env instances only.
  statement {
    sid       = "TheEnvInstances"
    effect    = "Allow"
    actions   = ["ssm:SendCommand", "ssm:StartSession"]
    resources = ["arn:aws:ec2:${var.aws_region}:${var.prod_account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = local.exit_test_node_instance_names
    }
  }

  # With the two documents with-cluster.sh uses, and no other.
  statement {
    sid     = "TheTwoDocuments"
    effect  = "Allow"
    actions = ["ssm:SendCommand", "ssm:StartSession"]
    resources = [
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
      "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession",
    ]
  }

  # Read the result of its own command. GetCommandInvocation has no
  # resource-level scope.
  statement {
    sid       = "ReadTheCommandResult"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  # End its own sessions only.
  statement {
    sid       = "EndItsOwnSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:*:${var.prod_account_id}:session/$${aws:userid}-*"]
  }
}

resource "aws_iam_role" "exit_test_node_access" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "exit-test-node-access"
  description          = "Assumed by zeroroot-ai/hosted exit-test-monitoring.yml and exit-test-setec-cpu-template.yml from main, in the staging and drill environments only. SSM to the env instance, nothing else (hosted#656)."
  assume_role_policy   = data.aws_iam_policy_document.exit_test_node_trust[0].json
  permissions_boundary = aws_iam_policy.operator_permission_boundary[0].arn
  max_session_duration = 3600

  tags = local.common_tags
}

resource "aws_iam_role_policy" "exit_test_node_access" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name   = "exit-test-node-access"
  role   = aws_iam_role.exit_test_node_access[0].id
  policy = data.aws_iam_policy_document.exit_test_node_access[0].json
}
