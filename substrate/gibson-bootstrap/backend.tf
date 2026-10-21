# ----------------------------------------------------------------------------
# State of stage 0 itself: the durable bucket it creates (ADR-0083, amendment
# of 2026-10-21).
#
#   bucket   zeroroot-ai-<env>-durable-<account>
#   key      tfstate/stage0/terraform.tfstate, with S3 native lock files
#
# The bucket name carries the account id, so scripts/stage0-store.sh
# (stage0_init) passes it with -backend-config. The first apply of a new
# environment has no bucket yet: it uses a local state file, and substrate.sh
# runs `terraform init -migrate-state` once the apply made the bucket. The
# state holds the access keys of the stage 0 users, so the bucket policy lets
# only the rotation role and the operator role read this prefix (bucket.tf).
# ----------------------------------------------------------------------------

terraform {
  backend "s3" {
    region  = "us-east-1"
    encrypt = true
  }
}
