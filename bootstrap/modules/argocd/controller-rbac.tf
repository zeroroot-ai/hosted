# ----------------------------------------------------------------------------
# application-controller ClusterRole + the matching watch set (deploy#1214).
#
# The argo-cd chart's default application-controller ClusterRole is literally
#
#     - apiGroups: ['*']   resources: ['*']      verbs: ['*']
#     - nonResourceURLs: ['*']                   verbs: ['*']
#
# (argo-cd/templates/argocd-application-controller/clusterrole.yaml, taken
# whenever controller.clusterRoleRules.enabled is false — which it was,
# nothing in this repo ever set it). That is cluster-admin plus every
# non-resource URL, on the cluster's most reachable controller.
#
# WHAT THIS BUYS, AND WHAT IT DOES NOT
#
# Read the `escalate` verb below before assuming this is a containment
# boundary. It is not, and it cannot be: a GitOps controller whose job
# includes applying ClusterRoles and ClusterRoleBindings can always write
# itself a binding to cluster-admin. Kubernetes' own escalation-prevention
# rule would normally stop that — you may only create a role granting
# permissions you already hold — but the platform charts defeat it, so the
# controller has to be granted `escalate` (see the rbac rule for the
# evidence). Anyone who can merge to zeroroot-ai/hosted can therefore still
# reach cluster-admin in one commit.
#
# What this DOES do is remove every API group the platform does not deploy
# from the controller's reach. Concretely it can no longer touch karpenter.sh
# (node provisioning, managed by Terraform in karpenter.tf, not by ArgoCD),
# apiregistration.k8s.io (APIService hijack), certificates.k8s.io (CSR
# approval and signing), flowcontrol.apiserver.k8s.io, or any
# CRD group a future operator introduces without a reviewed change here. It
# also drops `impersonate` on serviceaccounts, `pods/exec`, and the blanket
# nonResourceURLs grant. That is defence in depth and a real reduction in
# accidental blast radius; the containment boundary is the AppProject in
# appprojects.tf, and the durable fix for the escalate hole is an admission
# policy that rejects privileged ClusterRoleBindings.
#
# HOW THE SET WAS DERIVED
#
# From the rendered manifests, not from a guess. `helm template helm/gibson
# --include-crds` against the gitops env values, plus helm/saas-overlay/*,
# renders 326 objects across exactly the groups listed below. Every group
# here is present in that render; no group in that render is missing here.
#
# Anything only ONE environment renders is NOT in that baseline — it comes in
# through var.extra_managed_api_groups from eks/gibson/envs/<env>.tfvars
# (deploy#1397). Staging's two additions were derived the same way: the setec
# subchart adds node.k8s.io + setec.zeroroot.ai, and the two ARC charts at the
# pinned 0.14.2 add exactly one group, actions.github.com.
#
# REVERTING
#
# One value: set controller.clusterRoleRules.enabled back to false in
# main.tf. The failure signature to revert on is the application-controller
# logging `failed to list ... is forbidden` for a group, or an Application
# reporting a sync error naming a resource kind.
# ----------------------------------------------------------------------------

locals {
  # Full management. Deliberately excludes `impersonate` (which `verbs: ['*']`
  # on core resources would otherwise grant over every ServiceAccount in the
  # cluster) and `escalate`/`bind`, which are granted only on the rbac group
  # below and only for the documented reason.
  argocd_controller_verbs = [
    "get", "list", "watch", "create", "update", "patch", "delete", "deletecollection",
  ]

  # Core-group resources the controller applies or shows in an app's resource
  # tree. Enumerated rather than `*` so that subresources it has no business
  # with — pods/exec above all — stay out: `resources: ['*']` covers
  # subresources, an explicit list does not.
  argocd_controller_core_resources = [
    "configmaps",
    "endpoints", # resource-tree child of every Service
    "events",    # the controller emits these for Applications
    "namespaces",
    "persistentvolumeclaims", # StatefulSet volume claims
    "persistentvolumes",
    "pods",
    "secrets",
    "serviceaccounts",
    "services",
  ]
  argocd_controller_core_kinds = [
    "ConfigMap",
    "Endpoints",
    "Event",
    "Namespace",
    "PersistentVolumeClaim",
    "PersistentVolume",
    "Pod",
    "Secret",
    "ServiceAccount",
    "Service",
  ]

  # API groups the platform actually deploys into, managed whole. Each one
  # appears in the render:
  #   apps, batch, policy, networking.k8s.io  — workloads, jobs, PDBs, netpols
  #   admissionregistration.k8s.io            — cnpg + spire webhooks
  #   apiextensions.k8s.io                    — the 45 CRDs
  #   scheduling.k8s.io, storage.k8s.io       — PriorityClasses, spire's CSIDriver
  #   argoproj.io                             — the child Applications
  #   cert-manager.io                         — Certificate/Issuer/ClusterIssuer
  #   external-secrets.io                     — ExternalSecret/ClusterSecretStore
  #   monitoring.coreos.com                   — ServiceMonitors
  #   cilium.io                               — the Cilium network policies
  #   generators.external-secrets.io          — the database login generators
  #   spire.spiffe.io                         — ClusterSPIFFEIDs
  #   postgresql.cnpg.io                      — the platform Postgres clusters
  #   velero.io                               — the tenant-neo4j backup Schedule
  #   gibson.zeroroot.ai                      — PlatformBootstrap and the tenant CRs
  argocd_controller_platform_api_groups = [
    "apps",
    "batch",
    "policy",
    "networking.k8s.io",
    "admissionregistration.k8s.io",
    "apiextensions.k8s.io",
    "scheduling.k8s.io",
    "storage.k8s.io",
    "argoproj.io",
    "cert-manager.io",
    "external-secrets.io",
    # The ESO generators group. Every env renders a VaultDynamicSecret
    # generator for each platform database login (charts#602, ADR-0171,
    # helm/gibson-workloads/templates/external-secrets/postgres-logins.yaml).
    # Without the group the controller drops the generators in silence, each
    # ExternalSecret of a database login fails "VaultDynamicSecret ... not
    # found", and the gibson app never passes that wave (staging, 2026-10-12).
    # scripts/check-env-renders-at-pin.py holds this list to the render.
    "generators.external-secrets.io",
    "monitoring.coreos.com",
    # The Cilium policies of the chart (D76): CiliumNetworkPolicy and
    # CiliumClusterwideNetworkPolicy. Without the group the controller drops
    # them in silence and the platform runs with no Cilium policy.
    "cilium.io",
    "spire.spiffe.io",
    "postgresql.cnpg.io",
    "velero.io",
    "gibson.zeroroot.ai",
  ]

  # Per-env additions, appended in order (deploy#1397). Everything above is
  # what EVERY env's umbrella renders; everything a single env renders comes
  # from var.extra_managed_api_groups, set in eks/gibson/envs/<env>.tfvars.
  # Staging supplies:
  #   node.k8s.io, setec.zeroroot.ai — setec (envs/staging setec.enabled,
  #     deploy#1080). The umbrella renders one RuntimeClass per enabled kata
  #     backend plus the SandboxClasses. Both groups were once missing, so the
  #     controller silently dropped them (ExcludedResourceWarning) — no
  #     RuntimeClass ever landed and the sandbox venue never came up
  #     (setec#161, fixed by deploy#1415).
  #   actions.github.com — the ephemeral GitHub Actions runners
  #     (envs/staging/arc-*.yaml) deploy AutoscalingRunnerSets, and the
  #     controller mints AutoscalingListeners and EphemeralRunners under them
  #     at runtime.
  argocd_controller_managed_api_groups = concat(
    local.argocd_controller_platform_api_groups,
    var.extra_managed_api_groups,
  )

  # Read-only. Nothing in the render declares these; they turn up in resource
  # trees as owner-ref children of objects that ARE managed — EndpointSlices
  # under a Service, Orders and Challenges under a cert-manager Certificate —
  # so the controller must be able to see them but never to write them.
  argocd_controller_readonly_api_groups = [
    "discovery.k8s.io",
    "acme.cert-manager.io",
  ]

  argocd_controller_cluster_role_rules = [
    {
      apiGroups = [""]
      resources = local.argocd_controller_core_resources
      verbs     = local.argocd_controller_verbs
    },
    {
      # `escalate` and `bind` are here under protest, and the reason is
      # concrete rather than precautionary. Kubernetes refuses to let a
      # principal create a Role or ClusterRole granting permissions it does
      # not itself hold, unless it holds `escalate`; and it refuses to let it
      # create a binding to a role it does not hold, unless it holds `bind` on
      # that role. The umbrella renders three objects that trip those checks
      # against any enumerated role:
      #
      #   Role/gibson-velero-server            apiGroups ['*'] resources ['*'] verbs ['*']
      #   ClusterRoleBinding/gibson-velero-server   roleRef -> cluster-admin
      #   ClusterRole/gibson-tenant-operator   verb `bind` on a named clusterrole
      #
      # Without these verbs the gibson Application fails to sync with "attempt
      # to grant extra privileges" and goes Degraded. The alternative is to
      # hold cluster-admin, which is what we are removing. The first two are
      # deploy#1193 (Velero bound to cluster-admin), already in flight and NOT
      # this module's to fix. When #1193 lands, `escalate` and `bind` can come
      # out of this list and the enumeration below stops being defence in
      # depth and becomes a real boundary. That sequencing is the whole reason
      # this rule is written as an explicit concat rather than folded in.
      apiGroups = ["rbac.authorization.k8s.io"]
      resources = ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
      verbs     = concat(local.argocd_controller_verbs, ["escalate", "bind"])
    },
    {
      apiGroups = local.argocd_controller_managed_api_groups
      resources = ["*"]
      verbs     = ["*"]
    },
    {
      apiGroups = local.argocd_controller_readonly_api_groups
      resources = ["*"]
      verbs     = ["get", "list", "watch"]
    },
  ]

  # The watch set, which MUST track the ClusterRole above.
  #
  # ArgoCD's cluster cache discovers every API resource the server exposes and
  # opens a list/watch on each one it is not told to skip. With an enumerated
  # ClusterRole and no inclusion list it would list groups it has no
  # permission for, and a forbidden list during the initial cache load is not
  # a per-group warning — it degrades the whole cluster cache, which shows up
  # as every Application going Unknown. So the two are a matched pair: the
  # controller watches exactly what it is allowed to read.
  #
  # Both lists are built from the same locals precisely so they cannot drift
  # apart in review.
  argocd_controller_resource_inclusions = yamlencode([
    {
      apiGroups = [""]
      kinds     = local.argocd_controller_core_kinds
      clusters  = ["*"]
    },
    {
      apiGroups = ["rbac.authorization.k8s.io"]
      kinds     = ["ClusterRole", "ClusterRoleBinding", "Role", "RoleBinding"]
      clusters  = ["*"]
    },
    {
      apiGroups = local.argocd_controller_managed_api_groups
      kinds     = ["*"]
      clusters  = ["*"]
    },
    {
      apiGroups = local.argocd_controller_readonly_api_groups
      kinds     = ["*"]
      clusters  = ["*"]
    },
  ])
}
