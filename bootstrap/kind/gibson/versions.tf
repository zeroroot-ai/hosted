# ----------------------------------------------------------------------------
# Terraform + provider version constraints for the kind/gibson workspace.
# Backend and provider configurations live in backend.tf and providers.tf.
# ----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.9"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
  }
}
