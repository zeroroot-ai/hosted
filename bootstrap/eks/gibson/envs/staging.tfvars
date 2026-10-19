# ----------------------------------------------------------------------------
# STAGING — the env axis of the unified eks/gibson root (deploy#1397).
#
# Applied via `make eks-<target> ENV=staging`, which threads
# `-var-file=envs/staging.tfvars` through every terraform invocation. This file
# is COMMITTED: it holds no secret and no operator-specific value. Those two
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
# Staging is a cheap, torn-down-and-rebuilt env. Where it differs from the
# committed production-grade defaults it does so to shrink the footprint, and
# every such override is annotated with the issue that set it.
# ----------------------------------------------------------------------------

# --- identity ---------------------------------------------------------------
environment      = "staging"
workspace_name   = "zeroroot-ai-staging"
cluster_name     = "zeroroot-ai-staging"
cost_center      = "platform-staging"
app_of_apps_path = "gitops/envs/staging" # ADR-0072 — the gitops overlay this cluster reconciles

# --- DNS ---------------------------------------------------------------------
# A sub-zone: stage 0 (eks/gibson-bootstrap, make substrate ENV=staging)
# created staging.zeroroot.ai and delegated it with one NS record in the apex,
# which eks/apex-zone owns (ADR-0083). This root reads it as a data source.
route53_zone_name = "staging.zeroroot.ai"
apex_zone_name    = "zeroroot.ai"

# ArgoCD scope additions beyond the platform baseline. Order matters — these
# are appended, and the rendered ClusterRole/AppProject must stay byte-stable.
#   node.k8s.io, setec.zeroroot.ai — setec RuntimeClasses + SandboxClasses
#                                    (deploy#1415, #1431)
#   actions.github.com             — ARC mints AutoscalingListeners and
#                                    EphemeralRunners at runtime
argocd_extra_managed_api_groups = [
  "node.k8s.io",
  "setec.zeroroot.ai",
  "actions.github.com",
]

#   arc-systems / arc-runners / setec-system — the ephemeral GitHub Actions
#                     runners and the Role that lets them drive setec
#   setec-sandboxes — the sandbox namespace; its absence aborted the gibson app
#                     sync with "namespace ... is not permitted in project"
#                     (deploy#1429, #1434)
argocd_extra_platform_namespaces = [
  "arc-systems",
  "arc-runners",
  "setec-system",
  "setec-sandboxes",
]

# The only third-party Helm source any staging Application names.
argocd_extra_platform_source_repos = [
  "ghcr.io/actions/actions-runner-controller-charts",
]

# Cluster-scoped kinds only the setec-enabled umbrella renders (deploy#1431).
argocd_extra_cluster_resources = [
  { group = "node.k8s.io", kind = "RuntimeClass" },
  { group = "setec.zeroroot.ai", kind = "SandboxClass" },
]

# --- sizing (deploy#698) — matches the LIVE staging nodegroups exactly --------
system_nodegroup_size   = { min = 1, desired = 1, max = 2 }
workload_nodegroup_size = { min = 1, desired = 1, max = 3 }
system_instance_types   = ["m6g.large"]
workload_instance_types = ["m8i.xlarge"]
single_nat_gateway      = true
