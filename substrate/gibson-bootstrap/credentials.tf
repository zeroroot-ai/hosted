# ----------------------------------------------------------------------------
# The three credentials stage 0 mints. All go into the bringup keyring through
# substrate.sh and nowhere else. Each rotates through two key slots
# (key_slots in variables.tf, scripts/substrate-rotate.sh). All are in this workspace's local state,
# which is why that state lives with the keyring (README.md).
# ----------------------------------------------------------------------------

# The platform credential: what every workload that touches the durable
# bucket uses (Velero, CNPG, the OpenBao archive, the audit sink) and what
# preflight uses. Read, list, write, set a retention, no change to the bucket,
# and one delete: s3:DeleteObject under backups/velero/ (deploy#1734). The
# same allow list as kind's MinIO policy in kind/substrate/substrate.sh, so
# preflight proves one shape on both.
resource "aws_iam_user" "platform" {
  name                 = "zeroroot-ai-${var.environment}-platform"
  path                 = "/substrate/"
  permissions_boundary = local.identity_permissions_boundary_arn
}

# One key for each slot in key_slots.platform.keep (variables.tf). Two slots
# exist only during a rotation (scripts/substrate-rotate.sh).
resource "aws_iam_access_key" "platform" {
  for_each = var.key_slots["platform"].keep

  user = aws_iam_user.platform.name
}

moved {
  from = aws_iam_access_key.platform
  to   = aws_iam_access_key.platform["a"]
}

data "aws_iam_policy_document" "platform" {
  statement {
    sid    = "Bucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketVersioning",
      "s3:GetLifecycleConfiguration",
      "s3:GetBucketObjectLockConfiguration",
    ]
    resources = [aws_s3_bucket.durable.arn]
  }

  statement {
    sid    = "Objects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:GetObjectRetention",
      "s3:PutObjectRetention",
    ]
    resources = ["${aws_s3_bucket.durable.arn}/*"]
  }

  # THE ONE DELETE (deploy#1734). Velero's kopia repository writes a session
  # marker for every flush and removes it when the flush lands; a repository
  # that cannot delete that marker cannot complete a single backup (measured
  # on kind: "unable to complete DeleteBlob ... Access Denied"). It is scoped
  # to Velero's own prefix, it is s3:DeleteObject and never
  # s3:DeleteObjectVersion, and the bucket is versioned — so the delete
  # writes a delete marker and the object version stays until the lifecycle
  # rule on backups/ expires it. Nothing under backups/postgres/, audit/ or
  # tfstate/ is reachable by it.
  statement {
    sid    = "VeleroRepositoryDelete"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.durable.arn}/backups/velero/*"]
  }
}

resource "aws_iam_user_policy" "platform" {
  name   = "durable-bucket"
  user   = aws_iam_user.platform.name
  policy = data.aws_iam_policy_document.platform.json
}

# The SMTP relay credential. By default an IAM user whose access key id is
# the SMTP user and whose SES SMTP password (v4, region-bound) is derived by
# the provider from the secret key. It may send as the company's verified
# domain identity, which eks/apex-zone owns, and nothing else.
resource "aws_iam_user" "smtp" {
  count = local.ses_relay ? 1 : 0

  name                 = "zeroroot-ai-${var.environment}-smtp"
  path                 = "/substrate/"
  permissions_boundary = local.identity_permissions_boundary_arn
}

resource "aws_iam_access_key" "smtp" {
  for_each = local.ses_relay ? var.key_slots["smtp"].keep : toset([])

  user = aws_iam_user.smtp[0].name
}

moved {
  from = aws_iam_access_key.smtp[0]
  to   = aws_iam_access_key.smtp["a"]
}

data "aws_iam_policy_document" "smtp" {
  count = local.ses_relay ? 1 : 0

  statement {
    sid       = "SendAsApexIdentity"
    effect    = "Allow"
    actions   = ["ses:SendRawEmail", "ses:SendEmail"]
    resources = ["arn:aws:ses:${var.aws_region}:${var.aws_account_id}:identity/${var.apex_zone_name}"]
  }
}

resource "aws_iam_user_policy" "smtp" {
  count = local.ses_relay ? 1 : 0

  name   = "ses-smtp-send"
  user   = aws_iam_user.smtp[0].name
  policy = data.aws_iam_policy_document.smtp[0].json
}

# The DNS credential. cert-manager publishes the ACME DNS-01 challenge record
# and external-dns publishes the platform's records, both into the
# environment's zone and nothing else. Stage 1 mints no IRSA role
# (deploy#1744), so this is the one credential the two operators have: the
# keyring's DNS_ACCESS_KEY and DNS_SECRET_KEY, written by the bringup into
# the Secret route53-credential. Measured on staging 2026-09-10 without it:
# every ACME challenge pending on "no EC2 IMDS role found", no record
# published, no edge certificate, no platform.
#
# ListHostedZones and ListHostedZonesByName carry no resource scope in IAM,
# so they are allowed on every zone; the writes are scoped to this zone.
# GetChange polls a change batch by id, which is not zone-scoped either.
resource "aws_iam_user" "dns" {
  name                 = "zeroroot-ai-${var.environment}-dns"
  path                 = "/substrate/"
  permissions_boundary = local.identity_permissions_boundary_arn
}

resource "aws_iam_access_key" "dns" {
  for_each = var.key_slots["dns"].keep

  user = aws_iam_user.dns.name
}

moved {
  from = aws_iam_access_key.dns
  to   = aws_iam_access_key.dns["a"]
}

data "aws_iam_policy_document" "dns" {
  statement {
    sid    = "ZoneRecords"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:GetHostedZone",
    ]
    resources = ["arn:aws:route53:::hostedzone/${local.zone_id}"]
  }

  statement {
    sid    = "FindTheZone"
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListTagsForResource",
      "route53:GetChange",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "dns" {
  name   = "zone-records"
  user   = aws_iam_user.dns.name
  policy = data.aws_iam_policy_document.dns.json
}
