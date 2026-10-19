# ----------------------------------------------------------------------------
# The two stage 1 rows that install via helm_release: the AWS Load Balancer
# Controller (the LoadBalancer implementation) and Karpenter (node
# autoscaling). IRSA role ARNs come from the iam-irsa module. Each
# helm_release is pinned to a specific chart version.
#
# Nothing else installs here (ADR-0083 § Where the cluster ends). ESO,
# cert-manager, external-dns and CNPG are umbrella subcharts (deploy#1728);
# metrics-server and the EBS CSI driver are EKS addons at the root; the
# Private CA issuer, the EFS CSI driver and the Grafana agent were deleted
# (deploy#1744). scripts/check-no-operator-helm-release.py fails CI if an
# operator chart comes back as a helm_release.
# ----------------------------------------------------------------------------

# ============================================================================
# AWS Load Balancer Controller — provisions ALB/NLB for Ingress + LB Services.
# ============================================================================

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.4"
  timeout    = 900
  wait       = true

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  # Launch template enforces IMDSv2 with hop limit 1 (SSRF protection), so
  # pods can't auto-detect VPC ID via EC2 metadata. Pass it explicitly.
  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  # Disable the cluster-wide service mutating webhook (mservice.elbv2.k8s.aws).
  # With failurePolicy=Fail it intercepts EVERY Service create/update; during a
  # cold standup the controller's pods aren't Ready yet (Karpenter still
  # provisioning the node), so the webhook has no endpoints and any addon that
  # creates a Service before the controller is up fails with "no endpoints
  # available for service aws-load-balancer-webhook-service" — the velero addon
  # (since removed, deploy#1193) hit this and aborted the full apply
  # (deploy#899). The webhook's only function is to default the
  # aws-load-balancer-type annotation on type:LoadBalancer services
  # that omit it; our only such service (gibson envoy NLB) sets the annotation
  # explicitly, so the mutator is unnecessary. Removing it eliminates the
  # cluster-wide bootstrap race for every Service created during standup.
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }
}

resource "kubernetes_service_account" "aws_lb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = var.iam_role_arns["aws_lb_controller"]
    }
  }
}

# ============================================================================
# Karpenter — node autoscaler for the platform nodegroup.
# ============================================================================

resource "helm_release" "karpenter" {
  # Static toggle — NOT the apply-time queue name — so the count is known at
  # plan/import time (cold-state `terraform import` of the DNS zone evaluates
  # this count). The queue name still flows into the values below. #703.
  count = var.enable_karpenter ? 1 : 0

  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.0.8"

  values = [yamlencode({
    settings = {
      clusterName       = var.cluster_name
      interruptionQueue = var.karpenter_interruption_queue_name
      featureGates      = { spotToSpotConsolidation = true }
    }
    serviceAccount = {
      create = false
      name   = "karpenter"
    }
    # Chart default is 2 replicas for HA. The floor-sized staging cluster
    # cannot place the second replica (topology spread + CPU), leaving it
    # Pending forever and spamming FailedScheduling events; HA is pointless
    # on an env that is torn down nightly. One replica, by declaration
    # (deploy#881).
    replicas = 1
    controller = {
      resources = {
        requests = { cpu = "200m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }
  })]
}

resource "kubernetes_service_account" "karpenter" {
  metadata {
    name      = "karpenter"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = var.iam_role_arns["karpenter"]
    }
  }
}
