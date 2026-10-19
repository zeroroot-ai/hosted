# FIXTURE for scripts/check-no-operator-helm-release.py — the shape the guard
# must reject: the four operators the umbrella owns, declared as Terraform
# helm_releases the way kind/gibson/operators.tf and
# eks/gibson/modules/bootstrap-addons/main.tf declared them before deploy#1728.
# One release per chart, in the three spellings the guard must see through.

resource "helm_release" "eso" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.18.2"
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.16.2"

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

resource "helm_release" "cnpg" {
  name      = "cnpg"
  namespace = "cnpg-system"
  chart     = "oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg"
  version   = "0.23.0"
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.15.0"
}
