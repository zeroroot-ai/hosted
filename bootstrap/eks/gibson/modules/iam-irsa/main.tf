# ----------------------------------------------------------------------------
# The three controller IRSA roles stage 1 keeps (ADR-0083): the AWS Load
# Balancer Controller, the EBS CSI driver and Karpenter. Each role's trust
# policy is locked to one `system:serviceaccount:<ns>:<sa>` subject; each
# role grants only what that controller needs.
#
# Every workload role is gone (deploy#1744). A platform workload that needs
# a cloud object store uses the durable bucket credential from the bringup
# keyring (stage 0, eks/gibson-bootstrap); workload identity is an optional
# overlay later, never a stage 1 concern.
# ----------------------------------------------------------------------------

# THE PARTITION IS AN INPUT, NOT A DATA SOURCE READ HERE.
#
# This module is invoked with `depends_on`, and Terraform defers EVERY data
# source inside such a module to apply time whenever that dependency has
# pending changes. A deferred data source makes its value unknown, and an
# unknown value on a ForceNew attribute forces a replacement.
#
# That is what happened. `policy_arn` below is ForceNew, and it interpolated
# the partition:
#
#   # module.iam_irsa.aws_iam_role_policy_attachment.ebs_csi must be replaced
#   ~ policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
#       -> (known after apply) # forces replacement
#
# measured on exit-test-terraform run 34990262565. It is the same shape as
# deploy#1588 defect 2, where a bucket name interpolated an account id that
# Terraform deferred and the unknown name forced the bucket to be replaced.
#
# A partition is a constant of the provider and has no business being read
# inside a module that waits on a cluster. The root reads it, where nothing
# defers it, and passes it in.
#
# The other two data sources here are safe: aws_iam_policy_document.trust
# feeds assume_role_policy, which updates in place.

locals {
  partition = var.partition
  oidc_host = replace(var.oidc_provider_url, "https://", "")

  roles = {
    aws_lb_controller = {
      namespace = "kube-system"
      sa_name   = "aws-load-balancer-controller"
    }
    karpenter = {
      namespace = "kube-system"
      sa_name   = "karpenter"
    }
    ebs_csi = {
      namespace = "kube-system"
      sa_name   = "ebs-csi-controller-sa"
    }
  }
}

# ----------------------------------------------------------------------------
# Permission boundary — one reusable IAM policy attached to every role below.
# Defence-in-depth on top of the per-role policies.
# ----------------------------------------------------------------------------

resource "aws_iam_policy" "boundary_controller" {
  name        = "${var.workspace_name}-pb-controller"
  description = "PB-ControllerMaxPermissions — boundary for in-cluster controller IRSA roles."
  policy      = file("${path.module}/policies/permission-boundary-controller.json")
}

# ----------------------------------------------------------------------------
# Shared trust-policy template (one per role, federated against the cluster's
# OIDC provider with a subject + audience condition).
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "trust" {
  for_each = local.roles

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Exact subject match only — never StringLike here: a wildcard subject
    # turns "can create a namespace + ServiceAccount" into "can assume this
    # role".
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.sa_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  for_each = local.roles

  name               = "${var.workspace_name}-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json

  permissions_boundary = aws_iam_policy.boundary_controller.arn

  tags = {
    WorkloadNamespace = each.value.namespace
    WorkloadSA        = each.value.sa_name
  }
}

# ----------------------------------------------------------------------------
# Per-role policies. File-backed JSON for the two large upstream-defined
# policies; the AWS managed policy for the EBS CSI driver.
# ----------------------------------------------------------------------------

# AWS Load Balancer Controller: the upstream-published policy.
resource "aws_iam_policy" "aws_lb_controller" {
  name        = "${var.workspace_name}-aws-lb-controller"
  description = "AWS Load Balancer Controller IRSA policy"
  policy      = file("${path.module}/policies/aws-lb-controller.json")
}

resource "aws_iam_role_policy_attachment" "aws_lb_controller_managed" {
  role       = aws_iam_role.this["aws_lb_controller"].name
  policy_arn = aws_iam_policy.aws_lb_controller.arn
}

# Karpenter: EC2 Describe/Launch/Terminate + PassRole for the node role.
resource "aws_iam_policy" "karpenter" {
  name        = "${var.workspace_name}-karpenter"
  description = "Karpenter controller IRSA policy"
  policy      = templatefile("${path.module}/policies/karpenter.json", { CLUSTER_NAME = var.cluster_name })
}

resource "aws_iam_role_policy_attachment" "karpenter_managed" {
  role       = aws_iam_role.this["karpenter"].name
  policy_arn = aws_iam_policy.karpenter.arn
}

# EBS CSI: managed policy.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.this["ebs_csi"].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
