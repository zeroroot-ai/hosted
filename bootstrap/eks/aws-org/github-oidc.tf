# ----------------------------------------------------------------------------
# GitHub Actions OIDC trust + tf-plan/tf-apply roles in zeroroot-ai-prod.
#
# This wires zeroroot-ai/hosted, which carries the Argo tree and the verb
# workflows, to assume short-lived AWS sessions via OIDC, eliminating
# long-lived AWS access keys in GitHub Actions secrets. R-NFR-O2.
#
# Two roles in zeroroot-ai-prod:
#   - tf-plan-readonly: trusted on `pull_request` events from
#                       repo:<org>/<repo>:pull_request — used by the
#                       Terraform plan-on-PR workflow.
#   - tf-apply-privileged: trusted ONLY from a job running in the
#                          `aws-prod-apply` GitHub Environment, off
#                          refs/heads/main.
#
# Both roles carry PB-OperatorMaxPermissions to bound their blast radius.
#
# deploy#1198: the two AdministratorAccess roles (tf-apply-privileged,
# eks-bringup) used to trust a bare ref-shaped sub claim, so *any* merged
# change to main could reach admin in zeroroot-ai-prod with no second pair of
# eyes. They now require a GitHub Environment, which is where the human gate
# lives.
#
#   OPERATOR PREREQUISITE — NOT EXPRESSIBLE IN TERRAFORM.
#   The Environment gate is only a gate once the Environment carries required
#   reviewers. That is a per-repo GitHub setting; the AWS provider cannot set
#   it. Until an operator configures them, these conditions narrow *which*
#   workflow may assume the role but do not add an approval step:
#     - zeroroot-ai/hosted → Environment `aws-prod-apply`:
#         required reviewers = platform owners; deployment branch rule = main
#     - zeroroot-ai/hosted → Environments `staging` and `prod`:
#         prod: required reviewers = platform owners; deployment branch rule
#         = main. staging carries neither, on purpose
#         (docs/bringup.md § Who may run what).
#
# This file lives in the aws-org workspace (rather than zeroroot-ai-prod) because:
#   1. The OIDC IdP itself is account-scoped and there's value in owning it
#      in the org-cross-cutting workspace.
#   2. The roles need PB-OperatorMaxPermissions which is created here.
# ----------------------------------------------------------------------------

# OIDC IdP for GitHub Actions, in zeroroot-ai-prod.
resource "aws_iam_openid_connect_provider" "github" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # GitHub-published thumbprint, see https://github.blog/changelog/2023-06-27-github-actions-update-on-oidc-integration-with-aws/
  tags            = local.common_tags
}

locals {
  # GitHub OIDC sub-claim shapes:
  #   - pull_request:                 repo:<org>/<repo>:pull_request
  #   - push/dispatch off a branch:   repo:<org>/<repo>:ref:refs/heads/<branch>
  #   - job targeting an Environment: repo:<org>/<repo>:environment:<name>
  #
  # The third shape is the one the two admin-equivalent roles use. A job that
  # declares `environment: <name>` gets the environment-shaped sub INSTEAD of
  # the ref-shaped one — the two are mutually exclusive, so a trust policy that
  # asks for both can never be satisfied. The branch pin therefore moves to the
  # separate `ref` claim, which GitHub emits on every token regardless of shape.
  # GitHub signs the subject in its immutable form since 2026:
  #   repo:<org>@<org id>/<repo>@<repo id>:<ref or environment>
  # (measured in CloudTrail on 2026-09-06 after every repo was recreated, the
  # ids changed and every StringEquals trust went dark). The ids are pinned
  # with "@*" and matched with StringLike. "*" cannot cross into another org
  # or repo: names never contain "@" or "/", so the pattern still matches
  # exactly one repository.
  gh_pr_sub = "repo:${var.github_org}@*/${var.github_gitops_repo}@*:pull_request"

  gh_apply_env_sub = "repo:${var.github_org}@*/${var.github_gitops_repo}@*:environment:${var.github_apply_environment}"
  # The bringup verbs run in the GitHub environment named by their `env`
  # input, so the role is trusted for BOTH environment-shaped subs.
  gh_bringup_env_subs = [
    for e in var.github_bringup_environments :
    "repo:${var.github_org}@*/${var.github_deploy_repo}@*:environment:${e}"
  ]

  # job_workflow_ref pins the exact workflow file AND the ref it was loaded
  # from. The bringup role names its four callers, which are the only
  # workflows that drive `make recreate` / `make teardown` — drill.yml is the
  # fourth (ADR-0095) and drives both in one run, against an environment that is
  # destroyed at the end of it; the gitops apply
  # workflow has no committed caller yet, so pinning a path there would be a
  # guess that locks out the first real one.
  #
  # scripts/check-role-callers.py fails when a workflow assumes
  # EKS_BRINGUP_ROLE_ARN and this list does not name it, or the reverse. An
  # exit test that only reaches the nodes uses exit-test-node-access
  # (github-oidc-exit-tests.tf), never this administrator role (hosted#656).
  gh_bringup_job_workflow_refs = [
    for w in ["recreate.yml", "teardown.yml", "promote-staging.yml", "drill.yml"] :
    "${var.github_org}/${var.github_deploy_repo}/.github/workflows/${w}@refs/heads/main"
  ]
}

# tf-plan-readonly: trust pull_request events.
data "aws_iam_policy_document" "tf_plan_trust" {
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
      values   = [local.gh_pr_sub]
    }
  }
}

resource "aws_iam_role" "tf_plan_readonly" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "tf-plan-readonly"
  description          = "Read-only role assumed by GitHub Actions Terraform plan-on-PR workflow in zeroroot-ai/hosted."
  assume_role_policy   = data.aws_iam_policy_document.tf_plan_trust[0].json
  permissions_boundary = aws_iam_policy.operator_permission_boundary[0].arn
  max_session_duration = 3600 # 1 hour — plan jobs are short

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "tf_plan_ro" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  role       = aws_iam_role.tf_plan_readonly[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# tf-apply-privileged: assumable only from a job running in the
# `${var.github_apply_environment}` GitHub Environment of the gitops repo, off
# refs/heads/main. The Environment is the approval gate: a merged PR alone no
# longer reaches AdministratorAccess (deploy#1198).
data "aws_iam_policy_document" "tf_apply_trust" {
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
      values   = [local.gh_apply_env_sub]
    }

    # Redundant with the environment-shaped sub above, and deliberately so:
    # if the org ever customises the sub claim template, the sub stops
    # carrying the environment and this condition is what still holds.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:environment"
      values   = [var.github_apply_environment]
    }

    # The environment-shaped sub drops the branch, so pin the branch here.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "tf_apply_privileged" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "tf-apply-privileged"
  description          = "Privileged role assumed by GitHub Actions Terraform apply-on-merge workflow in zeroroot-ai/hosted. Applies are gated by manual workflow_dispatch in the workflow YAML."
  assume_role_policy   = data.aws_iam_policy_document.tf_apply_trust[0].json
  permissions_boundary = aws_iam_policy.operator_permission_boundary[0].arn
  max_session_duration = 7200 # 2 hours — apply may run long

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "tf_apply_admin" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  role       = aws_iam_role.tf_apply_privileged[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# eks-bringup: the role the bringup verbs run as (deploy#1746).
#
# Its four callers are recreate.yml, teardown.yml, promote-staging.yml and
# drill.yml,
# each workflow_dispatch-only off refs/heads/main, each running in the GitHub
# environment its `env` input names. They drive `make recreate` and
# `make teardown` — a full Terraform apply and destroy of EKS and the VPC —
# so, like tf-apply-privileged, the role is admin-equivalent in the workload
# account, bounded by PB-OperatorMaxPermissions.
#
# It replaces `eks-acceptance` outright (ADR-0027). That role pinned
# job_workflow_ref to eks-acceptance.yml, which deploy#1745 deleted, so no
# caller could assume it any more — including promote-staging.yml, whose AWS
# step has been broken since. There is no alias and no second role.
data "aws_iam_policy_document" "eks_bringup_trust" {
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
      values   = local.gh_bringup_env_subs
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:environment"
      values   = var.github_bringup_environments
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/main"]
    }

    # Only the three verb callers may assume this role — not any other
    # workflow that happens to declare the same environment.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = local.gh_bringup_job_workflow_refs
    }
  }
}

resource "aws_iam_role" "eks_bringup" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "eks-bringup"
  description          = "Privileged role the bringup verbs run as (deploy#1746). Assumed by zeroroot-ai/hosted's recreate.yml, teardown.yml and promote-staging.yml, workflow_dispatch-only off main, in the staging, drill or prod GitHub environment. Runs make recreate / make teardown."
  assume_role_policy   = data.aws_iam_policy_document.eks_bringup_trust[0].json
  permissions_boundary = aws_iam_policy.operator_permission_boundary[0].arn
  # 6 hours, the GitHub limit of one job. One job of drill.yml holds the
  # recreate, the smoke and the restore half or the rotation test, and it
  # stops at 345 minutes, so its one session must outlive 4 hours. The
  # teardown is a job of its own with a session of its own (hosted#679,
  # second drill sweep, row 19). Nothing needs more than one job.
  max_session_duration = 21600

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_bringup_admin" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  role       = aws_iam_role.eks_bringup[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ----------------------------------------------------------------------------
# eks-plan-readonly: the role launch blocker 1's exit test runs as.
#
# `exit-test-terraform.yml` measures one thing — that `terraform plan` on
# eks/gibson exits 0 with no S3 bucket in the replace set (deploy#1588). A plan
# reads state and reads AWS; it writes nothing, and the workflow passes
# -lock=false so it does not even take the state lock. So this role gets
# ReadOnlyAccess, never AdministratorAccess.
#
# That read-only blast radius is why the trust here is ref-shaped off main
# rather than Environment-gated like eks-bringup and tf-apply-privileged.
# Those two are AdministratorAccess, where deploy#1198's "one merged PR reaches
# admin" finding applies. A role that can only read does not need an approval
# gate in front of it, and putting one there would mean the exit test cannot
# run unattended — which defeats the point of measuring it on a schedule.
#
# job_workflow_ref still pins the single caller, so no other workflow in the
# deploy repo can assume it.
# ----------------------------------------------------------------------------
locals {
  gh_eks_plan_sub              = "repo:${var.github_org}@*/${var.github_deploy_repo}@*:ref:refs/heads/main"
  gh_eks_plan_job_workflow_ref = "${var.github_org}/${var.github_deploy_repo}/.github/workflows/exit-test-terraform.yml@refs/heads/main"
  # exit-test-substrate.yml reads the NLB and its security groups on the eks
  # leg (hosted#508). Its job declares `environment: eks`, so its sub is the
  # environment-shaped one. job_workflow_ref still pins that one caller.
  gh_eks_substrate_sub              = "repo:${var.github_org}@*/${var.github_deploy_repo}@*:environment:eks"
  gh_eks_substrate_job_workflow_ref = "${var.github_org}/${var.github_deploy_repo}/.github/workflows/exit-test-substrate.yml@refs/heads/main"
}

data "aws_iam_policy_document" "eks_plan_trust" {
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
      values   = [local.gh_eks_plan_sub]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = [local.gh_eks_plan_job_workflow_ref]
    }
  }

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
      values   = [local.gh_eks_substrate_sub]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = [local.gh_eks_substrate_job_workflow_ref]
    }
  }
}

resource "aws_iam_role" "eks_plan_readonly" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "eks-plan-readonly"
  description          = "Read-only role assumed by zeroroot-ai/hosted's exit-test-terraform.yml (terraform plan on eks/gibson) and exit-test-substrate.yml (the NLB security group check on the eks leg)."
  assume_role_policy   = data.aws_iam_policy_document.eks_plan_trust[0].json
  permissions_boundary = aws_iam_policy.operator_permission_boundary[0].arn
  max_session_duration = 3600 # 1 hour — a plan of the full workspace takes minutes, not hours

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_plan_ro" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  role       = aws_iam_role.eks_plan_readonly[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess covers kms:Describe/Get/List but NOT kms:Decrypt, and the
# terraform state buckets are SSE-KMS. Without this the plan fails on
# `terraform init` with AccessDenied reading the state object, which reads like
# a broken workflow rather than a missing grant. Scoped to S3-mediated decrypts
# so the role cannot decrypt anything else the key protects.
data "aws_iam_policy_document" "eks_plan_state_read" {
  count = length(var.prod_account_id) > 0 ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "eks_plan_state_read" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name   = "eks-plan-readonly-state-decrypt"
  role   = aws_iam_role.eks_plan_readonly[0].id
  policy = data.aws_iam_policy_document.eks_plan_state_read[0].json
}
