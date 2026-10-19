# ----------------------------------------------------------------------------
# Input variables for the kind/gibson workspace.
# ----------------------------------------------------------------------------

variable "cluster_name" {
  description = "kind cluster name. Must match the cluster created by kind-create."
  type        = string
  default     = "gibson"
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig. Defaults to ~/.kube/config."
  type        = string
  default     = "~/.kube/config"
}

variable "argocd_version" {
  description = "ArgoCD Helm chart version."
  type        = string
  default     = "8.1.3"
}

# No other operator version lives here. cert-manager, external-secrets,
# external-dns, CNPG and SPIRE are umbrella subcharts (ADR-0083, deploy#1728);
# their versions are pinned in helm/gibson/Chart.yaml.

# No LLM, Stripe or other credential variables (deploy#1732). Every seed key
# is generated or read from the bringup keyring by the openbao-auto-init
# sidecar. The GHCR pull token and the LLM keys are keyring members
# (GHCR_PULL_TOKEN, LLM_KEYS_JSON, scripts/keyring.sh). Stripe and the other
# operator-supplied values are set with scripts/baseline-set-secret.sh.
