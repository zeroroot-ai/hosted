output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "cluster_oidc_issuer_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  value = module.eks.cluster_oidc_issuer_url
}

output "cluster_security_group_id" {
  description = "Cluster-level SG (EKS-managed, covers control-plane ENIs)."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Node SG shared by all managed node groups. Consumed by RDS and EFS SG ingress rules."
  value       = module.eks.node_security_group_id
}

# The EKS-managed PRIMARY cluster SG (eks-cluster-sg-<cluster>) is what the
# managed node group instances actually run with (attach_cluster_primary_
# security_group). RDS/EFS ingress must allow THIS sg for in-cluster pods to
# reach the data tier — node_security_group_id above is created by the module
# but is not attached to the node ENIs, so allowing only it blocks pod→Aurora
# traffic (#703).
output "cluster_primary_security_group_id" {
  description = "EKS-managed primary cluster SG attached to node instances. Consumed by RDS/EFS SG ingress rules."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_role_name" {
  value = aws_iam_role.node.name
}
