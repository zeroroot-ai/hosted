
variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}



variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "iam_role_arns" {
  description = "IRSA role ARNs map from the iam-irsa module. Keys read here: aws_lb_controller, karpenter."
  type        = map(string)
}


variable "karpenter_interruption_queue_name" {
  description = "SQS queue name for Karpenter spot-interruption events. Used in the helm values only — do NOT gate the release count on it (the queue name is known only after apply, which breaks cold-state `terraform import`/plan). Gate on enable_karpenter instead."
  type        = string
  default     = ""
}

variable "enable_karpenter" {
  description = "Install the Karpenter helm release. Static toggle so the release count is determinable at plan/import time (the SQS queue name is apply-time). #703."
  type        = bool
  default     = false
}


variable "vpc_id" {
  description = "VPC ID where the cluster runs — passed to aws-lb-controller helm because the launch template's IMDSv2 hop limit (1) blocks pods from auto-detecting via EC2 metadata."
  type        = string
}
