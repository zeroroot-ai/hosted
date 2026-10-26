# ----------------------------------------------------------------------------
# Stage 1 for a plain-cluster environment (ADR-0083, hosted#159).
#
# This root builds ONE EC2 instance running k3s. It is the whole cluster.
# There is no managed control plane, no node group, no autoscaler and no load
# balancer: the instance's Elastic IP is the edge address, and Envoy takes the
# packet on the host port with the client address intact (ADR-0079).
#
# It provisions infrastructure only. Argo CD and the platform arrive in stage
# 2, the same way they do on every other substrate.
# ----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    # The agent token of a second node (hosted#453).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
