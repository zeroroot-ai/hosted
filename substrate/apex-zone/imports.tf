# ----------------------------------------------------------------------------
# Imports. The zone and every mail record existed before this workspace did,
# so the import is code, not a one-time command. The blocks stay after the
# first apply: on a state that already holds the resource they are no-ops,
# and on a lost state they re-import instead of creating a second zone.
#
# Route53 record import id: <zone id>_<record name>_<type>.
# SESv2 identity import id: the identity name, in the provider's region.
# ----------------------------------------------------------------------------

import {
  to = aws_route53_zone.apex
  id = var.apex_zone_id
}

import {
  to = aws_route53_record.mx
  id = "${var.apex_zone_id}_${var.apex_domain}_MX"
}

import {
  to = aws_route53_record.spf
  id = "${var.apex_zone_id}_${var.apex_domain}_TXT"
}

import {
  to = aws_route53_record.google_dkim
  id = "${var.apex_zone_id}_${local.google_dkim_selector}._domainkey.${var.apex_domain}_TXT"
}

import {
  to = aws_sesv2_email_identity.virginia
  id = var.apex_domain
}

import {
  provider = aws.ohio
  to       = aws_sesv2_email_identity.ohio
  id       = var.apex_domain
}

import {
  for_each = local.ses_dkim_tokens.virginia
  to       = aws_route53_record.ses_dkim_virginia[each.key]
  id       = "${var.apex_zone_id}_${each.key}._domainkey.${var.apex_domain}_CNAME"
}

import {
  for_each = local.ses_dkim_tokens.ohio
  to       = aws_route53_record.ses_dkim_ohio[each.key]
  id       = "${var.apex_zone_id}_${each.key}._domainkey.${var.apex_domain}_CNAME"
}
