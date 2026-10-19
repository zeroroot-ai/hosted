# ----------------------------------------------------------------------------
# Provider configurations.
#
# The AWS provider is always active. The kubernetes/helm/kubectl providers
# depend on the cluster module's outputs.
#
# On a cold apply, break the provider chicken-and-egg with
# `terraform apply -target=module.network`, then `-target=module.cluster`,
# before a full apply. The recreate verb (deploy#1746) owns this ordering.
# ----------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Absent-cluster guard (deploy#982 gap 3): a teardown runs against a state
# where the cluster may not exist (from-zero preflight on a clean account, or a
# run that failed before Phase 4). In that case module.cluster's outputs are
# null and the raw references below error with "Attempt to get attribute from
# null value", hard-failing the teardown and leaving billable NAT gateways up.
# Fall back to inert sentinel values: with no cluster there are no
# kubernetes/helm/kubectl resources in state either, so the providers are
# configured but never used to make API calls.
locals {
  k8s_absent_host = "https://cluster-absent.invalid"
  k8s_absent_ca   = base64encode("cluster-absent")

  # try() catches evaluation errors; coalesce() replaces null/empty values.
  k8s_host = try(coalesce(module.cluster.cluster_endpoint, local.k8s_absent_host), local.k8s_absent_host)
  k8s_ca   = try(coalesce(module.cluster.cluster_certificate_authority_data, local.k8s_absent_ca), local.k8s_absent_ca)
  k8s_name = try(coalesce(module.cluster.cluster_name, "cluster-absent"), "cluster-absent")
}

provider "kubernetes" {
  host                   = local.k8s_host
  cluster_ca_certificate = base64decode(local.k8s_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.k8s_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = local.k8s_host
    cluster_ca_certificate = base64decode(local.k8s_ca)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.k8s_name, "--region", var.aws_region]
    }
  }
}

provider "kubectl" {
  host                   = local.k8s_host
  cluster_ca_certificate = base64decode(local.k8s_ca)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.k8s_name, "--region", var.aws_region]
  }
}
