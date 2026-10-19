# The backend is configured per environment at init time, the same way
# bootstrap/ec2/gibson does it: the bucket name carries the account id, so it
# is supplied by -backend-config rather than committed here.
#
# THE KEY IS tfstate/targets/kubernetes-goat/terraform.tfstate
# (scripts/lib/targets.sh, targets_state_key), and it is never
# tfstate/ec2-gibson/. The two roots share the environment's durable bucket
# and nothing else. A shared key would let a goat apply destroy the platform.
terraform {
  backend "s3" {
    region  = "us-east-1"
    encrypt = true
  }
}
