# ----------------------------------------------------------------------------
# PRODUCTION — the env axis of the unified eks/gibson root (deploy#1397).
#
# Applied via `make eks-<target> ENV=prod`, which threads
# `-var-file=envs/prod.tfvars` through every terraform invocation. This file is
# COMMITTED: it holds no secret and no operator-specific value. Those two
# classes stay out on purpose —
#
#   operator_cidrs      operator workstation public IP; lives in the gitignored
#                       terraform.tfvars (a real IP must never be committed).
#   argocd_sso_*        client secret likewise via TF_VAR_.
#
# terraform's precedence puts -var-file ABOVE terraform.tfvars, so anything
# named here wins over an operator's local copy. That is why the two secret
# axes above are deliberately absent rather than set to a placeholder.
#
# The committed module/root defaults are already production-grade — multi-AZ
# NAT and HA nodegroup floors. So this file sets the env identity and almost
# nothing else: a hardened prod cluster runs on the defaults. Contrast
# envs/staging.tfvars, which shrinks the footprint for a cheap, torn-down env.
#
# NOTE: no prod EKS cluster stands as of 2026-08-13. `make eks-init ENV=prod`
# requires the eks/gibson-bootstrap workspace (stage 0) applied for prod
# first.
# ----------------------------------------------------------------------------

# --- identity ---------------------------------------------------------------
environment      = "prod"
workspace_name   = "zeroroot-ai-prod"
cluster_name     = "zeroroot-ai-prod"
cost_center      = "platform-prod"
app_of_apps_path = "gitops/envs/prod" # ADR-0072 — the gitops overlay this cluster reconciles

# --- DNS ---------------------------------------------------------------------
# Prod's zone IS the apex. The apex is owned by eks/apex-zone (ADR-0083) and
# is read here as a data source; this env creates no zone and no mail record.
route53_zone_name = "zeroroot.ai"
apex_zone_name    = "zeroroot.ai"

# --- Argo CD scope (deploy#1397) ----------------------------------------------
# Prod runs setec like every other env (D8). setec needs four Argo CD scope
# additions, or the gibson sync aborts or drops objects silently (deploy#1429):
#   1. controller resource.inclusions and ClusterRole: node.k8s.io and
#      setec.zeroroot.ai (argocd_extra_managed_api_groups)
#   2. AppProject clusterResourceWhitelist: RuntimeClass and SandboxClass
#      (argocd_extra_cluster_resources)
#   3. AppProject clusterResourceWhitelist: ValidatingAdmissionPolicy and its
#      Binding. These are in the platform baseline of modules/argocd for every
#      env, so prod needs no line for them.
#   4. AppProject destinations: setec-system and setec-sandboxes
#      (argocd_extra_platform_namespaces)
# Prod runs no ephemeral GitHub Actions runners, so actions.github.com and the
# arc-* namespaces of staging stay out.
argocd_extra_managed_api_groups = [
  "node.k8s.io",
  "setec.zeroroot.ai",
]
# The Prometheus stack of the environment (D26, hosted#423), then setec.
argocd_extra_platform_namespaces = [
  "monitoring",
  "setec-system",
  "setec-sandboxes",
]
argocd_extra_platform_source_repos = ["https://prometheus-community.github.io/helm-charts"]
argocd_extra_cluster_resources = [
  { group = "node.k8s.io", kind = "RuntimeClass" },
  { group = "setec.zeroroot.ai", kind = "SandboxClass" },
]

# --- sizing ------------------------------------------------------------------
# Intentionally NOT set — the committed prod-grade defaults stand:
#   single_nat_gateway      -> false (multi-AZ NAT)
#   system_nodegroup_size   -> { min = 2, desired = 2, max = 3 }
#   workload_nodegroup_size -> { min = 2, desired = 2, max = 6 } (Karpenter bursts above)
