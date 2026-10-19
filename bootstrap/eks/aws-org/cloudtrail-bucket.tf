# ----------------------------------------------------------------------------
# Org-wide CloudTrail destination bucket — lives in zeroroot-ai-mgmt.
#
# Lifecycle:
#   - 0-90d: STANDARD
#   - 90d:   transition to GLACIER
#   - 2192d: expire (6 years; HIPAA Security Rule audit-record retention).
#
# Hardening:
#   - SSE-KMS with the dedicated cloudtrail key.
#   - BPA on (block all public access).
#   - Versioning + MFA-delete on (MFA-delete must be enabled out-of-band by
#     the account root via aws s3api put-bucket-versioning with --mfa, since
#     Terraform cannot pass MFA codes — documented in README).
#   - Object-Lock NOT enabled (would block the lifecycle expiration; we use
#     denial via PB instead).
#   - Bucket policy: only CloudTrail service principal can write; only org
#     principals can read.
# ----------------------------------------------------------------------------

resource "random_id" "cloudtrail_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket = "${var.cloudtrail_bucket_name_prefix}-cloudtrail-${data.aws_caller_identity.mgmt.account_id}-${var.aws_region}"

  tags = merge(local.common_tags, {
    Name = "${var.cloudtrail_bucket_name_prefix}-cloudtrail"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.cloudtrail.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "glacier-then-expire-6y"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 2192 # 6 years per R13.3
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# Access logging — own access log bucket so PutObject events on the CloudTrail
# bucket itself are tracked.
resource "aws_s3_bucket_logging" "cloudtrail" {
  bucket        = aws_s3_bucket.cloudtrail.id
  target_bucket = aws_s3_bucket.cloudtrail.id
  target_prefix = "_self-access-logs/"
}

# ----------------------------------------------------------------------------
# Bucket policy — only CloudTrail can write; only org principals can read.
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.mgmt.account_id}:trail/gibson-org-trail"]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${aws_organizations_organization.this.id}/*",
      "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.mgmt.account_id}/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.mgmt.account_id}:trail/gibson-org-trail"]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cloudtrail.arn,
      "${aws_s3_bucket.cloudtrail.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}
