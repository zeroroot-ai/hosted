# ----------------------------------------------------------------------------
# DNS. The apex zone is company property, owned by eks/apex-zone (ADR-0083,
# CONTEXT.md "Apex zone"). Stage 0 reads it as a data source and never
# creates it, imports it or writes a mail record into it.
#
# A sub-zone env (staging) gets its own hosted zone here and one NS record in
# the apex. That record is the one write into the apex an environment makes.
# An apex env (prod) has the apex as its zone and this file creates nothing.
# Only the zone name decides. There is no flag.
#
# The SES identity data source reads the Easy DKIM tokens of the company's
# domain identity in the relay region, so preflight can prove the DKIM CNAMEs
# are still on the apex before stage 1 starts.
# ----------------------------------------------------------------------------

data "aws_route53_zone" "apex" {
  name         = var.apex_zone_name
  private_zone = false
}

data "aws_sesv2_email_identity" "apex" {
  email_identity = var.apex_zone_name
}

resource "aws_route53_zone" "env" {
  count = local.is_subzone ? 1 : 0

  name    = var.zone_name
  comment = "Zone of the ${var.environment} environment, delegated from ${var.apex_zone_name}. Stage 0 of ADR-0083."

  tags = {
    Name = var.zone_name
  }
}

resource "aws_route53_record" "delegation" {
  count = local.is_subzone ? 1 : 0

  zone_id = data.aws_route53_zone.apex.zone_id
  name    = var.zone_name
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.env[0].name_servers
}

locals {
  zone_id           = local.is_subzone ? aws_route53_zone.env[0].zone_id : data.aws_route53_zone.apex.zone_id
  zone_name_servers = local.is_subzone ? aws_route53_zone.env[0].name_servers : data.aws_route53_zone.apex.name_servers
}
