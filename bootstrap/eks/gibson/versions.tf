# ----------------------------------------------------------------------------
# Terraform + provider version constraints for the Gibson EKS root — ONE file
# for both envs (deploy#1397). Backend and provider configurations live in
# backend.tf and providers.tf.
#
# Two forked versions.tf files is precisely the drift that produced two
# separate aws-provider-v6 migration PRs (deploy#1426 + deploy#1428).
# ----------------------------------------------------------------------------

terraform {
  # >= 1.11: the s3 backend locks with use_lockfile (S3 native locking), which
  # is general availability from 1.11. CI pins the same version everywhere.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
