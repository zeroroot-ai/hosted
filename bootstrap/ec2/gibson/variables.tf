# ----------------------------------------------------------------------------
# Every variable an environment must name. None of them has a default that
# picks an environment: a stage 1 that guesses which estate it builds is how
# the wrong one gets touched (ADR-0083).
# ----------------------------------------------------------------------------

variable "environment" {
  description = "The environment this root builds. Supplied by envs/<env>.tfvars."
  type        = string
}

variable "workspace_name" {
  description = "The Terraform workspace name, recorded as a tag."
  type        = string
}

variable "cluster_name" {
  description = "The cluster's name. Names the instance, the VPC and the security group."
  type        = string
}

variable "cost_center" {
  description = "The CostCenter tag the SCP requires."
  type        = string
}

variable "aws_region" {
  description = "The region this environment runs in."
  type        = string
  default     = "us-east-1"
}

variable "route53_zone_name" {
  description = "The delegated zone stage 0 created, for example staging.zeroroot.ai. Every host of this environment is a record in it."
  type        = string
}

variable "vpc_cidr" {
  description = "The VPC range. One public subnet is carved from it."
  type        = string
  default     = "10.60.0.0/16"
}

variable "instance_type" {
  description = "The instance the whole cluster runs on. The default is 8 vCPU and 32 GB, which is the measured floor for the full stack plus sandboxes. It is an m8i type, so the node exposes /dev/kvm to the Firecracker sandboxes (hosted#446). scripts/check-fleet-instance-types.py fails on a type with no nested virtualization."
  type        = string
  default     = "m8i.2xlarge"
}

variable "node_count" {
  description = "How many instances form the cluster: 1 or 2 (hosted#453). The first is the k3s server. A second one of the same type joins it as a k3s agent, carries the same labels and the same ceiling, and gives a proof that needs two nodes a cluster. The default is 1. Only the drill environment accepts 2 (scripts/check-node-count.sh)."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2], var.node_count)
    error_message = "node_count must be 1 or 2."
  }
}

variable "root_volume_gb" {
  description = "The instance volume. It holds the container images, every local-path volume and the Velero staging area, so it is the cluster's disk."
  type        = number
  default     = 200
}

# THE ONLY GUARANTEE THAT SURVIVES A DEAD RUNNER.
#
# A throwaway environment is torn down by its workflow, and a workflow can die
# in ways that skip its own teardown: a cancelled job, a runner that vanishes, a
# terraform destroy that fails on one resource. Every one of those leaves an
# instance billing with nobody watching.
#
# When this is non-zero the instance arms `shutdown -h +<minutes>` on EVERY boot
# from its own cloud-init, and its shutdown behaviour is `terminate`. It then
# dies on its own clock, needing no network, no GitHub, no terraform state and
# no credential. That is what makes "it always gets torn down" a property of the
# instance rather than a hope about the pipeline.
#
# ZERO FOR A PERMANENT ENVIRONMENT. staging must never carry this (ADR-0095),
# which `tests/harness/drill-teardown.bats` asserts against the tfvars, because
# a staging node that terminates itself after an afternoon is the whole estate
# gone.
variable "self_terminate_after_minutes" {
  description = "Arm an instance-initiated termination this many minutes after every boot. 0 disables it, which is what a permanent environment wants."
  type        = number
  default     = 0

  validation {
    condition     = var.self_terminate_after_minutes >= 0 && var.self_terminate_after_minutes <= 1440
    error_message = "self_terminate_after_minutes must be between 0 and 1440. A ceiling above a day is not a ceiling."
  }
}

variable "k3s_version" {
  description = "The k3s release channel or exact version. An exact version is pinned per environment so an unattended rebuild cannot change the Kubernetes version. Kubernetes 1.35 or later: each setec launcher Pod mounts its sandbox disk as an image volume (D85), which 1.35 turns on by default (hosted#577)."
  type        = string
  default     = "v1.35.9+k3s1"
}

variable "api_allow_cidrs" {
  description = "The addresses allowed to reach the Kubernetes API on port 6443. Empty means nobody: the operator reaches the API through SSM, never over the internet."
  type        = list(string)
  default     = []
}

# ----------------------------------------------------------------------------
# Phase 2: Argo CD.
#
# The Kubernetes providers cannot plan until the cluster answers, and the
# cluster does not exist until phase 1 applies. So the recreate verb applies
# phase 1 with a target, fetches the kubeconfig from the instance over SSM,
# and applies phase 2 with the path below set. bootstrap/eks/gibson breaks
# the same ordering the same way, for the same reason.
# ----------------------------------------------------------------------------

variable "kubeconfig_path" {
  description = "The kubeconfig the recreate fetched from the instance. Empty during phase 1, when no Kubernetes resource is in the plan."
  type        = string
  default     = ""
}

variable "git_repo_url" {
  description = "The repository Argo CD watches. It carries the Argo tree under gitops/ (ADR-0086)."
  type        = string
  default     = "https://github.com/zeroroot-ai/hosted"
}

variable "git_revision" {
  description = "The ref Argo CD tracks."
  type        = string
  default     = "main"
}

variable "app_of_apps_path" {
  description = "The gitops overlay this cluster reconciles, for example gitops/envs/staging."
  type        = string
}

variable "bootstrap_app_of_apps" {
  description = "Whether the app-of-apps is created. A restore holds it back until the secret store is home, then applies again with it true (ADR-0083)."
  type        = bool
  default     = true
}

variable "argocd_extra_managed_api_groups" {
  description = "API groups this cluster's Argo controller may manage beyond the platform baseline."
  type        = list(string)
  default     = []
}

variable "argocd_extra_platform_namespaces" {
  description = "Namespaces the default AppProject may target beyond the baseline."
  type        = list(string)
  default     = []
}

variable "argocd_extra_platform_source_repos" {
  description = "Source repos the default AppProject may pull from beyond the first-party ones."
  type        = list(string)
  default     = []
}

variable "argocd_extra_cluster_resources" {
  description = "Cluster-scoped kinds the default AppProject may apply beyond the baseline."
  type = list(object({
    group = string
    kind  = string
  }))
  default = []
}

variable "service_cidr" {
  description = "The Kubernetes Service range. The NetworkPolicies allow its first address, the apiserver ClusterIP (scripts/check-apiserver-cidrs.py reads this value)."
  type        = string
  default     = "172.20.0.0/16"
}
