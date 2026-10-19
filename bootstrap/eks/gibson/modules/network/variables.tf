
variable "cluster_name" {
  description = "Cluster name, used to tag subnets for EKS auto-discovery."
  type        = string
}

variable "single_nat_gateway" {
  description = "When true, route all private subnets through ONE shared NAT gateway instead of one-per-AZ. Default false keeps the production multi-AZ posture (no NAT as a single-AZ failure point). A cheap dev org sets this true to save ~$90/mo, accepting that a NAT-AZ outage drops egress for all private pods."
  type        = bool
  default     = false
}

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC. Must not overlap any other workspace (e.g. gibson-dev uses 10.42.0.0/16). Production default is 10.40.0.0/16."
  type        = string
  default     = "10.40.0.0/16"
}

variable "availability_zones" {
  description = "Three AZs to span. Validated at root."
  type        = list(string)
}



