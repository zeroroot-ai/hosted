provider "aws" {
  region = var.aws_region

  # The four cost tags of this estate (no SCP enforces them), plus the two
  # operational ones. Same set as bootstrap/ec2/gibson.
  default_tags {
    tags = {
      Environment = var.environment
      Project     = "zeroroot-ai"
      Owner       = "platform"
      CostCenter  = var.cost_center
      ManagedBy   = "terraform"
      Workspace   = var.workspace_name
    }
  }
}
