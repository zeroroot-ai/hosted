argocd_extra_platform_namespaces = [
  "setec-system",
  "monitoring",
]

argocd_extra_cluster_resources = [
  { group = "setec.zeroroot.ai", kind = "SandboxClass" },
]
