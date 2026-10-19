# ----------------------------------------------------------------------------
# Required inputs.
#
# This root serves BOTH environments (deploy#1397 — it replaces the two forked
# per-env copies that used to live under eks/). The env axis is
# supplied by `envs/<env>.tfvars`, threaded through by
# `make eks-<target> ENV=<env>`; operator-local and secret values
# (operator_cidrs) stays in the gitignored terraform.tfvars
# / TF_VAR_ env, which envs/<env>.tfvars deliberately does not name.
#
# Every variable that identifies an environment is declared WITHOUT a default.
# A defaulted env identifier is how a staging apply writes prod secrets in the
# shared co-tenant account (ADR-0073): a missing value must be a plan-time
# error, not a silent misconfiguration.
# ----------------------------------------------------------------------------

variable "environment" {
  description = "Which environment this apply targets. Drives the Environment tag (the canonical env indicator across cost reports, alerting and ServiceMonitor labels). Required — supplied by envs/<env>.tfvars."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "environment must be staging or prod."
  }
}

variable "workspace_name" {
  description = "Workspace/account name prefix for every named AWS resource this root creates (the IAM role and policy names, the Karpenter SQS queue). Required — supplied by envs/<env>.tfvars."
  type        = string

  validation {
    condition     = can(regex("^zeroroot-ai-(staging|prod)$", var.workspace_name))
    error_message = "workspace_name must be zeroroot-ai-staging or zeroroot-ai-prod."
  }
}

variable "aws_region" {
  description = "AWS region for the EKS cluster. Pinned to us-east-1 per the DenyRegionsExceptUSEast1 SCP."
  type        = string
  default     = "us-east-1"
}

variable "operator_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint. Default empty = private-only. Populate with operator source IPs or a bastion CIDR. R0.4."
  type        = list(string)
  default     = []
}

variable "route53_zone_name" {
  description = "Public hosted zone this env uses: zeroroot.ai for prod (the apex itself), staging.zeroroot.ai for staging (the sub-zone stage 0, eks/gibson-bootstrap, created and delegated). Read as a data source; this root creates no zone. Required — supplied by envs/<env>.tfvars; a defaulted zone name points the wrong env at the apex."
  type        = string

  validation {
    condition     = var.route53_zone_name == var.apex_zone_name || endswith(var.route53_zone_name, ".${var.apex_zone_name}")
    error_message = "route53_zone_name must be the apex zone itself or a child of it. An environment never owns a second apex."
  }
}

variable "apex_zone_name" {
  description = "The company apex zone (zeroroot.ai). Owned by eks/apex-zone, a permanent workspace with no teardown target (ADR-0083). This root reads it as a data source and never creates it. An env whose route53_zone_name equals it is an apex env; any other env is a sub-zone delegated from it."
  type        = string
  default     = "zeroroot.ai"
}

variable "app_of_apps_path" {
  description = "Path in the Argo tree the ArgoCD root Application reconciles. Per-env overlay dir (ADR-0072): gitops/envs/staging for staging, gitops/envs/prod for prod. Required — supplied by envs/<env>.tfvars; a default here is how a cluster silently reconciles the wrong env's overlay (deploy#1395)."
  type        = string

  validation {
    condition     = can(regex("^gitops/envs/(staging|prod)$", var.app_of_apps_path))
    error_message = "app_of_apps_path must be gitops/envs/staging or gitops/envs/prod — the Argo tree lives under gitops/ in this repo (ADR-0086)."
  }
}

# ----------------------------------------------------------------------------
# Optional — sensible production defaults.
# ----------------------------------------------------------------------------

variable "cluster_name" {
  description = "EKS cluster name. Required — supplied by envs/<env>.tfvars (conventionally the same string as workspace_name)."
  type        = string
}

variable "service_cidr" {
  description = "The Kubernetes Service range of the cluster. The NetworkPolicies allow its first address, the apiserver ClusterIP (scripts/check-apiserver-cidrs.py reads this value). Set on the cluster, never left to the EKS default."
  type        = string
  default     = "172.20.0.0/16"
}

variable "vpc_cidr" {
  description = "CIDR for the production VPC. Must not overlap any other workspace. Default 10.40.0.0/16 dodges typical home-lab and AWS-default starter ranges (R3.1)."
  type        = string
  default     = "10.40.0.0/16"
}

variable "availability_zones" {
  description = "AZs to span. Must be exactly 3 for multi-AZ posture."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Production workspace requires exactly 3 AZs for multi-AZ posture."
  }
}

variable "git_repo_url" {
  description = "Git repository URL that ArgoCD reconciles from. This repo, which carries the Argo tree under gitops/ (ADR-0086). NOT the polyrepo workspace."
  type        = string
  default     = "https://github.com/zeroroot-ai/hosted"
}

variable "git_revision" {
  description = "Git ref ArgoCD tracks (branch, tag, or SHA)."
  type        = string
  default     = "main"
}

# ----------------------------------------------------------------------------
# Tag scheme.
# ----------------------------------------------------------------------------

variable "cost_center" {
  description = "Tag value for the CostCenter tag. Used by Cost Explorer cost categories — a defaulted value bills one env's spend to the other. Required; supplied by envs/<env>.tfvars."
  type        = string
}

# ----------------------------------------------------------------------------
# EKS posture.
# ----------------------------------------------------------------------------

variable "eks_audit_log_retention_days" {
  description = "Retention (days) for the EKS control-plane log group, audit log type included. 2192 days = 6 years per HIPAA Security Rule (R13.3). Bump upward only — never downward."
  type        = number
  default     = 2192

  validation {
    condition     = var.eks_audit_log_retention_days >= 2192
    error_message = "Audit log retention must be at least 6 years (2192 days) per R13.3."
  }
}

# ----------------------------------------------------------------------------
# Node-group sizing.
# ----------------------------------------------------------------------------

variable "system_nodegroup_size" {
  description = "System nodegroup min/desired/max. ARM64 (m6g family) — controllers, ESO, ArgoCD, monitoring, etc."
  type        = object({ min = number, desired = number, max = number })
  default     = { min = 2, desired = 2, max = 3 }
}

variable "workload_nodegroup_size" {
  description = "Workload nodegroup min/desired/max. x86_64 (m6i family) — daemon, dashboard, tenant-operator, ext-authz. Karpenter manages bursts above max."
  type        = object({ min = number, desired = number, max = number })
  default     = { min = 2, desired = 2, max = 6 }
}

variable "system_instance_types" {
  description = "Instance types for the system nodegroup (ARM64 Graviton). Default m6g.large. A cheap dev org may shrink via terraform.tfvars."
  type        = list(string)
  default     = ["m6g.large"]
}

variable "workload_instance_types" {
  description = "Instance types for the workload nodegroup (x86_64). The workload nodes are the sandbox fleet, so each type must expose /dev/kvm: c8i, m8i, r8i or metal (hosted#446). Default m8i.xlarge."
  type        = list(string)
  default     = ["m8i.xlarge"]
}

variable "single_nat_gateway" {
  description = "Route all private subnets through one shared NAT gateway instead of one-per-AZ. Default false (production multi-AZ posture). A cheap dev org sets true to save ~$90/mo."
  type        = bool
  default     = false
}

# argocd_github_pat is retired (ADR-0083): ArgoCD's repo-creds Secret is seeded
# from the org GitHub App by scripts/keyring-to-cluster.sh, and the chart's OCI
# package is public, so no PAT flows through Terraform.

# Pluggable ops SSO (github|gitlab|oidc) via the bundled Dex — a SEPARATE
# identity plane from Zitadel, threaded into module.argocd. Reworks deploy#1332
# (which wired AWS Identity Center SAML); see eks/aws-org/runbooks/RUNBOOK-argocd-sso.md.
variable "argocd_sso_provider" {
  description = "Ops SSO provider routed through the bundled Dex: one of none (default), github, gitlab, oidc. github requires argocd_sso_github_org; gitlab/oidc require argocd_sso_base_url."
  type        = string
  default     = "none"
}

variable "argocd_sso_client_id" {
  description = "OAuth application client ID for the selected SSO provider. Public identifier, not a secret. Unused when argocd_sso_provider=none."
  type        = string
  default     = ""
}

variable "argocd_sso_client_secret" {
  description = "OAuth application client secret for the selected SSO provider (github/gitlab/oidc all issue one; SAML did not). Delivered to Dex via argocd-secret as \"$dex.sso.clientSecret\", never in argocd-cm. Pass via TF_VAR_argocd_sso_client_secret so it never lands in version control; state stores it sensitively."
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_sso_github_org" {
  description = "GitHub org whose membership gates login (Dex github connector orgs). REQUIRED when argocd_sso_provider=github; unused otherwise. e.g. zeroroot-ai."
  type        = string
  default     = "zeroroot-ai"
}

variable "argocd_sso_base_url" {
  description = "GitLab base URL (e.g. https://gitlab.com) when argocd_sso_provider=gitlab, or the OIDC issuer URL when argocd_sso_provider=oidc. REQUIRED for gitlab and oidc; unused for github and none."
  type        = string
  default     = ""
}

variable "argocd_sso_admin_group" {
  description = "Group subject mapped to ArgoCD role:admin. Per-provider format: github -> \"<org>:<team-slug>\" (default \"zeroroot-ai:platform-admins\", since zeroroot ops use GitHub org zeroroot-ai); gitlab -> the group path; oidc -> the raw group claim value."
  type        = string
  default     = "zeroroot-ai:platform-admins"
}

variable "argocd_extra_managed_api_groups" {
  description = "API groups this env's ArgoCD controller may manage BEYOND the platform baseline in bootstrap/modules/argocd/controller-rbac.tf. Appended in order. Staging carries node.k8s.io + setec.zeroroot.ai (setec, deploy#1080/#1415) and actions.github.com (ARC runners)."
  type        = list(string)
  default     = []
}

variable "argocd_extra_platform_namespaces" {
  description = "Namespaces this env's gitops Applications may target BEYOND argocd/gibson/zitadel. Appended in order to the `default` AppProject destinations. Staging carries arc-systems, arc-runners, setec-system (ARC) and setec-sandboxes (setec, deploy#1434)."
  type        = list(string)
  default     = []
}

variable "argocd_extra_platform_source_repos" {
  description = "Source repos this env's Applications may pull from BEYOND the three first-party ones. Appended in order. Staging carries ghcr.io/actions/actions-runner-controller-charts (ARC)."
  type        = list(string)
  default     = []
}

variable "argocd_extra_cluster_resources" {
  description = "Cluster-scoped kinds this env's Applications may apply BEYOND the platform baseline. Appended in order to the `default` AppProject clusterResourceWhitelist. Staging carries node.k8s.io/RuntimeClass + setec.zeroroot.ai/SandboxClass (setec, deploy#1431)."
  type = list(object({
    group = string
    kind  = string
  }))
  default = []
}

# ----------------------------------------------------------------------------
# The app-of-apps Application, which is the whole of stage 2 on this substrate.
#
# TRUE on every ordinary apply, and the recreate verb sets it FALSE for exactly
# one window: a restore (ADR-0083, deploy#1746). A restore puts the secret
# store back BEFORE the platform Application exists, because Velero moves
# volume data through a pod and a store whose pod Argo has already created
# keeps the empty volume it was given (deploy#1739 measured that on kind). The
# app-of-apps brings the platform Application, so on a restore it is created
# AFTER the store is back, and `make recreate` re-applies this root with the
# default to do it.
#
# This is a bringup-ORDER input, not a feature flag: there is no second
# codepath behind it and no state in which stage 2 is permanently absent. A
# recreate that ends with this false is a failed recreate.
# ----------------------------------------------------------------------------
variable "bootstrap_app_of_apps" {
  description = "Create the app-of-apps Application. Always true except inside a restore, where the recreate verb creates it only after the secret store is back (ADR-0083, deploy#1746)."
  type        = bool
  default     = true
}
