output "role_arns" {
  description = "Map of controller role name -> IAM role ARN: aws_lb_controller, ebs_csi, karpenter."
  value       = { for k, v in aws_iam_role.this : k => v.arn }
}

