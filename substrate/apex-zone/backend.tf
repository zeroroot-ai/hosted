# ----------------------------------------------------------------------------
# State.
#
# Partial config. The bucket, lock table and KMS key come from
# eks/gibson-bootstrap (envs/prod) and carry prevent_destroy, so the state of
# this workspace outlives every cluster, which is the property the apex zone
# needs. Same shape as eks/public-site.
#
#   terraform -chdir=eks/apex-zone init \
#     -backend-config="bucket=zeroroot-ai-prod-tfstate-<account-id>-us-east-1" \
#     -backend-config="dynamodb_table=zeroroot-ai-prod-tf-locks" \
#     -backend-config="kms_key_id=alias/zeroroot-ai-prod-tf-bootstrap"
#
# The key is not env-prefixed. There is one apex zone and one state for it,
# whichever bucket holds the object.
# ----------------------------------------------------------------------------

terraform {
  backend "s3" {
    key     = "apex-zone/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
