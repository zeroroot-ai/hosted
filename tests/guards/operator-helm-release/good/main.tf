# FIXTURE for scripts/check-no-operator-helm-release.py — what stage 1 may
# install: Argo CD, and the cloud-bound rows of ADR-0083 (a LoadBalancer
# implementation here). The guard must produce no finding on this file.

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "8.1.3"
}

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.4"
}

# A chart whose NAME contains an operator name is not that operator.
resource "helm_release" "privateca_issuer" {
  name       = "aws-privateca-issuer"
  namespace  = "cert-manager"
  repository = "https://cert-manager.github.io/aws-privateca-issuer"
  chart      = "aws-privateca-issuer"
  version    = "v1.8.1"
}
