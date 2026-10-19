# The shape of 2026-10-05: the destroy removed the egress rule while the
# release was deleted through the SSM forward.
module "argocd" {
  source = "../../modules/argocd"
  # depends_on = [aws_route.default, aws_vpc_security_group_egress_rule.all]
  depends_on = [aws_eip_association.node]
}
