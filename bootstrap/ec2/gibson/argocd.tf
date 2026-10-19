# ----------------------------------------------------------------------------
# Phase 2: Argo CD, from the shared module.
#
# The SAME module bootstrap/eks/gibson uses. It speaks Kubernetes and Git
# only, so one copy serves every substrate and there is one Argo CD
# everywhere, including its chart pin.
#
# This is the whole of stage 1's second phase. Everything after it is stage 2:
# Argo syncs the umbrella from the overlay this environment names.
# ----------------------------------------------------------------------------

module "argocd" {
  source              = "../../modules/argocd"
  app_of_apps_path    = var.app_of_apps_path
  app_of_apps_enabled = var.bootstrap_app_of_apps
  git_repo_url        = var.git_repo_url
  git_revision        = var.git_revision
  route53_zone_name   = var.route53_zone_name

  extra_managed_api_groups    = var.argocd_extra_managed_api_groups
  extra_platform_namespaces   = var.argocd_extra_platform_namespaces
  extra_platform_source_repos = var.argocd_extra_platform_source_repos
  extra_cluster_resources     = var.argocd_extra_cluster_resources

  # The cluster lives inside the instance, so Argo CD must be created after
  # it answers and destroyed before it goes. Without this, a destroy can
  # terminate the instance first and then fail forever trying to delete
  # Kubernetes objects through an API that no longer exists.
  #
  # The API is reached only through an SSM port forward, and SSM needs the
  # node's way out: the default route, the subnet's route table, the egress
  # rule and the SSM policy on the instance role. Each one is listed, so that
  # a destroy removes Argo CD before it removes the path to the API.
  # Measured 2026-10-06: with only the address association listed, the
  # destroy removed the egress rule and the route table association in
  # parallel with the Argo CD release, the SSM session lost its network, and
  # the destroy stopped on "failed to delete release: argocd".
  # scripts/check-ec2-argocd-depends-on.py keeps this list complete.
  depends_on = [
    aws_eip_association.node,
    aws_route.default,
    aws_route_table_association.public,
    aws_vpc_security_group_egress_rule.all,
    aws_iam_role_policy_attachment.ssm,
  ]
}
