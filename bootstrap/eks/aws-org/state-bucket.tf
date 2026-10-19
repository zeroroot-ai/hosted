# ----------------------------------------------------------------------------
# State bucket for the aws-org workspace (lives in zeroroot-ai-mgmt).
#
# This is the s3 backend the workspace migrates to after first apply. The
# initial apply uses local state; the second apply (with backend.tf
# uncommented) migrates state into this bucket.
#
# NOTE: this is NOT the zeroroot-ai-prod workspace's state bucket. That lives in
# zeroroot-ai-prod itself, provisioned by the zeroroot-ai-prod-bootstrap workspace, per
# design.md (blast-radius isolation: a credential leak in mgmt should not
# unlock prod state).
# ----------------------------------------------------------------------------

# Dedicated KMS key for the state bucket. Multi-region disabled, rotation on,
# 30-day deletion window.
resource "aws_kms_key" "state" {
  description             = "Encrypts the aws-org workspace's Terraform state bucket."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false

  tags = merge(local.common_tags, {
    Name = "${var.mgmt_name_prefix}-tf-state"
  })
}

resource "aws_kms_alias" "state" {
  name          = "alias/${var.mgmt_name_prefix}-tf-state"
  target_key_id = aws_kms_key.state.key_id
}

# State bucket. prevent_destroy lifecycle to avoid accidental terraform
# destroy from wiping state — operator must explicitly remove the
# prevent_destroy block to delete (and even then, MFA-delete bites unless
# disabled).
resource "aws_s3_bucket" "state" {
  bucket = "${var.mgmt_name_prefix}-tfstate-${data.aws_caller_identity.mgmt.account_id}-${var.aws_region}"

  tags = merge(local.common_tags, {
    Name = "${var.mgmt_name_prefix}-tfstate"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Access logs are written to the state bucket itself under _access-logs/.
# Cheap and self-contained; no second bucket needed.
resource "aws_s3_bucket_logging" "state" {
  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.state.id
  target_prefix = "_access-logs/"
}

# Lifecycle for noncurrent versions only — state file size is tiny but
# every plan/apply emits a new version. Keep 90 days of history; expire
# after.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-90d"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# TLS-only bucket policy.
data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

# DynamoDB lock table — single PK on LockID, PAY_PER_REQUEST so we are not
# paying for capacity that sits idle 99% of the time.
resource "aws_dynamodb_table" "state_lock" {
  name         = "${var.mgmt_name_prefix}-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name = "zeroroot-ai-mgmt-tf-locks"
  })

  lifecycle {
    prevent_destroy = true
  }
}
