# ----------------------------------------------------------------------------
# argocd-server ClusterRole (deploy#1236, split out of #1214).
#
# The argo-cd chart's default argocd-server ClusterRole is
#
#     - apiGroups: ['*']   resources: ['*']   verbs: [delete, get, patch, list]
#
# plus events create/list, pods + pods/log get, batch/jobs create and
# argoproj.io/workflows create (argo-cd/templates/argocd-server/
# clusterrole.yaml, taken whenever server.clusterRoleRules.enabled is false —
# which it was, nothing in this repo ever set it). `get`/`list` on `*`/`*`
# cluster-wide means the server — the component behind the web UI and the
# API, the most network-reachable part of the ArgoCD control plane, guarded
# today by a single shared local admin password with no MFA — can read every
# Secret in every namespace: the OpenBao credentials, the Zitadel system key,
# the platform Postgres superuser password, the tenant secrets, the GitHub
# PAT. `delete`/`patch` on `*`/`*` means it can also remove or mutate any
# object in the cluster.
#
# THE REPLACEMENT
#
# The same enumerated API-group set controller-rbac.tf derived from the
# rendered manifests (see HOW THE SET WAS DERIVED there — these rules reuse
# its locals precisely so the two roles cannot drift apart in review), with
# the chart's own server verb set: delete/get/patch/list, i.e. UI
# affordances, not apply. The server does not sync, so unlike the controller
# it gets no `escalate`/`bind`, no create/update/deletecollection, and no
# watch outside Application/ApplicationSet. Secret read within the
# platform's own namespaces remains — unavoidable for a tool whose job is
# diffing rendered manifests against live state — but kube-system and every
# API group the platform does not deploy leave the server's reach.
#
# Deliberately DROPPED from the chart default (deploy#1236):
#   - batch `jobs` create            — the "create Job from CronJob" UI button
#   - argoproj.io `workflows` create — the "retry Argo Workflow" UI button
# Neither affordance is used today. Restoring one is a one-rule addition
# here, not a chart-default revert.
#
# REVERTING
#
# One value: set server.clusterRoleRules.enabled back to false in main.tf.
# The failure signature this narrowing produces is UI degradation, not sync
# failure: a resource shows as Unknown in the tree, a 403 toast on a live
# manifest view, or a refused delete/patch of a kind in a group missing from
# the lists in controller-rbac.tf.
# ----------------------------------------------------------------------------

locals {
  # The chart default's verb set for its `*`/`*` rule, unchanged; only the
  # group scope shrinks. No create/update/watch: the server renders and
  # mutates single live objects on operator action, it does not apply
  # manifests or maintain the cluster cache (the resource tree it shows
  # comes from the application-controller via Redis).
  argocd_server_verbs = ["delete", "get", "patch", "list"]

  argocd_server_cluster_role_rules = [
    {
      # Same core-resource enumeration as the controller: pods/exec and
      # every other subresource stay out (`resources: ['*']` covers
      # subresources, an explicit list does not). pods/log is granted
      # separately below, get-only, matching the chart default.
      apiGroups = [""]
      resources = local.argocd_controller_core_resources
      verbs     = local.argocd_server_verbs
    },
    {
      # No `escalate`/`bind` here, on purpose: the controller holds them
      # because it must APPLY the platform's privileged RBAC objects. The
      # server only offers delete/patch of live objects in the UI, and a
      # patch that would grant privileges the server does not itself hold
      # is exactly what Kubernetes' escalation-prevention rule should
      # refuse.
      apiGroups = ["rbac.authorization.k8s.io"]
      resources = ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
      verbs     = local.argocd_server_verbs
    },
    {
      apiGroups = local.argocd_controller_managed_api_groups
      resources = ["*"]
      verbs     = local.argocd_server_verbs
    },
    {
      # Owner-ref children in resource trees (EndpointSlices under a
      # Service, ACME Orders/Challenges under a Certificate): visible in
      # the UI, never deletable or patchable from it. Read-only for the
      # controller, read-only here.
      apiGroups = local.argocd_controller_readonly_api_groups
      resources = ["*"]
      verbs     = ["get", "list"]
    },
    # The chart default's UI-support rules, kept verbatim.
    {
      apiGroups = [""]
      resources = ["events"]
      verbs     = ["list", "create"] # event feed in the UI; the server records events
    },
    {
      apiGroups = [""]
      resources = ["pods", "pods/log"]
      verbs     = ["get"] # pod-logs view in the UI
    },
    {
      # The API/UI reads and mutates Application/ApplicationSet CRs
      # directly: `update` carries sync, rollback and spec edits, `watch`
      # streams app changes to the UI. delete/patch on these already
      # arrive via the managed-groups rule above (argoproj.io is in it).
      apiGroups = ["argoproj.io"]
      resources = ["applications", "applicationsets"]
      verbs     = ["get", "list", "update", "watch"]
    },
  ]
}
