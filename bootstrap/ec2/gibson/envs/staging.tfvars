# STAGING, stage 1 of ADR-0083 on a plain cluster (hosted#159). Applied by
# `make recreate ENV=staging`, which selects this file and the backend key
# from the one ENV.

environment    = "staging"
workspace_name = "zeroroot-ai-staging"
cluster_name   = "zeroroot-ai-staging"
cost_center    = "platform-staging"

# The zone stage 0 created and delegated. Every host of this environment is a
# record in it: app.staging.zeroroot.ai, api.staging.zeroroot.ai and so on.
route53_zone_name = "staging.zeroroot.ai"

# 8 vCPU and 32 GB. The measured floor for the whole stack plus sandboxes.
instance_type  = "m8i.2xlarge"
root_volume_gb = 200

# The Kubernetes API is not reachable from the internet. The operator reaches
# it through SSM. Naming an address range here opens port 6443 to it.
api_allow_cidrs = []

# The gitops overlay this cluster reconciles (ADR-0072).
app_of_apps_path = "gitops/envs/staging"

# Beyond the platform baseline, staging's Argo manages the sandbox runtime
# and the self-hosted runners.
argocd_extra_managed_api_groups = [
  "node.k8s.io",
  "setec.zeroroot.ai",
  "actions.github.com",
]

argocd_extra_platform_namespaces = [
  "arc-systems",
  "arc-runners",
  "setec-system",
  "setec-sandboxes",
  # The Prometheus stack of the environment (D26, hosted#423).
  "monitoring",
]

argocd_extra_platform_source_repos = [
  "ghcr.io/actions/actions-runner-controller-charts",
  "https://prometheus-community.github.io/helm-charts",
]

argocd_extra_cluster_resources = [
  { group = "node.k8s.io", kind = "RuntimeClass" },
  { group = "setec.zeroroot.ai", kind = "SandboxClass" },
]
