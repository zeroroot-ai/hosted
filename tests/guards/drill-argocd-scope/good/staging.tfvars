argocd_extra_managed_api_groups = [
  "node.k8s.io",
  "setec.zeroroot.ai",
  "actions.github.com",
]

argocd_extra_platform_namespaces = [
  "arc-systems",
  "setec-system",
  "monitoring",
]

argocd_extra_cluster_resources = [
  { group = "setec.zeroroot.ai", kind = "SandboxClass" },
]
