# ----------------------------------------------------------------------------
# Remote state backend — partial configuration.
#
# Bootstrap dance (one-time, per `aws-org/README.md` for full detail):
#
#   1. First apply uses a local backend. Comment out the `backend "s3"`
#      block below and `terraform init` against the local working
#      directory. Run `terraform apply` to provision (among other things)
#      the state bucket + lock table at:
#        - bucket: zeroroot-ai-mgmt-tfstate-<account-id>-us-east-1
#        - lock table: zeroroot-ai-mgmt-tf-locks
#        - kms key: alias/zeroroot-ai-mgmt-tf-state
#      via state-bucket.tf in this workspace.
#
#   2. Uncomment the backend "s3" block below.
#
#   3. Run:
#        terraform init -migrate-state \
#          -backend-config="bucket=zeroroot-ai-mgmt-tfstate-<account-id>-us-east-1" \
#          -backend-config="dynamodb_table=zeroroot-ai-mgmt-tf-locks" \
#          -backend-config="kms_key_id=alias/zeroroot-ai-mgmt-tf-state"
#      Confirm the migration prompt with `yes`.
#
#   4. Delete the local terraform.tfstate file. Confirm `terraform plan`
#      reports no diff.
#
# After step 4 the workspace operates against the s3 backend and never
# rolls back to local.
# ----------------------------------------------------------------------------

terraform {
  backend "s3" {
    key     = "aws-org/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
