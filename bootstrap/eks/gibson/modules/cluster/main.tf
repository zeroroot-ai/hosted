# ----------------------------------------------------------------------------
# EKS control plane + two managed node groups (system, workload).
#
# Production hardening over dev:
#   - Customer-managed KMS envelope encryption of K8s Secrets.
#   - All five control-plane log types enabled, KMS-encrypted CloudWatch
#     Logs group, 6-year retention (R2.5).
#   - Public API endpoint only when operator_cidrs is non-empty (private
#     by default per R2.4).
#   - Launch templates with IMDSv2 required + 1-hop limit (SSRF protection).
#   - AL2023 nodes, SSM-managed.
#   - K8s version: dynamic lookup of latest STANDARD via
#     data "aws_eks_cluster_versions" — applies always pick the newest
#     supported (R2.1).
#
# Node groups:
#   - system: ARM64 (m6g.large), tainted workload=system. Runs controllers,
#             ESO, ArgoCD, monitoring (which all support arm64).
#   - workload: x86_64 (m6i.xlarge). Runs daemon, dashboard, tenant-operator,
#               ext-authz. Karpenter manages bursts above max.
#
# The legacy `data` node group is intentionally absent — the chart's
# Postgres tier is consolidated onto Aurora SLv2; sandbox hosts are owned
# by the sister setec-sandbox-prod-default spec.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# Dynamic K8s version — pull latest STANDARD support at apply time.
# Operators can pin a specific version by overriding the local in this
# file or wiring a var; default behaviour is "latest" per R2.1.
# ----------------------------------------------------------------------------

locals {
  platform_envoy_service = "gibson-envoy.${var.platform_namespace}.svc.cluster.local"

  # The Corefile the EKS CoreDNS add-on ships, with the two rewrite rules at
  # the head of the server block. A changed default in a later add-on version
  # does not reach this text: compare it with the add-on's default when the
  # add-on version moves.
  coredns_corefile = <<-EOT
    .:53 {
        rewrite name exact api.${var.platform_domain} ${local.platform_envoy_service} answer auto
        rewrite name exact app.${var.platform_domain} ${local.platform_envoy_service} answer auto
        errors
        health {
          lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf
        cache 30
        loop
        reload
        loadbalance
    }
  EOT
}

data "aws_eks_cluster_versions" "this" {
  cluster_type   = "eks"
  default_only   = false
  include_all    = false
  version_status = "STANDARD_SUPPORT"
}

locals {
  k8s_version = sort(data.aws_eks_cluster_versions.this.cluster_versions[*].cluster_version)[length(data.aws_eks_cluster_versions.this.cluster_versions) - 1]
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = local.k8s_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.private_subnet_ids

  # The Service range is a committed value, not the EKS default, because the
  # apiserver egress rule of the gitops overlay names its first address.
  service_ipv4_cidr = var.service_cidr

  # Private endpoint always on. Public endpoint only when operator_cidrs is
  # supplied; empty list means no public access at all (R2.4).
  endpoint_private_access      = true
  endpoint_public_access       = length(var.operator_cidrs) > 0
  endpoint_public_access_cidrs = var.operator_cidrs

  # false, and the admin entry declared explicitly below instead. When true,
  # the module derives an access entry from data.aws_caller_identity — that
  # is, from WHOEVER RAN THE APPLY. State then records a concrete principal,
  # and any plan made by a different identity sees it as (known after apply)
  # and FORCES REPLACEMENT of the access entry and its policy association.
  # Blocker 1 asserts "nothing in the replace set", so it read red whenever a
  # cluster stood and CI planned as eks-plan-readonly rather than the role
  # that applied (observed 2026-09-03, deploy#1801 fixed a second identity
  # coupling in the same job). Who may administer the cluster is a property of
  # the CONFIGURATION, not of whose laptop ran terraform.
  enable_cluster_creator_admin_permissions = false

  # The same principal the module used to grant implicitly, now named. This is
  # the only human-facing access entry the live staging cluster carried.
  access_entries = {
    admin = {
      principal_arn = var.cluster_admin_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
  enable_irsa = true

  # No customer-managed KMS key (ADR-0083: the KMS keys left the infra
  # plane, deploy#1744). EKS encrypts secrets at rest with an AWS-owned key
  # by default, and nothing this cluster stores in a Secret outlives it —
  # the durable secrets live in OpenBao, archived to the stage 0 bucket.
  create_kms_key    = false
  encryption_config = null

  # All five control-plane log types enabled.
  enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]
  cloudwatch_log_group_retention_in_days = var.audit_log_retention

  # EKS add-ons. The EBS CSI driver and metrics-server install at the
  # workspace root (main.tf) — EBS CSI needs the IRSA role ARN that
  # module.iam_irsa emits after this module applies.
  addons = {
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_update = "OVERWRITE"
      # The platform's public hosts answer with the Envoy Service inside the
      # cluster (hosted#397, ADR-0092). Public DNS answers for them too, but
      # that answer is the load balancer: an in-cluster caller would leave the
      # cluster and come back through the edge, and every such caller would
      # share one source address for rate limits. The add-on owns its
      # ConfigMap (OVERWRITE), so the record goes in the add-on configuration
      # and not in a kubectl apply that the next add-on update would undo.
      # The rules are the same two lines the kind and EC2 bringups write
      # (scripts/lib/coredns-platform-hosts.sh): a host maps to the Service
      # NAME, never to an address (hosted#186).
      configuration_values = jsonencode({
        corefile = local.coredns_corefile
      })
    }
  }

  # THERE IS NO kube-proxy ADD-ON either. Cilium replaces kube-proxy
  # (hosted#446, setec#182).
  #
  # THERE IS NO vpc-cni ADD-ON. Cilium is the network plugin (ADR-0083,
  # hosted#436), installed by helm_release.cilium below in ENI mode. The EKS
  # module creates the cluster with no self-managed add-on, so no aws-node
  # DaemonSet exists to remove. Cilium enforces NetworkPolicy and
  # CiliumNetworkPolicy on each node.

  # Node IAM role policies attached via the shared role below; these here
  # are for any module-managed nodegroups (we don't use them — see below).
  iam_role_additional_policies = {
    AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Node groups are authored below as aws_eks_node_group resources so we can
  # apply launch templates with IMDSv2 required.
  eks_managed_node_groups = {}
}

# ----------------------------------------------------------------------------
# Shared node IAM role.
# ----------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The Cilium operator manages the ENIs and the pod addresses of each node
# (ENI mode). It runs on the host network and uses this node role. The action
# list is the one the Cilium documentation gives for ENI mode. It replaces the
# AmazonEKS_CNI_Policy attachment that the VPC CNI used.
resource "aws_iam_role_policy" "node_cilium_eni" {
  name = "${var.cluster_name}-cilium-eni"
  role = aws_iam_role.node.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:AssignPrivateIpAddresses",
        "ec2:AttachNetworkInterface",
        "ec2:CreateNetworkInterface",
        "ec2:CreateTags",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeTags",
        "ec2:DescribeVpcs",
        "ec2:DetachNetworkInterface",
        "ec2:ModifyNetworkInterfaceAttribute",
        "ec2:UnassignPrivateIpAddresses",
      ]
      Resource = "*"
    }]
  })
}

# ----------------------------------------------------------------------------
# Cilium, the network plugin (ADR-0083, hosted#436).
#
# The version and the shared values come from bootstrap/cilium/, the same
# files the kind, k3d and k3s bringups read. This release holds no version
# literal: scripts/check-cilium-pin.py fails on one that differs.
#
# ENI mode. Each pod gets an address of the VPC, as it did with the VPC CNI.
# The EKS control plane must reach the admission webhooks of the platform by
# pod address, so an overlay network is not an option here.
#
# THE ORDER IS LOAD-BEARING. A managed node group reports a failure when its
# nodes do not get Ready, and a node with no network plugin never gets Ready.
# So the release is applied after the control plane and BEFORE the node
# groups, with wait = false: the DaemonSet exists when the first node joins.
# The release depends on the cluster through two values only, never on the
# whole module. The CoreDNS add-on in that module waits for a node, and a
# dependency on it would be a cycle in time: add-on waits for node, node
# group waits for Cilium, Cilium waits for add-on.
#
# The agent reaches the API server by its endpoint, not through the
# kubernetes Service, so it does not wait for kube-proxy on a new node.
# ----------------------------------------------------------------------------
locals {
  cilium_dir     = "${path.module}/../../../../cilium"
  cilium_version = trimspace(file("${local.cilium_dir}/VERSION"))
}

resource "helm_release" "cilium" {
  name       = "cilium"
  namespace  = "kube-system"
  repository = "oci://quay.io/cilium/charts"
  chart      = "cilium"
  version    = local.cilium_version
  wait       = false

  values = [
    file("${local.cilium_dir}/values.yaml"),
    file("${local.cilium_dir}/values-eks.yaml"),
    yamlencode({
      cluster        = { name = module.eks.cluster_name }
      k8sServiceHost = trimprefix(module.eks.cluster_endpoint, "https://")
      k8sServicePort = 443
    }),
  ]
}

# ----------------------------------------------------------------------------
# Launch templates — enforce IMDSv2 and single-hop (prevents SSRF → IMDS
# token theft).
# ----------------------------------------------------------------------------

resource "aws_launch_template" "system" {
  name_prefix   = "${var.cluster_name}-system-"
  ebs_optimized = true

  # Pin the root volume larger than the AL2023 AMI's 20 GiB default — the umbrella
  # image footprint overflows 20 GiB (deploy#826). The AL2023 EKS AMI root device
  # is /dev/xvda.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.common_tags, {
      NodeGroup = "system"
      Cluster   = var.cluster_name
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.common_tags, {
      NodeGroup = "system"
      Cluster   = var.cluster_name
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_template" "workload" {
  name_prefix   = "${var.cluster_name}-workload-"
  ebs_optimized = true

  # Pin the root volume larger than the AL2023 AMI's 20 GiB default — the workload
  # node hosts the daemon pod whose belief-sidecar (xgboost/pgmpy) alone is multi-GB
  # (deploy#826/#937). The AL2023 EKS AMI root device is /dev/xvda.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # The workload nodes are the sandbox fleet (hosted#446): each Firecracker
  # sandbox needs /dev/kvm. A c8i, m8i or r8i node exposes it only with
  # nested virtualization turned on at launch. A metal type needs no setting.
  dynamic "cpu_options" {
    for_each = alltrue([for t in var.workload_instance_types : can(regex("^(c8i|m8i|r8i)\\.", t))]) ? [1] : []
    content {
      nested_virtualization = "enabled"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.common_tags, {
      NodeGroup = "workload"
      Cluster   = var.cluster_name
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.common_tags, {
      NodeGroup = "workload"
      Cluster   = var.cluster_name
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ----------------------------------------------------------------------------
# Managed node groups — system (arm64) + workload (x86_64).
# ----------------------------------------------------------------------------

resource "aws_eks_node_group" "system" {
  # A node needs the network plugin to get Ready. See helm_release.cilium.
  depends_on = [helm_release.cilium, aws_iam_role_policy.node_cilium_eni]

  cluster_name    = module.eks.cluster_name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  # ARM64 — m6g.large is the cheapest production-grade Graviton instance.
  ami_type       = "AL2023_ARM_64_STANDARD"
  instance_types = var.system_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.system_nodegroup_size.desired
    min_size     = var.system_nodegroup_size.min
    max_size     = var.system_nodegroup_size.max
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  taint {
    key    = "workload"
    value  = "system"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "workload" = "system"
  }

  tags = {
    Name = "${var.cluster_name}-system"
  }
}

resource "aws_eks_node_group" "workload" {
  # A node needs the network plugin to get Ready. See helm_release.cilium.
  depends_on = [helm_release.cilium, aws_iam_role_policy.node_cilium_eni]

  cluster_name    = module.eks.cluster_name
  node_group_name = "workload"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = var.workload_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.workload_nodegroup_size.desired
    min_size     = var.workload_nodegroup_size.min
    max_size     = var.workload_nodegroup_size.max
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.workload.id
    version = aws_launch_template.workload.latest_version
  }

  labels = {
    "workload" = "workload"
    # The workload nodes are the sandbox fleet (hosted#446). A setec sandbox
    # selects this label, and scripts/verify-kvm-nodes.sh proves /dev/kvm on
    # each node that carries it.
    "setec.zeroroot.ai/sandbox-host" = "true"
  }

  tags = {
    Name = "${var.cluster_name}-workload"
    # Karpenter takes over above the baseline.
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# ----------------------------------------------------------------------------
# gp3 default StorageClass.
# ----------------------------------------------------------------------------

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }

  depends_on = [module.eks]
}

resource "kubernetes_storage_class" "gp3_retain" {
  metadata {
    name = "gp3-retain"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }

  depends_on = [module.eks]
}

resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true

  depends_on = [module.eks]
}

# ----------------------------------------------------------------------------
# PodSecurity admission on the gibson namespace.
# ----------------------------------------------------------------------------

# The gibson namespace. Terraform creates it before the workload pods land,
# and sets no Pod Security label on it. The gibson Argo Application
# (gitops/envs/<env>/gibson.yaml, managedNamespaceMetadata) is the one place
# that labels it: enforce restricted (D8, ADR-0165, hosted#438). The SPIRE
# agent and the SPIFFE CSI driver, which cannot meet restricted, run in
# spire-system (charts#639). ignore_changes keeps Terraform from removing
# the labels that Argo sets (scripts/check-namespace-pod-security.py).
resource "kubernetes_namespace" "gibson" {
  metadata {
    name = "gibson"
    labels = {
      "gibson" = "prod"
    }
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels["pod-security.kubernetes.io/enforce"],
      metadata[0].labels["pod-security.kubernetes.io/enforce-version"],
      metadata[0].labels["pod-security.kubernetes.io/audit"],
      metadata[0].labels["pod-security.kubernetes.io/warn"],
    ]
  }

  depends_on = [aws_eks_node_group.system, aws_eks_node_group.workload]
}
