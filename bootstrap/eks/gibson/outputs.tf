# ----------------------------------------------------------------------------
# Outputs consumed by operators inspecting state via `terraform output`.
#
# Stage 1 emits only cluster identity and network facts (ADR-0083). No KMS
# alias, no bucket name, no secret ARN, no IRSA role for a workload: those
# constructs no longer exist here. The chart takes no value from this
# workspace — the umbrella renders the same on every substrate.
# ----------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR."
  value       = module.network.vpc_cidr
}

output "private_subnet_ids" {
  description = "Private subnet IDs across all 3 AZs."
  value       = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs across all 3 AZs (NLB / NAT lives here)."
  value       = module.network.public_subnet_ids
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API endpoint (private; public only when operator_cidrs is non-empty)."
  value       = module.cluster.cluster_endpoint
}
