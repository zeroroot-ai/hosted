module "argocd" {
  source = "../../modules/argocd"

  depends_on = [
    aws_eip_association.node,
    aws_route.default,
    aws_route_table_association.public,
    aws_vpc_security_group_egress_rule.all,
    aws_iam_role_policy_attachment.ssm,
  ]
}
