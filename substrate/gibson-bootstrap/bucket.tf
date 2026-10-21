# ----------------------------------------------------------------------------
# The durable bucket. One bucket per environment, three prefixes with their
# own lifecycle rule, and the properties preflight proves:
#
#   versioning on                 aws_s3_bucket_versioning
#   the platform credential       aws_s3_bucket_policy, statement DenyPlatformDelete
#     cannot delete
#   a lifecycle rule per prefix   aws_s3_bucket_lifecycle_configuration
#
# Prefixes:
#   tfstate/    Terraform state of stage 1 (eks/gibson) and of anything else
#               that must outlive a cluster. Current versions never expire,
#               noncurrent versions go after 90 days.
#   backups/    Velero, CNPG WAL and base backups, the OpenBao archive. Cold
#               storage after 30 days, expired at 180.
#   audit/      the append-only audit log. Object lock, six years, then the
#               lifecycle rule expires it. Never before.
#   preflight/  the canaries preflight writes and cannot delete. One day.
#
# Object lock is enabled on the bucket at creation, which is the only time it
# can be. There is no default retention: a bucket-wide default would lock the
# state and every canary too. The retention on audit/ comes from the bucket
# policy, which refuses a write under audit/ that does not carry a lock of at
# least var.audit_retention_days in var.audit_lock_mode. Object lock needs
# nothing from KMS.
#
# Locking of the Terraform state that lives under tfstate/ is S3 native
# (use_lockfile in the eks/gibson backend), so stage 0 is one bucket and no
# DynamoDB table.
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "durable" {
  bucket              = local.bucket_name
  object_lock_enabled = true

  tags = {
    Name = local.bucket_name
  }

  lifecycle {
    # The bucket holds the state of this workspace (backend.tf). An apply
    # that would destroy it fails at plan time. substrate.sh also refuses any
    # plan that deletes a resource.
    prevent_destroy = true

    precondition {
      condition     = local.account_id == var.aws_account_id
      error_message = "The AWS session is in account ${local.account_id}, but envs/${var.environment}.tfvars names ${var.aws_account_id}. Select the environment's profile."
    }
  }
}

resource "aws_s3_bucket_versioning" "durable" {
  bucket = aws_s3_bucket.durable.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "durable" {
  bucket = aws_s3_bucket.durable.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "durable" {
  bucket                  = aws_s3_bucket.durable.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "durable" {
  bucket = aws_s3_bucket.durable.id

  depends_on = [aws_s3_bucket_versioning.durable]

  rule {
    id     = "tfstate"
    status = "Enabled"
    filter {
      prefix = "tfstate/"
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "backups"
    status = "Enabled"
    filter {
      prefix = "backups/"
    }
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = 180
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "audit"
    status = "Enabled"
    filter {
      prefix = "audit/"
    }
    expiration {
      days = var.audit_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.audit_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "preflight"
    status = "Enabled"
    filter {
      prefix = "preflight/"
    }
    expiration {
      days = 1
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

data "aws_iam_policy_document" "durable" {
  # The state of stage 0, its key slots and its rotation record. Only the
  # rotation role and the operator role touch them (rotation-role.tf,
  # scripts/stage0-store.sh). The state holds the access keys of the stage 0
  # users, and the platform credential and every other principal are refused.
  statement {
    sid    = "DenyStage0StateToEveryoneElse"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = ["${aws_s3_bucket.durable.arn}/${local.state_prefix}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values = concat(
        [for r in var.stage0_state_principal_role_names : "arn:aws:iam::${var.aws_account_id}:role/${r}"],
        var.rotation_role_enabled ? [aws_iam_role.rotation[0].arn] : [],
      )
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.durable.arn, "${aws_s3_bucket.durable.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # The platform credential cannot destroy a version, cannot weaken the
  # bucket, and cannot bypass a governance lock. Its IAM policy grants none of
  # these either. This statement is what preflight proves with an attempted
  # delete, and it holds even if that policy is widened.
  statement {
    sid    = "DenyPlatformDestroy"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.platform.arn]
    }
    actions = [
      "s3:DeleteObjectVersion",
      "s3:DeleteObjectTagging",
      "s3:DeleteObjectVersionTagging",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:BypassGovernanceRetention",
      "s3:PutBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketObjectLockConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutEncryptionConfiguration",
    ]
    resources = [aws_s3_bucket.durable.arn, "${aws_s3_bucket.durable.arn}/*"]
  }

  # s3:DeleteObject everywhere EXCEPT Velero's own prefix (deploy#1734).
  # Velero's kopia repository cannot complete a backup without deleting its
  # own session markers, so that one prefix is carved out here and in the
  # platform IAM policy. On a versioned bucket a DeleteObject writes a delete
  # marker and keeps the version, and DeleteObjectVersion stays denied above,
  # so nothing this credential does removes data. `not_resources` is what
  # makes the carve-out a hole of exactly one prefix: a bucket policy is
  # evaluated only for requests to this bucket.
  statement {
    sid    = "DenyPlatformDeleteOutsideVeleroRepository"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = [aws_iam_user.platform.arn]
    }
    actions       = ["s3:DeleteObject"]
    not_resources = ["${aws_s3_bucket.durable.arn}/backups/velero/*"]
  }

  # Every write under audit/ carries an object lock in the environment's mode
  # for at least the retention period. A write with no lock header fails the
  # first statement (a missing key makes StringNotEquals true). A write with
  # a shorter lock fails the second.
  statement {
    sid    = "DenyUnlockedAuditWrite"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.durable.arn}/audit/*"]
    condition {
      test     = "StringNotEquals"
      variable = "s3:object-lock-mode"
      values   = [var.audit_lock_mode]
    }
  }

  statement {
    sid    = "DenyShortAuditLock"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.durable.arn}/audit/*"]
    condition {
      test     = "NumericLessThan"
      variable = "s3:object-lock-remaining-retention-days"
      values   = [tostring(var.audit_retention_days)]
    }
  }
}

resource "aws_s3_bucket_policy" "durable" {
  bucket = aws_s3_bucket.durable.id
  policy = data.aws_iam_policy_document.durable.json

  depends_on = [aws_s3_bucket_public_access_block.durable]
}
