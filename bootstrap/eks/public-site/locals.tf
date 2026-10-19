locals {
  # The four org-required tags, matching every other root in this repo.
  # `Environment = public` is deliberate and is NOT one of staging, drill or prod:
  # this workspace has no Environment (ADR-0077). The public surfaces
  # are production-only singletons; there is no staging MARKETING site.
  #
  # The documentation is the exception, decided 2026-09-22 (ADR-0095).
  # Staging must be able to read a docs build that is not released yet, which
  # the one live site cannot show it. That is a second surface in this SAME
  # singleton workspace, not an environment fork: there is still no envs/
  # directory here and there never should be.
  common_tags = {
    Environment = "public"
    Project     = "zeroroot-ai"
    Owner       = "platform"
    ManagedBy   = "terraform"
  }

  docs_domain = "docs.${var.apex_domain}"
  www_domain  = "www.${var.apex_domain}"

  # Every hostname the one public certificate must cover. The apex is included
  # because the www distribution carries it as an alias and 301s it to www.
  # The staging documentation host. It lives inside the delegated sub-zone
  # staging's stage 0 created, which is why its validation record cannot go in
  # the apex: a record there would not be authoritative.
  staging_docs_domain = "docs.staging.${var.apex_domain}"
  cert_sans           = [local.www_domain, var.apex_domain, local.staging_docs_domain]

  # Every domain the certificate requests. Used as STATIC for_each keys on the
  # validation records — see the comment there.
  cert_domains = concat([local.docs_domain], local.cert_sans)
  # Which zone proves each name. Every apex name validates in the apex zone;
  # the staging documentation name validates in the delegated sub-zone.
  cert_zone_id = merge(
    { for d in [local.docs_domain, local.www_domain, var.apex_domain] : d => data.aws_route53_zone.apex.zone_id },
    { (local.staging_docs_domain) = data.aws_route53_zone.staging.zone_id },
  )
}
