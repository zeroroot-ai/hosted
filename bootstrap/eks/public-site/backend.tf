# ----------------------------------------------------------------------------
# State.
#
# Partial config: the bucket and lock table are created by eks/gibson-bootstrap
# and carry prevent_destroy, so they survive every estate teardown — which is
# exactly the property this workspace needs, since the surfaces it provisions
# must outlive the cluster.
#
#   terraform -chdir=eks/public-site init \
#     -backend-config="bucket=zeroroot-ai-<env>-tfstate-<account-id>-us-east-1" \
#     -backend-config="dynamodb_table=zeroroot-ai-<env>-tf-locks" \
#     -backend-config="kms_key_id=alias/zeroroot-ai-<env>-tf-bootstrap"
#
# The key is deliberately NOT env-prefixed: there is one public-site state,
# ever, no matter which env's bucket holds the object.
# ----------------------------------------------------------------------------

terraform {
  backend "s3" {
    key     = "public-site/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
