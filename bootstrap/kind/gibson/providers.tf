# ----------------------------------------------------------------------------
# Provider configurations for kind/gibson workspace.
#
# Both kubernetes and helm providers point at the kind cluster via the
# local kubeconfig. The context name is always kind-<cluster_name>.
# ----------------------------------------------------------------------------

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = "kind-${var.cluster_name}"
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = "kind-${var.cluster_name}"
  }
}
