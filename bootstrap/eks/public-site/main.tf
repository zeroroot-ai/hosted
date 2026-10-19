# ----------------------------------------------------------------------------
# eks/public-site — the public web surfaces, off-cluster.
#
# See ADR-0077.
#
# In plain words: the marketing site and the public documentation are files.
# They do not need a server, they do not need a cluster, and they must stay up
# when the estate is torn down. This workspace serves them from S3 behind
# CloudFront, so `www.zeroroot.ai` and `docs.zeroroot.ai` are reachable whether
# or not an EKS cluster exists.
#
# THIS ROOT IS NOT ENVIRONMENT-FORKED. Every other root here is (staging/prod),
# and `Environment` in this repo means staging, drill or prod. The public surfaces
# are production-only singletons — there is no staging marketing site, and
# inventing one doubles the CloudFront, ACM and DNS surface for no reader.
# Do not add an `envs/` directory to this workspace.
#
# DELIBERATELY NOT IN eks/gibson. That root is full-ephemeral (ADR-0083):
# a teardown deletes everything in it. Putting the marketing site there
# would destroy it on every teardown — the exact failure this workspace exists
# to prevent.
#
# NOT A REVERSAL OF THE CLOUDFRONT VOID. That decision concerns the
# customer-traffic edge — a distribution in front of Envoy, terminating API
# traffic, needing shared-secret origin verification. It was deleted in #1606
# and #1608 and stays deleted. This is object-storage delivery, which shares a
# product name with it and nothing else.
# ----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

# The delegated sub-zone staging's stage 0 created. This root never creates or
# owns it; it reads it, the same way it reads the apex.
data "aws_route53_zone" "staging" {
  name         = "staging.${var.apex_domain}."
  private_zone = false
}

# The apex zone already exists and is delegated from the registrar. It survived
# the 2026-08-16 teardown. Data source only — never created or owned here.
data "aws_route53_zone" "apex" {
  name         = var.apex_domain
  private_zone = false
}

# ----------------------------------------------------------------------------
# Certificate.
#
# One certificate covering every public surface, issued in us-east-1 because
# CloudFront reads certificates from that region only.
#
# Deliberately NOT the wildcard cert from eks/gibson's route53 module: that one
# belongs to the cluster workspace and is destroyed with it. A surface that must
# outlive the estate cannot hold a certificate that does not.
# ----------------------------------------------------------------------------

resource "aws_acm_certificate" "public" {
  domain_name               = local.docs_domain
  subject_alternative_names = local.cert_sans
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Static for_each keys = the exact domain set the cert requests. Keying off
# `domain_validation_options` instead makes the KEYS an apply-time value, and
# Terraform refuses to plan a map whose keys it cannot know — which is what
# adding the www and apex SANs to an existing cert triggers. Record
# name/value/type are still resolved from the cert at apply time.
#
# Same shape as eks/gibson/modules/route53, for the same reason.
resource "aws_route53_record" "cert_validation" {
  for_each = toset(local.cert_domains)

  # Not always the apex. The staging documentation name lives in the delegated
  # sub-zone, and a validation record for it in the apex proves nothing.
  zone_id = local.cert_zone_id[each.value]
  name = one([
    for dvo in aws_acm_certificate.public.domain_validation_options :
    dvo.resource_record_name if dvo.domain_name == each.value
  ])
  type = one([
    for dvo in aws_acm_certificate.public.domain_validation_options :
    dvo.resource_record_type if dvo.domain_name == each.value
  ])
  records = [one([
    for dvo in aws_acm_certificate.public.domain_validation_options :
    dvo.resource_record_value if dvo.domain_name == each.value
  ])]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "public" {
  certificate_arn         = aws_acm_certificate.public.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ----------------------------------------------------------------------------
# docs.zeroroot.ai — the public consumer of the docs deployable.
#
# The container image remains the deployable for self-hosted and air-gapped
# installs, digest-pinned in the umbrella chart. Both are published from the
# same release tag, so this is one artifact with two consumers, not a parallel
# codepath (ADR-0077, ADR-0027).
# ----------------------------------------------------------------------------

# The CSP of the documentation. It equals the add_header line of the docs-site
# nginx.conf, so the container and the edge serve one policy. The static
# export inlines its scripts and styles, which is why 'unsafe-inline' stays.
# scripts/check-public-site-csp.py fails when this value is empty or allows
# framing or plugins.
locals {
  docs_content_security_policy = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
}

module "docs" {
  source = "./modules/static-site"

  name                    = "docs"
  domain_name             = local.docs_domain
  bucket_name             = "zeroroot-ai-docs-site-${data.aws_caller_identity.current.account_id}"
  acm_certificate_arn     = aws_acm_certificate_validation.public.certificate_arn
  route53_zone_id         = data.aws_route53_zone.apex.zone_id
  content_security_policy = local.docs_content_security_policy
}

# ----------------------------------------------------------------------------
# docs.staging.zeroroot.ai — the documentation staging reads.
#
# Staging must be able to read a docs build that is not released yet. The one
# live site cannot show it, and serving the documentation from the staging
# cluster would put a chart back in front of a surface ADR-0077 took out of
# every chart. So it is a second small surface here: its own bucket, its own
# distribution, the same module, about a dollar a month.
#
# THIS MODULE STAYS IN THIS ROOT BY DECISION (owner decision of 2026-10-05,
# ADR-0077, hosted#429). This root has no Environment, and this module is the
# one part of it that reads an environment: the delegated staging sub-zone.
# Do not move it to a staging root.
#
# So the staging stage 0 must run first (`make substrate ENV=staging`). A plan
# before that fails on the zone lookup, which is the truth said plainly.
# ----------------------------------------------------------------------------
module "docs_staging" {
  source = "./modules/static-site"

  name                    = "docs-staging"
  domain_name             = local.staging_docs_domain
  bucket_name             = "zeroroot-ai-docs-staging-site-${data.aws_caller_identity.current.account_id}"
  acm_certificate_arn     = aws_acm_certificate_validation.public.certificate_arn
  route53_zone_id         = data.aws_route53_zone.staging.zone_id
  content_security_policy = local.docs_content_security_policy
}

# ----------------------------------------------------------------------------
# www.zeroroot.ai — the marketing site, plus the apex.
#
# One distribution carries both hostnames. The edge function 301s the apex to
# www, so the apex needs no second distribution, no second certificate and no
# redirect bucket. A redirect bucket would need S3 website hosting, which
# speaks only HTTP and forces the bucket public.
#
# This surface is deployed by no chart in either audience — it is an
# off-cluster surface (ADR-0077). helm/saas-overlay/www-svc and the www Envoy
# virtual host are deleted, not disabled.
# ----------------------------------------------------------------------------

module "www" {
  source = "./modules/static-site"

  name                = "www"
  domain_name         = local.www_domain
  redirect_hosts      = [var.apex_domain]
  bucket_name         = "zeroroot-ai-www-site-${data.aws_caller_identity.current.account_id}"
  acm_certificate_arn = aws_acm_certificate_validation.public.certificate_arn
  route53_zone_id     = data.aws_route53_zone.apex.zone_id

  # Makes /api/contact-sales same-origin with the form. See modules/lead-path.
  api_origin_enabled = true
  api_origin_host    = module.lead_path.api_origin_host
}

# ----------------------------------------------------------------------------
# The contact-sales endpoint.
#
# Attached to the www distribution above as a second origin, which is what
# makes the request same-origin and lets the dashboard route's CORS apparatus
# be deleted rather than ported.
#
# The dependency runs both ways — the distribution needs the function's host,
# and the function's invoke permission needs the distribution's ARN — so the
# permission is granted from the module using a value Terraform resolves after
# the distribution exists. That is a normal two-phase create, not a cycle.
# ----------------------------------------------------------------------------

module "lead_path" {
  source = "./modules/lead-path"

  name        = "www"
  sales_inbox = var.sales_inbox
}
