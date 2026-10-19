# ----------------------------------------------------------------------------
# Org-wide CloudTrail in zeroroot-ai-mgmt.
#
# is_organization_trail = true means events from every member account
# (currently just zeroroot-ai-prod) are aggregated to a single bucket in mgmt.
# Multi-region + log-file-validation + KMS-encrypted are all required by
# R13.6.
#
# The trail itself is in this file; the destination bucket is in
# cloudtrail-bucket.tf to keep ownership boundaries clear.
# ----------------------------------------------------------------------------

resource "aws_cloudtrail" "org" {
  name                          = "gibson-org-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_organization_trail         = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  include_global_service_events = true
  kms_key_id                    = aws_kms_key.cloudtrail.arn

  # Capture data events for sensitive S3 buckets (state, audit, findings,
  # cloudtrail itself). Without these, S3 PutObject on those buckets is not
  # logged, and any operator who wipes a state file would not leave a trace.
  #
  # deploy#1200: the per-workspace platform *audit* buckets in the member
  # account were missing from this selector despite the selector's own name
  # claiming to cover them, so object-level writes and deletes on the HIPAA
  # evidence store were the one thing in this list that left no trace. This is
  # an organization trail, so member-account data events land here too.
  advanced_event_selector {
    name = "ManagementEvents"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  advanced_event_selector {
    name = "S3DataEvents-StateAndAuditBuckets"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field = "resources.ARN"
      starts_with = concat(
        [
          "${aws_s3_bucket.cloudtrail.arn}/",
          "${aws_s3_bucket.state.arn}/",
          "${aws_s3_bucket.findings.arn}/",
        ],
        local.platform_audit_bucket_object_arn_prefixes,
      )
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_s3_bucket_policy.cloudtrail,
    aws_kms_key_policy.cloudtrail,
  ]
}

# Dedicated KMS key for CloudTrail. Rotation enabled, 30-day deletion window,
# tied to a key policy that lets CloudTrail write but locks out everyone else
# from decrypting except the org's CloudTrail readers.
resource "aws_kms_key" "cloudtrail" {
  description             = "Encrypts org-wide CloudTrail events written to gibson-org-cloudtrail bucket."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false

  tags = merge(local.common_tags, {
    Name = "${var.mgmt_name_prefix}-cloudtrail"
  })
}

resource "aws_kms_alias" "cloudtrail" {
  name          = "alias/${var.mgmt_name_prefix}-cloudtrail"
  target_key_id = aws_kms_key.cloudtrail.key_id
}

resource "aws_kms_key_policy" "cloudtrail" {
  key_id = aws_kms_key.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_kms.json
}

data "aws_iam_policy_document" "cloudtrail_kms" {
  # Account root can manage the key (recover-from-IAM-mistake escape hatch).
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

  # CloudTrail service principal can encrypt log files, in this org only.
  statement {
    sid    = "AllowCloudTrailEncrypt"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions = [
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.mgmt.account_id}:trail/gibson-org-trail"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${data.aws_caller_identity.mgmt.account_id}:trail/gibson-org-trail"]
    }
  }

  # Anyone in the org can decrypt to read the events.
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
