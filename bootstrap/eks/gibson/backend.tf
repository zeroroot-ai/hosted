# ----------------------------------------------------------------------------
# Remote state: the env's durable bucket, prefix tfstate/ (ADR-0083).
#
# Stage 0 (eks/gibson-bootstrap, `make substrate ENV=<env>`) creates the
# bucket in the environment's own account, with versioning, SSE-S3 and a
# lifecycle rule that never expires a current state version. Locking is S3
# native (use_lockfile, Terraform >= 1.11), so there is no DynamoDB table,
# and encryption is SSE-S3, so there is no KMS key.
#
# This is a PARTIAL backend configuration. The bucket is env-specific and the
# key is the same in every env, so `make eks-init ENV=<env>` supplies both
# from ENV plus the live account id:
#
#   terraform -chdir=eks/gibson init -reconfigure \
#     -backend-config="key=tfstate/eks-gibson/terraform.tfstate" \
#     -backend-config="bucket=zeroroot-ai-<env>-durable-<account-id>" \
#     -backend-config="use_lockfile=true"
#
# ALWAYS init through `make eks-init`. A bare `terraform init` in this
# directory has no bucket and refuses to initialize, which is the intended
# failure: an env-less init is how staging config lands on prod state.
#
# History: until deploy#1742 the state lived in a per-env
# zeroroot-ai-<env>-tfstate bucket with a DynamoDB lock table and a KMS key.
# Staging's was deleted with the staging estate on 2026-09-01. Prod's still
# holds the eks/apex-zone and eks/public-site state and moves with prod's
# stage 0.
# ----------------------------------------------------------------------------

terraform {
  backend "s3" {
    region  = "us-east-1"
    encrypt = true
  }
}
