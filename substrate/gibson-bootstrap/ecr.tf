# ----------------------------------------------------------------------------
# The setec disk registry (D85, hosted#521, ADR-0166).
#
# In plain words: one private ECR repository per environment holds the signed
# sandbox disks. The setec disk builder makes one disk for each image digest
# and pushes it here. Each launcher Pod mounts that disk as an image volume,
# so the kubelet of the node pulls it.
#
#   repository     zeroroot-ai-<env>-setec-disks
#   disk builder   IAM user zeroroot-ai-<env>-setec-disk-builder, push and pull
#                  on this repository and nothing else
#   node pull      stage 1 grants it to the node role (bootstrap/ec2/gibson
#                  ecr.tf; the EKS node role holds
#                  AmazonEC2ContainerRegistryReadOnly)
#
# The repository is stage 0 because it outlives each cluster: a new cluster
# finds the disks of the last one and builds only the disks it does not find.
# The overlay of each env names the repository URL as a reviewed commit
# (gitops/envs/<env>/values.yaml, setec.launcher.diskRepo), and
# scripts/check-overlay-disk-repo.py proves the overlay names the URL that
# this file makes.
#
# Tags are IMMUTABLE. The disk builder writes one tag per image digest and
# skips a tag that exists (setec internal/diskbuilder/store.go), so a tag never
# needs to move. An immutable tag also means that the push credential cannot
# replace a disk that a launcher already trusts.
#
# Encryption is AES256. ADR-0083 puts no cloud KMS in the data path, so this
# workspace creates no key.
# ----------------------------------------------------------------------------

locals {
  disk_repository_name = "zeroroot-ai-${var.environment}-setec-disks"
}

resource "aws_ecr_repository" "setec_disks" {
  name                 = local.disk_repository_name
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }

  lifecycle {
    precondition {
      condition     = local.account_id == var.aws_account_id
      error_message = "The AWS session is in account ${local.account_id}, but envs/${var.environment}.tfvars names ${var.aws_account_id}. Select the environment's profile."
    }
  }
}

# An interrupted push can leave an untagged manifest. No launcher pulls an
# untagged disk, so it goes after one day. A tagged disk never expires here:
# a disk belongs to an image digest that a Sandbox can ask for again.
resource "aws_ecr_lifecycle_policy" "setec_disks" {
  repository = aws_ecr_repository.setec_disks.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged manifests after one day"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 1
      }
      action = { type = "expire" }
    }]
  })
}

# The disk builder credential. The disk builder runs as a Job in a cluster
# Pod. A Pod cannot reach the instance role (IMDSv2 hop limit 1 on every
# node), and stage 1 mints no IRSA role (deploy#1744), so the builder gets an
# access key pair, the same shape as the bucket and DNS credentials above.
# substrate.sh puts the pair in the keyring. It rotates through two key
# slots like the other substrate users (scripts/substrate-rotate.sh).
resource "aws_iam_user" "setec_disk_builder" {
  name                 = "zeroroot-ai-${var.environment}-setec-disk-builder"
  path                 = "/substrate/"
  permissions_boundary = local.identity_permissions_boundary_arn
}

# One key for each slot in key_slots["setec-disk-builder"].keep
# (variables.tf). Two slots exist only while scripts/substrate-rotate.sh
# moves the cluster to a new key (CREDENTIAL=setec-disk-builder).
resource "aws_iam_access_key" "setec_disk_builder" {
  for_each = var.key_slots["setec-disk-builder"].keep

  user = aws_iam_user.setec_disk_builder.name
}

moved {
  from = aws_iam_access_key.setec_disk_builder
  to   = aws_iam_access_key.setec_disk_builder["a"]
}

data "aws_iam_policy_document" "setec_disk_builder" {
  # GetAuthorizationToken has no resource scope in IAM. The token it returns
  # opens only what the other statement allows.
  statement {
    sid       = "RegistryLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push, and the reads a push needs: the builder asks for the tag before it
  # builds, and a layer upload checks each layer first. No delete.
  statement {
    sid    = "PushDisks"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [aws_ecr_repository.setec_disks.arn]
  }
}

resource "aws_iam_user_policy" "setec_disk_builder" {
  name   = "setec-disk-push"
  user   = aws_iam_user.setec_disk_builder.name
  policy = data.aws_iam_policy_document.setec_disk_builder.json
}

# ----------------------------------------------------------------------------
# The belief trainer registry (gibson#31, the D85 path).
#
# In plain words: the SaaS trainer image (ghcr.io/zeroroot-ai/billing-belief-
# trainer, which carries the curated base model) is private. The trainer
# CronJob runs in each tenant namespace, which has no image pull secret, and
# must not get one: a tenant namespace also runs third-party MCP pods. So the
# node pulls a copy of the image from a private ECR repository of the env
# with its instance role, as it pulls the setec disks.
#
#   repository     zeroroot-ai-<env>-belief-trainer
#   copy           scripts/belief-trainer-image.sh, at stage 1 with the
#                  operator session: it copies the image that the overlay
#                  pins from GHCR with its digest unchanged
#   node pull      stage 1 grants it to the node role (bootstrap/ec2/gibson
#                  ecr.tf; the EKS node role holds
#                  AmazonEC2ContainerRegistryReadOnly)
#
# Tags are IMMUTABLE: a tag holds the one digest that the overlay pins.
# ----------------------------------------------------------------------------

resource "aws_ecr_repository" "belief_trainer" {
  name                 = "zeroroot-ai-${var.environment}-belief-trainer"
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }

  lifecycle {
    precondition {
      condition     = local.account_id == var.aws_account_id
      error_message = "The AWS session is in account ${local.account_id}, but envs/${var.environment}.tfvars names ${var.aws_account_id}. Select the environment's profile."
    }
  }
}

# An interrupted copy can leave an untagged manifest. A tagged image never
# expires here: an overlay of an older promotion can name it again.
resource "aws_ecr_lifecycle_policy" "belief_trainer" {
  repository = aws_ecr_repository.belief_trainer.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged manifests after one day"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 1
      }
      action = { type = "expire" }
    }]
  })
}
