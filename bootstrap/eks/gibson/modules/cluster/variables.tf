
variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

# var.k8s_version is intentionally NOT a variable here — design.md R2.1
# mandates the module pick the latest STANDARD version at apply time via
# data "aws_eks_cluster_versions". See main.tf for the lookup.

variable "vpc_id" {
  description = "VPC ID from the network module."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (node placement + control plane ENIs)."
  type        = list(string)
}

variable "operator_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint. Empty = private-only endpoint access."
  type        = list(string)
  default     = []
}



variable "system_nodegroup_size" {
  description = "System nodegroup min/desired/max. ARM64 (m6g family) — controllers, ESO, ArgoCD, monitoring."
  type        = object({ min = number, desired = number, max = number })
}

variable "workload_nodegroup_size" {
  description = "Workload nodegroup min/desired/max. x86_64 (m8i family, the sandbox fleet) — daemon, dashboard, tenant-operator, ext-authz."
  type        = object({ min = number, desired = number, max = number })
}

variable "system_instance_types" {
  description = "Instance types for the system nodegroup. MUST be ARM64 (Graviton, e.g. m6g.*) to match the AL2023_ARM_64_STANDARD AMI. Default m6g.large. A cheap dev org may shrink via tfvars."
  type        = list(string)
  default     = ["m6g.large"]
}

variable "workload_instance_types" {
  description = "Instance types for the workload nodegroup, the sandbox fleet. MUST be x86_64 to match the AL2023_x86_64_STANDARD AMI, and MUST expose /dev/kvm: c8i, m8i, r8i or metal (hosted#446). Default m8i.xlarge."
  type        = list(string)
  default     = ["m8i.xlarge"]
}

variable "node_disk_size_gb" {
  description = "Root EBS volume (gp3) size in GiB for BOTH node groups. The AL2023 EKS AMI defaults to 20 GiB, which is too small for the umbrella's image footprint — the daemon pod's belief-sidecar (xgboost/pgmpy, multi-GB, deploy#937) plus neo4j/zitadel/prometheus/dashboard layers overflow 20 GiB, causing ImagePullBackOff + 'no space left on device' + inode-pressure evictions (deploy#826). 100 GiB gives headroom on a floor node; gp3 is ~$0.08/GiB-mo."
  type        = number
  default     = 100
}

variable "audit_log_retention" {
  description = "CloudWatch Logs retention for control-plane logs. Default 2192 = 6 years per R2.5 / R13.3."
  type        = number
  default     = 2192

  validation {
    condition     = var.audit_log_retention >= 2192
    error_message = "Audit log retention must be at least 6 years (2192 days) per R13.3."
  }
}



variable "common_tags" {
  description = "Workspace-level tags (Environment / Project / Owner / CostCenter) — passed through to launch-template tag_specifications so EKS-launched EC2 instances carry the SCP-required tag set."
  type        = map(string)
}

# The principal that administers the cluster. Declared, never derived from the
# applying identity: a derived entry makes every plan from a different role
# force a replacement (deploy blocker 1). Defaults to the role operators
# already assume into the workload account, which is the entry the live
# staging cluster carried.
variable "cluster_admin_role_arn" {
  description = "IAM role ARN granted AmazonEKSClusterAdminPolicy on the cluster."
  type        = string
  default     = "arn:aws:iam::447184491447:role/OrganizationAccountAccessRole"
}

variable "platform_domain" {
  description = "The platform domain (global.domain of the environment overlay). CoreDNS maps api.<domain> and app.<domain> to the Envoy Service inside the cluster (hosted#397)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.platform_domain))
    error_message = "platform_domain must be a bare domain name, for example zeroroot.ai."
  }
}

variable "platform_namespace" {
  description = "The namespace of the platform release, which holds the Envoy Service."
  type        = string
  default     = "gibson"
}

variable "service_cidr" {
  description = "The Kubernetes Service range of the cluster (service_ipv4_cidr)."
  type        = string
}
