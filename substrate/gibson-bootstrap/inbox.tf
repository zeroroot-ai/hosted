# ----------------------------------------------------------------------------
# The test inbox of this environment (hosted#647).
#
# The bringup smoke and the signup exit test sign up through the real edge
# with one driver (test/signup/driver.mjs). On kind the verification mail
# lands in Mailpit. On an AWS environment it leaves through SES, so the
# driver needs a mailbox it can read: this one.
#
#   inbox.<zone_name>  MX to the SES inbound endpoint of the region
#   one SES rule       in the ONE active rule set that substrate/apex-zone
#                      owns. Its name carries the environment, and it takes
#                      mail only for inbox.<zone_name>, so no environment
#                      receives the mail of another
#   one bucket         SSE, public access blocked, every object expires after
#                      one day; only SES writes, and only the smoke driver
#                      role (var.inbox_reader_role_name) reads
#
# Order: substrate/apex-zone first. substrate.sh refuses this stage when the
# account has no active rule set, with that message. Stage 0 outlives every
# cluster, so no teardown reaches these resources, and none reaches the rule
# set (scripts/check-ses-rule-set-owner.py).
# ----------------------------------------------------------------------------

locals {
  inbox_domain    = "inbox.${var.zone_name}"
  inbox_bucket    = "zeroroot-ai-${var.environment}-inbox-${var.aws_account_id}"
  inbox_rule_name = "zeroroot-ai-${var.environment}-inbox"
}

data "aws_ses_active_receipt_rule_set" "inbox" {}

data "aws_iam_role" "inbox_reader" {
  name = var.inbox_reader_role_name
}

resource "aws_s3_bucket" "inbox" {
  bucket = local.inbox_bucket
  # Test mail of one day. A stage 0 destroy (never a teardown) may empty it.
  force_destroy = true

  tags = {
    Name = local.inbox_bucket
  }
}

resource "aws_s3_bucket_ownership_controls" "inbox" {
  bucket = aws_s3_bucket.inbox.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "inbox" {
  bucket = aws_s3_bucket.inbox.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "inbox" {
  bucket                  = aws_s3_bucket.inbox.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "inbox" {
  bucket = aws_s3_bucket.inbox.id
  rule {
    id     = "expire-test-mail"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

data "aws_iam_policy_document" "inbox" {
  # SES writes the mail of this environment's rule, and of no other.
  statement {
    sid     = "SESWritesThisEnvironmentRule"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.inbox.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ses:${var.aws_region}:${var.aws_account_id}:receipt-rule-set/${data.aws_ses_active_receipt_rule_set.inbox.rule_set_name}:receipt-rule/${local.inbox_rule_name}"]
    }
  }

  # The smoke driver reads and clears the mail.
  statement {
    sid     = "SmokeDriverReads"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_iam_role.inbox_reader.arn]
    }
    resources = [aws_s3_bucket.inbox.arn, "${aws_s3_bucket.inbox.arn}/*"]
  }

  # Nobody else reads the mail, whatever their IAM policy grants.
  statement {
    sid       = "NobodyElseReads"
    effect    = "Deny"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.inbox.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = [data.aws_iam_role.inbox_reader.arn]
    }
  }

  statement {
    sid       = "TLSOnly"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.inbox.arn, "${aws_s3_bucket.inbox.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "inbox" {
  bucket = aws_s3_bucket.inbox.id
  policy = data.aws_iam_policy_document.inbox.json

  depends_on = [aws_s3_bucket_public_access_block.inbox]
}

resource "aws_route53_record" "inbox_mx" {
  zone_id = local.zone_id
  name    = local.inbox_domain
  type    = "MX"
  ttl     = 300
  records = ["10 inbound-smtp.${var.aws_region}.amazonaws.com"]
}

resource "aws_ses_receipt_rule" "inbox" {
  name          = local.inbox_rule_name
  rule_set_name = data.aws_ses_active_receipt_rule_set.inbox.rule_set_name
  recipients    = [local.inbox_domain]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Require"

  s3_action {
    bucket_name       = aws_s3_bucket.inbox.id
    object_key_prefix = "mail/"
    position          = 1
  }

  lifecycle {
    precondition {
      condition     = data.aws_ses_active_receipt_rule_set.inbox.rule_set_name == var.inbox_rule_set_name
      error_message = "The active SES receipt rule set of the account is not ${var.inbox_rule_set_name}. Apply substrate/apex-zone first: it owns the one rule set (hosted#647)."
    }
  }

  depends_on = [aws_s3_bucket_policy.inbox]
}
