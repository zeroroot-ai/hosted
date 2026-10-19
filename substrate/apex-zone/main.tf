# ----------------------------------------------------------------------------
# eks/apex-zone: the zeroroot.ai apex zone and its mail records.
#
# In plain words: the company's domain and the records that make its mail
# work. They belong to the company, not to any environment, so no teardown may
# touch them (ADR-0083, CONTEXT.md "Apex zone").
#
# THIS WORKSPACE IS PERMANENT. It has no destroy target, no teardown mode and
# no environment. The zone was imported, never created here, and it carries
# the one prevent_destroy this repo keeps on purpose. See README.md for why
# that is not the retain machinery ADR-0083 deletes.
#
# What an environment may write into this zone: application records through
# external-dns under its ownership TXT, and the ACM validation CNAMEs for its
# own certificate. Nothing else. The delegation NS record for a sub-zone
# (staging.zeroroot.ai) is written by the environment that owns the sub-zone.
# ----------------------------------------------------------------------------

resource "aws_route53_zone" "apex" {
  name = var.apex_domain

  # The comment and the tags are the live values, verbatim. They still name the
  # prod workspace that created the zone on 2026-06-04. Changing them is a
  # change to the live zone, and this workspace was imported with an empty
  # plan, so they stay until an owner decides otherwise.
  comment = "Public zone for zeroroot.ai. Namecheap NS records repointed at this zone during prod cutover (see RUNBOOK-cutover.md phase 3)."

  tags = {
    Name        = var.apex_domain
    Project     = "zeroroot-ai"
    Owner       = "platform"
    ManagedBy   = "terraform"
    CostCenter  = "platform-prod"
    Environment = "prod"
    Workspace   = "zeroroot-ai-prod"
  }

  lifecycle {
    # The one prevent_destroy this repo keeps. This workspace is meant to be
    # permanent, so the guard and the intent agree. Everywhere else,
    # prevent_destroy was a retain flag on an ephemeral estate, and ADR-0083
    # deletes it.
    prevent_destroy = true
  }
}
