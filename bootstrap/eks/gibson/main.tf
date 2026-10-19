# ----------------------------------------------------------------------------
# Stage 1 on AWS: the cluster and nothing else (ADR-0083 § Where the cluster
# ends). ONE root, BOTH environments (deploy#1397). The env axis lives in
# envs/<env>.tfvars. Never invoke terraform here directly:
#
#   make eks-init  ENV=staging      # backend from the stage 0 durable bucket
#   make eks-plan  ENV=staging      # -var-file=envs/staging.tfvars
#
# A bare `terraform apply` in this directory has no -var-file, so every
# env-identifying variable is unset and the plan fails — deliberately. That
# failure is the guard that stops a staging apply landing on prod state.
#
# This root provides the six stage 1 rows and nothing else:
#
#   storage            EBS CSI addon + gp3 default StorageClass (modules/cluster)
#   LoadBalancer       AWS Load Balancer Controller (modules/bootstrap-addons)
#   node autoscaling   Karpenter (karpenter.tf + modules/bootstrap-addons)
#   metrics-server     EKS community addon (below)
#   Argo CD            ../../modules/argocd (shared, hosted#159)
#
# plus what those rows stand on: the VPC (modules/network), the EKS cluster
# with its node groups and OIDC provider (modules/cluster), and the three
# controller IRSA roles (modules/iam-irsa: LB controller, EBS CSI, Karpenter).
#
# Everything that used to live here beyond that — Aurora, Secrets Manager,
# the KMS keys, the workload IRSA roles, WAFv2, GuardDuty, SES, ACM and the
# ALB Ingress, ESO, cert-manager, external-dns, the Private CA issuer, EFS
# CSI, the Grafana agent, Argo Image Updater — was deleted by deploy#1744.
# The umbrella chart or stage 0 (eks/gibson-bootstrap) owns the replacement.
# scripts/check-stage1-shape.py keeps it deleted.
# ----------------------------------------------------------------------------

module "network" {
  source = "./modules/network"

  cluster_name       = var.cluster_name
  aws_region         = var.aws_region
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  single_nat_gateway = var.single_nat_gateway
}

module "cluster" {
  source = "./modules/cluster"

  cluster_name        = var.cluster_name
  vpc_id              = module.network.vpc_id
  private_subnet_ids  = module.network.private_subnet_ids
  operator_cidrs      = var.operator_cidrs
  audit_log_retention = var.eks_audit_log_retention_days

  system_nodegroup_size   = var.system_nodegroup_size
  workload_nodegroup_size = var.workload_nodegroup_size
  system_instance_types   = var.system_instance_types
  workload_instance_types = var.workload_instance_types
  service_cidr            = var.service_cidr

  # CoreDNS maps the platform's public hosts to the Envoy Service (hosted#397).
  # The environment's zone IS the platform domain on this substrate.
  platform_domain = var.route53_zone_name

  common_tags = local.common_tags

  depends_on = [module.network]
}

# The three controller roles stage 1 keeps (ADR-0083): the LB controller,
# EBS CSI and Karpenter federate against the cluster's OIDC provider. Every
# workload role is gone — the platform's one cloud credential is the durable
# bucket credential in the bringup keyring, minted by stage 0.
module "iam_irsa" {
  source = "./modules/iam-irsa"

  cluster_name      = var.cluster_name
  workspace_name    = var.workspace_name
  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_provider_url = module.cluster.oidc_provider_url

  # Read HERE, not inside the module. `depends_on` below defers every data
  # source the module declares, and a deferred partition lands on a ForceNew
  # policy ARN and forces a replacement (exit-test-terraform run 34990262565).
  partition = data.aws_partition.current.partition

  depends_on = [module.cluster]
}

# ----------------------------------------------------------------------------
# aws-ebs-csi-driver — EKS managed addon. Lives at workspace root rather
# than inside module.cluster because it needs the IRSA role ARN that
# module.iam_irsa emits AFTER the cluster comes up (chicken-and-egg —
# module.iam_irsa needs the cluster's OIDC provider). The gp3 default
# StorageClass it provisions for lives in modules/cluster.
# ----------------------------------------------------------------------------

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.cluster.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.iam_irsa.role_arns["ebs_csi"]

  # OVERWRITE lets terraform re-take ownership if the addon was installed
  # out-of-band.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# metrics-server — an EKS community addon since 2024, so it is not a
# helm_release (ADR-0083 § Where the cluster ends names it as the EKS
# implementation of the metrics-server row). No IRSA: it talks only to the
# kubelet.
resource "aws_eks_addon" "metrics_server" {
  cluster_name = module.cluster.cluster_name
  addon_name   = "metrics-server"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# The LoadBalancer implementation and the Karpenter controller. cert-manager,
# external-dns and external-secrets are umbrella subcharts (ADR-0083,
# deploy#1728); scripts/check-no-operator-helm-release.py fails CI if one of
# those charts comes back as a helm_release.
module "bootstrap_addons" {
  source = "./modules/bootstrap-addons"

  cluster_name                      = module.cluster.cluster_name
  aws_region                        = var.aws_region
  iam_role_arns                     = module.iam_irsa.role_arns
  enable_karpenter                  = true
  karpenter_interruption_queue_name = aws_sqs_queue.karpenter.name
  vpc_id                            = module.network.vpc_id

  depends_on = [module.cluster, module.iam_irsa]
}

module "argocd" {
  # Shared with the plain-cluster stage 1 root (hosted#159). The module speaks
  # Kubernetes and Git only: it takes the cluster name as information, never as
  # a provider input, so one copy serves every substrate.
  source = "../../modules/argocd"

  app_of_apps_path    = var.app_of_apps_path
  app_of_apps_enabled = var.bootstrap_app_of_apps
  git_repo_url        = var.git_repo_url
  git_revision        = var.git_revision
  route53_zone_name   = var.route53_zone_name

  # Per-env platform axes (deploy#1397). Empty on prod; staging carries setec
  # and the ARC runners. Appended to the module's baseline in order, so the
  # rendered AppProject and ClusterRole are byte-identical to the pre-
  # unification staging fork.
  extra_managed_api_groups    = var.argocd_extra_managed_api_groups
  extra_platform_namespaces   = var.argocd_extra_platform_namespaces
  extra_platform_source_repos = var.argocd_extra_platform_source_repos
  extra_cluster_resources     = var.argocd_extra_cluster_resources

  # ArgoCD repo-creds are seeded from the org GitHub App by
  # scripts/keyring-to-cluster.sh (ADR-0083), not Terraform, so no credential
  # is threaded here. The chart's OCI package is public (anonymous pull).

  # Pluggable ops SSO (github|gitlab|oidc) via the bundled Dex — a SEPARATE
  # identity plane from Zitadel. sso_provider="none" until the operator wires a
  # provider (deploy#1214, eks/aws-org/runbooks/RUNBOOK-argocd-sso.md). All
  # three providers carry an OAuth client secret, passed via
  # TF_VAR_argocd_sso_client_secret (never in version control).
  sso_provider      = var.argocd_sso_provider
  sso_client_id     = var.argocd_sso_client_id
  sso_client_secret = var.argocd_sso_client_secret
  sso_github_org    = var.argocd_sso_github_org
  sso_base_url      = var.argocd_sso_base_url
  sso_admin_group   = var.argocd_sso_admin_group

  depends_on = [module.bootstrap_addons]
}
