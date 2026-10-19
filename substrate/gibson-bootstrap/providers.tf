# The operator authenticates as a session inside the environment's account
# (AWS_PROFILE=zeroroot-prod on a workstation). The precondition on the
# durable bucket refuses a session in any other account.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
