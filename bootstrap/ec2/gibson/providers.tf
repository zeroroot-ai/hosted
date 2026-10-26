provider "aws" {
  region = var.aws_region

  # The four cost tags of this estate (no SCP enforces them), plus the two
  # operational ones. Same set as bootstrap/eks/gibson.
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

# ----------------------------------------------------------------------------
# The Kubernetes providers, for phase 2.
#
# They read the kubeconfig the recreate fetched from the instance. During
# phase 1 the path is empty and no Kubernetes resource is in the plan, so
# nothing connects.
# ----------------------------------------------------------------------------

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes = {
    config_path = var.kubeconfig_path
  }
}

provider "kubectl" {
  config_path      = var.kubeconfig_path
  load_config_file = true
}
