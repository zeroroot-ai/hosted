# ----------------------------------------------------------------------------
# eks/gibson-bootstrap: stage 0, the substrate bootstrap, for an AWS
# environment (ADR-0083, docs/bringup.md, deploy#1742).
#
# One directory, every AWS environment. The env axis is envs/<env>.tfvars and
# the local state path, both chosen by substrate.sh from one ENV.
#
# Terraform >= 1.11: the eks/gibson backend this workspace serves uses S3
# native locking (use_lockfile), which is general availability from 1.11.
# CI pins the same version for fmt, validate and the exit test.
# ----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
  }
}
