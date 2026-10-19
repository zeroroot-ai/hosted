# ----------------------------------------------------------------------------
# AppProjects — the scope boundary on what ArgoCD may deploy (deploy#1214).
#
# WHY THIS FILE EXISTS
#
# Until this file landed, every Application in this cluster ran in the
# stock `default` AppProject, which ArgoCD's server auto-creates with
#
#     sourceRepos:              ['*']
#     destinations:             [{server: '*', namespace: '*'}]
#     clusterResourceWhitelist: [{group: '*', kind: '*'}]
#
# — i.e. no scope at all. Combined with the application-controller's
# cluster-admin ClusterRole, merge access to the gitops repo was merge access
# to the whole cluster: an Application could be pointed at any repo, target
# any namespace, and apply any cluster-scoped kind, including a
# ClusterRoleBinding onto cluster-admin. That is the real platform identity
# boundary — not SPIFFE, which sits below it and cannot constrain the
# principal that writes SPIFFE's own configuration.
#
# WHY `default` IS HARDENED IN PLACE RATHER THAN REPLACED
#
# All Applications under gitops/envs/ hard-code `project: default`
# (envs/<env>/gibson.yaml, envs/<env>/root.yaml, envs/<env>/apps/*.yaml, and
# staging's envs/staging/arc-*.yaml). Introducing a differently-named project
# here without a lockstep change in that repo would leave every one of them in
# an unrestricted `default` and change nothing. So `default` is adopted and given
# a real scope, derived below from what those Applications actually deploy.
# Moving them onto purpose-named projects is a follow-up that has to be a
# gitops-repo change; this file makes that flip a one-word edit per Application
# because the scope will already be correct.
#
# The one Application this module owns — the bootstrap app-of-apps — does move
# now, onto `platform-bootstrap`, because nothing outside this module
# references it.
#
# HOW THE WHITELISTS WERE DERIVED
#
# Not guessed. `helm template` of helm/gibson (the umbrella this cluster runs)
# plus helm/saas-overlay/* against the gitops env overlays renders 326 objects.
# Their cluster-scoped kinds are exactly the baseline
# clusterResourceWhitelist below; their namespaces are exactly the baseline
# destinations below; the repos the Applications name in spec.source(s) are
# exactly the baseline sourceRepos below. Anything outside those sets is a new
# deployment shape that should require a reviewed change — either to this file
# (if every env renders it) or to eks/gibson/envs/<env>.tfvars (if one does).
#
# The two ARC charts, which only staging runs, were rendered the same way at
# the pinned 0.14.2. They add no cluster-scoped kind that the platform does not
# already need — a ClusterRole, a ClusterRoleBinding and their CRDs — only
# namespaces and one source repo, both supplied per-env.
# ----------------------------------------------------------------------------

locals {
  # In-cluster destination. ArgoCD registers exactly one cluster (itself);
  # naming it explicitly denies any future externally-registered cluster.
  argocd_in_cluster_server = "https://kubernetes.default.svc"

  # Namespaces the gitops Applications legitimately target.
  #   argocd  — envs/<env>/root.yaml and the bootstrap app-of-apps write child
  #             Application CRs here.
  #   gibson  — the umbrella chart's release namespace and the namespace all
  #             three SaaS-overlay Applications deploy into.
  #   zitadel — the umbrella renders a Namespace plus a ServiceAccount, Role
  #             and RoleBinding (gibson-zitadel-admin-reader) here.
  #   velero  — gibson-velero is a SECOND release in its own namespace, and it
  #             is an Application in every env since gitops#564. The Velero
  #             server reads its kopia repository password through a cache
  #             restricted to the namespace it runs in, which is why the
  #             release is not in `gibson` (deploy#1762). Missing, the whole
  #             Application is refused before it syncs a single object:
  #             "application destination server ... and namespace 'velero' do
  #             not match any of the allowed destinations in project
  #             'default'" (measured on staging, deploy#1746).
  #   spire-system — the namespace of the SPIRE agent and the SPIFFE CSI
  #             driver, with the named privileged Pod Security exception of
  #             ADR-0165 (charts#639, hosted#438). The umbrella renders the
  #             Namespace, the two DaemonSets, a Role and a default deny here.
  #             Missing, the gibson app sync aborts "namespace spire-system
  #             is not permitted in project", as setec-sandboxes did.
  #   kube-system — the umbrella's cert-manager subchart renders its
  #             leader-election RoleBinding here, as every cert-manager
  #             release does. Missing, the gibson app sync aborts
  #             "namespace kube-system is not permitted in project 'default'"
  #             (measured on staging, deploy#1746) — the same shape as the
  #             setec-sandboxes miss below.
  # Per-tenant namespaces are deliberately absent: the tenant operator mints
  # those at runtime, ArgoCD never applies into them.
  #
  # Env-specific namespaces are appended from var.extra_platform_namespaces
  # (eks/gibson/envs/<env>.tfvars, deploy#1397). Staging supplies four, for
  # the ephemeral GitHub Actions runners and for setec:
  #   arc-systems  — gha-runner-scale-set-controller destination.
  #   arc-runners  — gha-runner-scale-set destination plus the ServiceAccount
  #                  and ExternalSecret in envs/staging/manifests/arc-runners/.
  #   setec-system — the Role and RoleBinding that same manifests directory
  #                  grants the runner SA so KVM e2e can drive setec.
  #   setec-sandboxes — the sandbox namespace (setec.sandboxNamespaces): the
  #                  umbrella renders the baseline-deny NetworkPolicy and the
  #                  operator's namespace-scoped Pod-write RoleBinding here.
  #                  Missing, the gibson app sync aborted "namespace
  #                  setec-sandboxes is not permitted in project" (deploy#1429).
  argocd_platform_namespaces = concat(
    [
      "argocd",
      "gibson",
      "zitadel",
      "velero",
      "spire-system",
      "kube-system",
    ],
    var.extra_platform_namespaces,
  )

  # Every repo named in a spec.source(s).repoURL across this env's Applications.
  #   hosted — the Application CRs themselves, the $values ref, and the SaaS
  #            overlay charts under gitops/saas-overlay/ (ADR-0086).
  #   ghcr charts — the versioned OCI umbrella chart
  #                 (gitops/envs/<env>/gibson.yaml source[0]).
  # Third-party sources are per-env and come from
  # var.extra_platform_source_repos: staging names exactly one, the upstream
  # actions-runner-controller OCI Helm repo.
  argocd_platform_source_repos = concat(
    [
      "https://github.com/zeroroot-ai/hosted",
      "ghcr.io/zeroroot-ai/charts",
    ],
    var.extra_platform_source_repos,
  )

  # Cluster-scoped kinds rendered by the umbrella + SaaS overlays. One entry
  # per kind actually present in the render — NOT one entry per kind whose CRD
  # is installed. Installing the velero.io or postgresql.cnpg.io CRDs does not
  # oblige ArgoCD to be able to apply their cluster-scoped variants, and none
  # of them are rendered as CRs.
  argocd_platform_cluster_resources = concat(local.argocd_baseline_cluster_resources, var.extra_cluster_resources)

  argocd_baseline_cluster_resources = [
    # Created by CreateNamespace=true and by the umbrella's `zitadel` Namespace.
    { group = "", kind = "Namespace" },
    # 45 CRDs: gibson.zeroroot.ai, monitoring.coreos.com, postgresql.cnpg.io,
    # spire.spiffe.io, velero.io.
    { group = "apiextensions.k8s.io", kind = "CustomResourceDefinition" },
    # 15 ClusterRoles / 13 ClusterRoleBindings (cnpg, velero, both operators,
    # reloader, prometheus, promtail, spire agent/server, dashboard,
    # sandbox-eviction-handler).
    { group = "rbac.authorization.k8s.io", kind = "ClusterRole" },
    { group = "rbac.authorization.k8s.io", kind = "ClusterRoleBinding" },
    # cnpg + spire admission webhooks.
    { group = "admissionregistration.k8s.io", kind = "MutatingWebhookConfiguration" },
    { group = "admissionregistration.k8s.io", kind = "ValidatingWebhookConfiguration" },
    # CEL ValidatingAdmissionPolicy + Binding: gibson's platform-identity
    # guards (pods, workloads) and setec's sandbox-host-guard /
    # runtime-agent-node-guard. Cluster-scoped; missing here also aborted the
    # gibson app sync (deploy#1429).
    { group = "admissionregistration.k8s.io", kind = "ValidatingAdmissionPolicy" },
    { group = "admissionregistration.k8s.io", kind = "ValidatingAdmissionPolicyBinding" },
    # 3 PriorityClasses (spire agent/server, platform workloads).
    { group = "scheduling.k8s.io", kind = "PriorityClass" },
    # spire's CSI driver.
    { group = "storage.k8s.io", kind = "CSIDriver" },
    { group = "cert-manager.io", kind = "ClusterIssuer" },
    { group = "external-secrets.io", kind = "ClusterSecretStore" },
    # The cluster-wide Cilium policies of the chart (D76).
    { group = "cilium.io", kind = "CiliumClusterwideNetworkPolicy" },
    # 15 ClusterSPIFFEIDs from the umbrella + 1 from the entitlements-svc overlay.
    { group = "spire.spiffe.io", kind = "ClusterSPIFFEID" },
    # The cluster-scoped PlatformBootstrap CR that drives platform bringup.
    { group = "gibson.zeroroot.ai", kind = "PlatformBootstrap" },
    # Anything only ONE env renders is appended from var.extra_cluster_resources
    # (deploy#1397). Staging supplies the setec pair — the umbrella renders the
    # cluster-scoped kata RuntimeClasses (kata-fc, kata-qemu) and the
    # SandboxClasses (tool, connector) when setec is enabled (deploy#1080).
    # Their absence blocked the gibson app sync with "resource ... is not
    # permitted in project default" (deploy#1429/#1431) — this AppProject
    # allowlist is a second gate beyond the controller's resource.inclusions
    # (controller-rbac.tf).
  ]
}

# ----------------------------------------------------------------------------
# `default` — the scope every gitops-declared Application inherits today.
#
# server_side_apply + force_conflicts because argocd-server's
# initializeDefaultProject() creates this object on first start and never
# updates it again. SSA adopts whichever copy exists rather than failing the
# apply with AlreadyExists, and works identically whether Terraform or the
# server got there first.
# ----------------------------------------------------------------------------

resource "kubectl_manifest" "project_default" {
  server_side_apply = true
  force_conflicts   = true

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "default"
      namespace = "argocd"
    }
    spec = {
      description = "Platform scope for the zeroroot-ai/hosted Applications. Whitelists are derived from the rendered umbrella + SaaS-overlay charts; see appprojects.tf."

      sourceRepos = local.argocd_platform_source_repos

      destinations = [
        for ns in local.argocd_platform_namespaces : {
          server    = local.argocd_in_cluster_server
          namespace = ns
        }
      ]

      clusterResourceWhitelist = local.argocd_platform_cluster_resources

      # Namespaced kinds are left open. They are already confined by
      # `destinations` above — an Application in this project cannot write a
      # namespaced object outside argocd/gibson/zitadel whatever its kind — and
      # enumerating ~40 namespaced kinds across ten API groups would turn every
      # future chart addition into a silent, hard-to-diagnose sync failure for
      # no additional containment. The two exceptions below are not about
      # containment-by-kind, they close a privilege-escalation path.
      namespaceResourceWhitelist = [{ group = "*", kind = "*" }]

      namespaceResourceBlacklist = [
        # An Application in this project writes into the argocd namespace (that
        # is how envs/<env>/root.yaml works). Without this entry it could write
        # an AppProject there — a wildcard one — and then an Application bound
        # to it, escaping every restriction above. AppProjects are owned by
        # this Terraform module and by nothing else, so denying the kind costs
        # nothing.
        { group = "argoproj.io", kind = "AppProject" },
        # Same escalation, one step longer: an ApplicationSet generates
        # Applications and can set their spec.project. Nothing in
        # the Argo tree declares an ApplicationSet (verified across every
        # Application under gitops/envs/), so this denies an unused path.
        { group = "argoproj.io", kind = "ApplicationSet" },
      ]
    }
  })

  depends_on = [helm_release.argocd]
}

# ----------------------------------------------------------------------------
# `platform-bootstrap` — the bootstrap app-of-apps only.
#
# This Application's entire job is to lay down other Application CRs in the
# argocd namespace from one repo. It has no business applying a ClusterRole, a
# CRD, or anything at all outside `argocd` — so it gets none of that.
# clusterResourceWhitelist is empty, which in ArgoCD means "no cluster-scoped
# resource may be applied", not "all".
# ----------------------------------------------------------------------------

resource "kubectl_manifest" "project_platform_bootstrap" {
  server_side_apply = true
  force_conflicts   = true

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "platform-bootstrap"
      namespace = "argocd"
    }
    spec = {
      description = "Terraform-owned bootstrap app-of-apps. Writes Application CRs into the argocd namespace and nothing else."

      sourceRepos = [var.git_repo_url]

      destinations = [{
        server    = local.argocd_in_cluster_server
        namespace = "argocd"
      }]

      # Namespace and nothing else. The app-of-apps carries
      # CreateNamespace=true, and ArgoCD runs the managed-namespace object
      # through the same project permission validator as any other resource
      # whenever it decides the namespace needs creating or its metadata
      # updating. The `argocd` namespace is created ahead of this Application
      # by helm_release.argocd (create_namespace = true), so that branch
      # should never be taken — but "should never" is a poor thing to stake
      # cluster bootstrap on, and the privilege being granted is the ability
      # to create an empty namespace this project may then put nothing into.
      clusterResourceWhitelist = [
        { group = "", kind = "Namespace" },
      ]

      # Applications only. Notably NOT AppProject: this project must not be
      # able to widen itself or mint a permissive sibling.
      namespaceResourceWhitelist = [
        { group = "argoproj.io", kind = "Application" },
      ]
    }
  })

  depends_on = [helm_release.argocd]
}
