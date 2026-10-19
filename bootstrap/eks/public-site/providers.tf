# ----------------------------------------------------------------------------
# Providers.
#
# CloudFront and ACM-for-CloudFront are global services that live in us-east-1,
# which is also this org's pinned region (SCP R0.3,
# eks/aws-org/policies/deny-regions-except-us-east-1.json). That SCP's
# allow-list already names cloudfront as a global service — do not remove that
# entry, or this workspace's own apply is denied by our own guardrail.
#
# Only one provider block is needed because the pinned region and CloudFront's
# required region are the same. If the org ever un-pins, this root needs an
# explicit us-east-1 alias for the certificate.
# ----------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
