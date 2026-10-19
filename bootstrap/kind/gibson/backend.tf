# ----------------------------------------------------------------------------
# Local backend for kind dev. State lives on-disk so the operator releases
# survive cluster recreations without a re-download. No credential lives in
# this state (deploy#1732).
#
# To share state across a team or migrate to S3:
#   terraform {
#     backend "s3" {
#       bucket = "zeroroot-ai-terraform-state"
#       key    = "kind/gibson/terraform.tfstate"
#       region = "us-east-1"
#     }
#   }
# ----------------------------------------------------------------------------

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
