argocd_extra_managed_api_groups = [
  "node.k8s.io",
  "setec.zeroroot.ai",
]

argocd_extra_platform_namespaces = [
  "setec-system",
  "monitoring",
]

argocd_extra_cluster_resources = [
  { group = "setec.zeroroot.ai", kind = "SandboxClass" },
]
