# DRILL, stage 1 of ADR-0083 on a plain cluster. Applied by
# `make recreate ENV=drill`, which selects this file and the backend key from the
# one ENV. The durable bucket is drill's own, `zeroroot-ai-drill-durable-<acct>`,
# because both EC2 verbs derive the bucket from ENV and share one state KEY
# inside it. That is the property that keeps a drill teardown away from staging's
# state, and tests/harness/drill-teardown.bats asserts it.

environment    = "drill"
workspace_name = "zeroroot-ai-drill"
cluster_name   = "zeroroot-ai-drill"
cost_center    = "platform-drill"

route53_zone_name = "drill.zeroroot.ai"

# The same shape as staging, deliberately. A drill on a smaller box would prove
# a bringup nobody runs: the measured floor for the whole stack plus sandboxes is
# 8 vCPU and 32 GB, and a drill that passes on a shape staging does not use is
# not evidence about staging.
instance_type  = "m8i.2xlarge"
root_volume_gb = 200

# The API is not published here either. The operator and CI reach it over SSM,
# exactly as they reach staging (ADR-0095).
api_allow_cidrs = []

# THE CEILING. This is the line that makes drill a throwaway rather than a
# second permanent environment (ADR-0095). The node arms
# `shutdown -h +420` from its own cloud-init on every boot and its shutdown
# behaviour is `terminate`, so it dies on its own clock with no network, no
# GitHub, no state file and no credential involved.
#
# 420 minutes is the ceiling, not the plan. The drill workflow tears down at the
# end of its run, which is minutes; this is what covers a cancelled job, a runner
# that vanishes and a destroy that fails. The node serves the up job and then
# the rotation job (.github/workflows/drill.yml, THE BUDGET): a green up job of
# 25 minutes and a rotation job of up to 345 minutes fit in it, with margin
# (hosted#444 added the 15th rotation class). A run that keeps a node for
# longer has gone wrong in a way that should end rather than continue.
#
# staging carries no such line and must never carry one.
self_terminate_after_minutes = 420

# The gitops overlay this cluster reconciles (ADR-0072).
app_of_apps_path = "gitops/envs/drill"

# Argo CD manages the same platform as on staging, so a drill failure is about
# the platform. The one difference: the self-hosted runners (arc-systems,
# arc-runners, actions.github.com and their chart repo) stay on staging only.
# The sandbox runtime is part of the platform (D85): the gibson app syncs
# setec into setec-system and setec-sandboxes, and a project that does not
# permit them fails the whole sync (hosted#618).
# scripts/check-drill-argocd-scope.py holds this list to staging.
argocd_extra_managed_api_groups = [
  "node.k8s.io",
  "setec.zeroroot.ai",
]

# The Prometheus stack of the environment (D26, hosted#423): its namespace and
# its chart repo. The Applications that install it come after this scope is
# applied, so Argo never holds an Application that the project refuses.
argocd_extra_platform_namespaces = [
  "setec-system",
  "setec-sandboxes",
  "monitoring",
]

argocd_extra_platform_source_repos = [
  "https://prometheus-community.github.io/helm-charts",
]

argocd_extra_cluster_resources = [
  { group = "node.k8s.io", kind = "RuntimeClass" },
  { group = "setec.zeroroot.ai", kind = "SandboxClass" },
]

# The drill runs as drill-bringup, which may create a role only when the role
# carries its boundary (bootstrap/eks/aws-org/github-oidc-drill.tf). So the node
# role of drill carries it too.
node_permissions_boundary_name = "PB-DrillBringup"
