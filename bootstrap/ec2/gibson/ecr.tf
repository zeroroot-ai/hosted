# ----------------------------------------------------------------------------
# The node pulls the setec sandbox disks (D85, hosted#521).
#
# Stage 0 (substrate/gibson-bootstrap/ecr.tf) makes the repository
# zeroroot-ai-<env>-setec-disks. The kubelet pulls each disk as an image
# volume with the instance role, through the ECR credential provider that
# node-init installs (templates/ecr-credential-provider.sh.tftpl). The
# kubelet also pulls the belief trainer image copy of the env
# (zeroroot-ai-<env>-belief-trainer, gibson#31) the same way. So the role
# gets pull on these two repositories and nothing else: no push, and no
# other repository.
#
# The repository is named, not read as a data source. Stage 0 runs before
# stage 1, and a name that does not match is a pull that fails on the node,
# which `make preflight` and the exit test both see. The account comes from
# the session, so the ARN is the one of the account that runs this root.
# ----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  setec_disk_repository_arn = "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/zeroroot-ai-${var.environment}-setec-disks"
  # The belief trainer image copy (gibson#31). The kubelet pulls it for the
  # trainer CronJob of each tenant namespace, which has no pull secret.
  belief_trainer_repository_arn = "arn:${data.aws_partition.current.partition}:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/zeroroot-ai-${var.environment}-belief-trainer"
}

data "aws_iam_policy_document" "node_setec_disk_pull" {
  # GetAuthorizationToken has no resource scope in IAM. The token opens only
  # what the statement below allows.
  statement {
    sid       = "RegistryLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PullDisksAndTrainer"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [local.setec_disk_repository_arn, local.belief_trainer_repository_arn]
  }
}

resource "aws_iam_role_policy" "node_setec_disk_pull" {
  name   = "${var.cluster_name}-setec-disk-pull"
  role   = aws_iam_role.node.name
  policy = data.aws_iam_policy_document.node_setec_disk_pull.json
}
