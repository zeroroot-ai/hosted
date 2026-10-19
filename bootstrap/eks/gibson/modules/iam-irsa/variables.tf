variable "workspace_name" {
  description = "Prefix for role names (zeroroot-ai-staging | zeroroot-ai-prod)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS cluster OIDC provider ARN."
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS cluster OIDC issuer URL (https://oidc.eks.<region>.amazonaws.com/id/<id>)."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name, substituted into the Karpenter controller policy's CLUSTER_NAME placeholder scoping conditions."
  type        = string
}

variable "partition" {
  description = "AWS partition (aws, aws-us-gov, aws-cn). Read at the ROOT and passed in: a data source inside this module is deferred by its depends_on, and a deferred partition forces the EBS CSI policy attachment to be replaced."
  type        = string

  validation {
    condition     = length(var.partition) > 0
    error_message = "partition must not be empty: an empty partition builds a malformed policy ARN."
  }
}
