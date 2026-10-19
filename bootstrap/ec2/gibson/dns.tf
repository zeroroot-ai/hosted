# ----------------------------------------------------------------------------
# DNS. Stage 0 created the delegated zone and put the NS record in the apex,
# so this root only writes records inside it (ADR-0083, the apex belongs to
# substrate/apex-zone and never to an environment).
#
# One wildcard covers every host the platform serves: app, api, auth, argocd
# and anything a later slice adds. A host that must NOT come from this cluster
# gets its own record, and a specific record always wins over the wildcard.
# That is how docs.<zone> reaches its own off-cluster site (ADR-0077).
# ----------------------------------------------------------------------------

data "aws_route53_zone" "env" {
  name         = "${var.route53_zone_name}."
  private_zone = false
}

resource "aws_route53_record" "wildcard" {
  zone_id = data.aws_route53_zone.env.zone_id
  name    = "*.${var.route53_zone_name}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.node.public_ip]
}

resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.env.zone_id
  name    = var.route53_zone_name
  type    = "A"
  ttl     = 60
  records = [aws_eip.node.public_ip]
}
