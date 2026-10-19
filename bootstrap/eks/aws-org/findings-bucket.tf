# ----------------------------------------------------------------------------
# Security findings bucket in zeroroot-ai-mgmt.
#
# Receives:
#   - GuardDuty findings export from zeroroot-ai-prod (configured by
#     module.guardduty_config in the zeroroot-ai-prod workspace; this workspace
#     only owns the bucket).
#   - Optionally: AWS Config / Security Hub aggregator (future).
#
# Lifecycle: Glacier@90d, expire@2192d (6 years per R12.1 + R13.3).
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "findings" {
  bucket = "${var.findings_bucket_name_prefix}-security-findings-${data.aws_caller_identity.mgmt.account_id}-${var.aws_region}"

  tags = merge(local.common_tags, {
    Name = "${var.findings_bucket_name_prefix}-security-findings"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "findings" {
  bucket = aws_s3_bucket.findings.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "findings" {
  bucket = aws_s3_bucket.findings.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.findings.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "findings" {
  bucket                  = aws_s3_bucket.findings.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "findings" {
  bucket = aws_s3_bucket.findings.id

  rule {
    id     = "glacier-then-expire-6y"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 2192
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# Dedicated KMS key for findings.
resource "aws_kms_key" "findings" {
  description             = "Encrypts GuardDuty + Security Hub findings exports from zeroroot-ai-prod."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.findings_kms.json

  tags = merge(local.common_tags, {
    Name = "${var.mgmt_name_prefix}-findings"
  })
}

resource "aws_kms_alias" "findings" {
  name          = "alias/${var.mgmt_name_prefix}-findings"
  target_key_id = aws_kms_key.findings.key_id
}

data "aws_iam_policy_document" "findings_kms" {
  statement {
    sid    = "AccountRootAdministration"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.mgmt.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # GuardDuty service principal in any org account can encrypt findings into
  # this bucket.
  statement {
    sid    = "AllowGuardDutyEncrypt"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["guardduty.amazonaws.com"]
    }
    actions = [
      "kms:GenerateDataKey",
      "kms:Encrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [aws_organizations_organization.this.id]
    }
  }

  # Org principals can decrypt to read findings.
  statement {
    sid    = "AllowOrgPrincipalsToDecrypt"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [aws_organizations_organization.this.id]
    }
  }
}

# Bucket policy — GuardDuty service principal in any org account can write;
# only org principals can read.
data "aws_iam_policy_document" "findings_bucket" {
  statement {
    sid    = "AllowGuardDutyAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["guardduty.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.findings.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [aws_organizations_organization.this.id]
    }
  }

  statement {
    sid    = "AllowGuardDutyPutObject"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["guardduty.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.findings.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [aws_organizations_organization.this.id]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
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
      aws_s3_bucket.findings.arn,
      "${aws_s3_bucket.findings.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "findings" {
  bucket = aws_s3_bucket.findings.id
  policy = data.aws_iam_policy_document.findings_bucket.json
}
