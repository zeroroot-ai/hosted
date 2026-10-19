# ----------------------------------------------------------------------------
# Mail records. Every value below is the live value on the zone as of
# 2026-09-01. A change here is a change to company mail: make it on purpose,
# with the owner, never as a side effect of another slice.
# ----------------------------------------------------------------------------

locals {
  # Google Workspace inbound mail. The apex mailbox is also the AWS
  # member-account root email, so losing this record loses AWS verification
  # and root-password-reset mail.
  mx_records = ["1 smtp.google.com."]

  # One SPF record per domain. It authorizes Google Workspace and Amazon SES.
  spf_record = "v=spf1 include:_spf.google.com include:amazonses.com ~all"

  # Google Workspace DKIM public key, selector `google`. Public by design.
  # Generated in Google Admin -> Apps -> Google Workspace -> Gmail ->
  # Authenticate email. It cannot be derived from infrastructure.
  google_dkim_selector = "google"
  google_dkim_key      = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2TbjD3ZAJHBb1AAePG++f7EJrbqwAaApgoz9YqFev7QTQ0Jwww481RtT1JVBOKqc37pElNaactPbcTdk1KLUOdd7Z/UVSfe/oBtv8m/2BOxEqi3s7sQYYQQA2lMhG4gxCKnuaAVJUNm//rvtVUPgWuxhmVxrXieJZz5Puzea7SbiCrPVmcO6qCbqIlEgM6KrvCHiQf03MTQoJ4R165FkuR771ikjsoi28itjO5bsrE68xNxcPTq+mIYTY9Yzcg1Z/jngs/oqtjWwcHPCDO3XwgymsEmvxW8PthnmVXikGpBybNeR4Sjo5kP1ktmsyn9rjTgM6vcjZ+11ws+dceMdzwIDAQAB"
}

resource "aws_route53_record" "mx" {
  zone_id = aws_route53_zone.apex.zone_id
  name    = var.apex_domain
  type    = "MX"
  ttl     = 3600
  records = local.mx_records
}

resource "aws_route53_record" "spf" {
  zone_id = aws_route53_zone.apex.zone_id
  name    = var.apex_domain
  type    = "TXT"
  ttl     = 3600
  records = [local.spf_record]
}

# Route53 caps one TXT string at 255 characters. A longer key is split into
# quoted chunks, which is what the `""` join produces.
resource "aws_route53_record" "google_dkim" {
  zone_id = aws_route53_zone.apex.zone_id
  name    = "${local.google_dkim_selector}._domainkey.${var.apex_domain}"
  type    = "TXT"
  ttl     = 3600
  records = [join("\"\"", regexall(".{1,255}", local.google_dkim_key))]
}

# ----------------------------------------------------------------------------
# SES domain identities. Two regions, both live, both verified, both signing
# (see providers.tf). Each identity has three Easy DKIM tokens, and each token
# is one CNAME in the apex zone. The CNAMEs are derived from the identity, so
# a key rotation on the SES side shows up as a plan here, not as silent drift.
#
# Not declared, because it does not exist live: a MAIL FROM domain
# (mail.zeroroot.ai) and a _dmarc record. Both are deliverability records the
# relay owner should publish. Adding them is a change to live mail and is an
# owner decision, tracked separately from this import.
# ----------------------------------------------------------------------------

resource "aws_sesv2_email_identity" "virginia" {
  email_identity = var.apex_domain
}

resource "aws_sesv2_email_identity" "ohio" {
  provider       = aws.ohio
  email_identity = var.apex_domain
}

locals {
  ses_dkim_tokens = {
    virginia = toset(aws_sesv2_email_identity.virginia.dkim_signing_attributes[0].tokens)
    ohio     = toset(aws_sesv2_email_identity.ohio.dkim_signing_attributes[0].tokens)
  }
}

resource "aws_route53_record" "ses_dkim_virginia" {
  for_each = local.ses_dkim_tokens.virginia

  zone_id = aws_route53_zone.apex.zone_id
  name    = "${each.key}._domainkey.${var.apex_domain}"
  type    = "CNAME"
  ttl     = 300
  records = ["${each.key}.dkim.amazonses.com"]
}

resource "aws_route53_record" "ses_dkim_ohio" {
  for_each = local.ses_dkim_tokens.ohio

  zone_id = aws_route53_zone.apex.zone_id
  name    = "${each.key}._domainkey.${var.apex_domain}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${each.key}.dkim.amazonses.com"]
}
