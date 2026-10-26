# ----------------------------------------------------------------------------
# Argo CD installation + App-of-Apps bootstrap. The last stage 1 row
# (ADR-0083 § Where the cluster ends): it installs stage 2.
#
# Two phases inside this module:
#   1. helm_release argo-cd into namespace `argocd`. The chart generates the
#      break-glass admin password itself (`argocd-initial-admin-secret`);
#      nothing here mints or stores a credential. The operator reads it with
#      `kubectl -n argocd get secret argocd-initial-admin-secret` over the
#      same port-forward that reaches the UI.
#   2. kubectl_manifest "app-of-apps" Application pointing at
#      github.com/zeroroot-ai/hosted `path: <var.app_of_apps_path>` (required,
#      gitops/envs/staging | gitops/envs/prod) `targetRevision: <var.git_revision>`
#      (default "main").
#
# After this module applies the App-of-Apps Application, ArgoCD takes over
# everything inside the cluster. Subsequent changes go through the gitops
# repo via PRs (NFR-O1, R6.4).
#
# There is NO Ingress and NO load balancer for the UI. ArgoCD is a
# cluster-admin control plane; operators reach it with
# `kubectl -n argocd port-forward svc/argocd-server 8080:80`, which needs no
# DNS record, no certificate and no exposure decision. The ALB Ingress, the
# ACM certificate and the WAFv2 association that used to sit here were
# deleted with the rest of the AWS control-plane surface (deploy#1744).
# Argo CD Image Updater is gone too: the release loop of ADR-0080 owns
# promotion.
# ----------------------------------------------------------------------------

locals {
  # External base URL of the ArgoCD UI. Dex derives the OAuth/OIDC callback
  # (<url>/api/dex/callback) from this, and argocd-server uses it as its
  # canonical URL. There is no Ingress, so the hostname resolves nowhere
  # public — the SSO round-trip runs over the operator's port-forward.
  argocd_url = "https://argocd.${var.route53_zone_name}"

  # Ops SSO is a PLUGGABLE identity plane, kept SEPARATE from Zitadel (the
  # customer IdP) for blast-radius, and wired only once the operator selects a
  # provider (var.sso_provider != "none"). GitHub is NOT OIDC-compliant, so it
  # MUST route through Dex's github connector; GitLab and generic OIDC route
  # through Dex too for one uniform mechanism. Until a provider is selected the
  # Dex connector is omitted and only local break-glass admin works.
  argocd_sso_enabled = var.sso_provider != "none"

  # One Dex connector per supported provider, selected by var.sso_provider. The
  # OAuth client secret is never inlined here — "$dex.sso.clientSecret" is a Dex
  # secret-reference resolved from the argocd-secret key set in
  # configs.secret.extra below, so the secret stays out of the argocd-cm
  # ConfigMap. (SAML was certificate-based and had no client secret; all three
  # of github/gitlab/oidc do.)
  argocd_dex_connectors = {
    github = {
      type = "github"
      id   = "github"
      name = "GitHub"
      config = {
        clientID      = var.sso_client_id
        clientSecret  = "$dex.sso.clientSecret"
        orgs          = [{ name = var.sso_github_org }]
        teamNameField = "slug"
        loadAllGroups = false
      }
    }
    gitlab = {
      type = "gitlab"
      id   = "gitlab"
      name = "GitLab"
      config = {
        baseURL      = var.sso_base_url
        clientID     = var.sso_client_id
        clientSecret = "$dex.sso.clientSecret"
        useLoginAsID = false
      }
    }
    oidc = {
      type = "oidc"
      id   = "oidc"
      name = "OIDC"
      config = {
        issuer               = var.sso_base_url
        clientID             = var.sso_client_id
        clientSecret         = "$dex.sso.clientSecret"
        redirectURI          = "${local.argocd_url}/api/dex/callback"
        insecureEnableGroups = true
        scopes               = ["openid", "profile", "email", "groups"]
      }
    }
  }

  # Emit ONLY the selected connector. When sso_provider="none" the map index is
  # never evaluated (the ternary short-circuits) and dex.config is omitted from
  # configs.cm below.
  argocd_dex_config = local.argocd_sso_enabled ? yamlencode({
    connectors = [local.argocd_dex_connectors[var.sso_provider]]
  }) : ""
}

# ----------------------------------------------------------------------------
# argo-cd helm release.
# ----------------------------------------------------------------------------

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true

  repository = "oci://ghcr.io/argoproj"
  chart      = "argo-helm/argo-cd"
  version    = var.argocd_chart_version

  values = [
    yamlencode({
      configs = {
        params = {
          # Server runs as TLS terminator behind the public NLB; the
          # Envoy ingress for argocd.zeroroot.ai routes here.
          "server.insecure" = false

          # ServerSideDiff: render manifests via the kube-apiserver dry-run
          # so the diff view matches what kubectl would actually apply.
          # Without this controller-cm key, the "argocd app diff" view
          # double-counts CRD-managed fields and looks perpetually OutOfSync.
          # Per-app sync option ServerSideDiff=true also required; that's
          # set on the App-of-Apps below.
          "controller.diff.server.side" = "true"

          # Bound every sync OPERATION (gitops#495): an op gated on wave
          # health can hang in Running forever, and selfHeal cannot abandon
          # or re-target an in-flight operation — a stale-values op stranded
          # staging 17h. 30m is generous against the slowest observed cold
          # bringup; a hung op past it is terminated, reaches a terminal
          # state, and the next selfHeal drive resolves CURRENT revisions.
          # Failing (not hung) ops are bounded by syncPolicy.retry on the
          # gitops Applications.
          "controller.sync.timeout.seconds" = "1800"
        }
        cm = merge({
          # Annotation-based resource tracking (deploy#1118): controllers
          # like ARC propagate LABELS from their CRs onto runtime-minted
          # children (AutoscalingListener, listener Role/RoleBinding,
          # EphemeralRunners), so label-tracking counts them as extraneous
          # app resources and the app is perpetually OutOfSync. Annotations
          # are not propagated, so annotation tracking ends the drift noise.
          # MUST be annotation+label (not bare annotation): with pure
          # annotation tracking the instance label vanishes from desired
          # state while the SSA apply path still writes it, so ServerSideDiff
          # predicts a label removal that never happens and every previously
          # label-tracked resource is perpetually OutOfSync (live-verified on
          # staging 2026-07-03; +label keeps the label in both paths, and
          # tracking itself is still annotation-decided so ARC noise stays
          # gone).
          "application.resourceTrackingMethod" = "annotation+label"

          # The watch set, pinned to the application-controller's ClusterRole
          # (deploy#1214). Built in controller-rbac.tf from the same locals as
          # the role's rules so the two cannot drift: the controller lists and
          # watches exactly the API groups it is permitted to read, and never
          # attempts a group that would come back forbidden and degrade the
          # whole cluster cache.
          "resource.inclusions" = local.argocd_controller_resource_inclusions

          # ArgoCD canonical external URL. Dex builds the OAuth/OIDC callback
          # (<url>/api/dex/callback) from it, and argocd-server emits correct
          # redirects with it. Correct and harmless even before SSO is wired.
          "url" = local.argocd_url
          },
          # Dex connector for the selected ops SSO provider (github|gitlab|oidc)
          # — rendered only once the operator sets sso_provider and supplies its
          # OAuth app credentials. Omitted otherwise so ArgoCD boots on
          # break-glass admin with no idle/broken connector. See
          # RUNBOOK-argocd-sso.md.
        local.argocd_sso_enabled ? { "dex.config" = local.argocd_dex_config } : {})
        rbac = {
          # Default DENY for any authenticated identity that is not explicitly
          # granted a role (deploy#1191). ArgoCD's built-in default is
          # `role:readonly`, which would give every future SSO-authenticated
          # user read of every Application — including their live manifests,
          # and therefore Secret NAMES and the repo-creds wiring. `admin` is a
          # superuser independent of this key, so tightening it is safe.
          "policy.default" = ""

          # SSO grant: the admin group carried in the groups claim via the Dex
          # connector above → ArgoCD role:admin. role:admin is app-level
          # superuser within ArgoCD, still bounded by the narrowed
          # argocd-server/controller ClusterRoles (server-rbac.tf /
          # controller-rbac.tf) — so this grants no cluster capability beyond
          # those scoped roles. The subject format depends on the provider:
          # github → "<org>:<team-slug>" (e.g. zeroroot-ai:platform-admins);
          # gitlab → the group path; oidc → the raw group claim value. Confirm
          # against what the provider emits per RUNBOOK-argocd-sso.md. Inert
          # until the connector is wired (no SSO identity can authenticate).
          #
          # No local API account exists. No workflow calls the Argo CD API
          # (hosted#407).
          "policy.csv" = <<-CSV
            p, role:readonly-apps, applications, get, */*, allow
            g, ${var.sso_admin_group}, role:admin
          CSV
        }
        # Local admin is BREAK-GLASS, not the primary login: operators sign
        # in through the pluggable github|gitlab|oidc SSO (Dex connector +
        # policy.csv group grant above). No argocdServerAdminPassword is set,
        # so the chart generates one and writes it to the in-cluster
        # argocd-initial-admin-secret — the operator reads it over the same
        # port-forward that reaches the UI, and no copy exists outside the
        # cluster (ADR-0083: the cluster is disposable, and so is this
        # credential).
        #
        # The `extra` key delivers the OAuth client secret into argocd-secret
        # under the key the Dex connector references as
        # "$dex.sso.clientSecret". Present only when a provider is selected.
        secret = local.argocd_sso_enabled ? {
          extra = { "dex.sso.clientSecret" = var.sso_client_secret }
        } : {}
      }

      controller = {
        # Replaces the chart's default application-controller ClusterRole,
        # which is `*` on `*` cluster-wide plus every nonResourceURL
        # (deploy#1214). Rules and rationale in controller-rbac.tf.
        clusterRoleRules = {
          enabled = true
          rules   = local.argocd_controller_cluster_role_rules
        }

        nodeSelector = {
          workload = "system" # ArgoCD runs on system nodegroup (arm64-tolerant).
        }
        tolerations = [{
          key      = "workload"
          operator = "Equal"
          value    = "system"
          effect   = "NoSchedule"
        }]
      }

      server = {
        # Replaces the chart's default argocd-server ClusterRole, which is
        # delete/get/patch/list on `*`/`*` cluster-wide — i.e. read of every
        # Secret in the cluster (deploy#1236). Rules and rationale in
        # server-rbac.tf; the group lists are shared with controller-rbac.tf.
        clusterRoleRules = {
          enabled = true
          rules   = local.argocd_server_cluster_role_rules
        }

        nodeSelector = {
          workload = "system"
        }
        tolerations = [{
          key      = "workload"
          operator = "Equal"
          value    = "system"
          effect   = "NoSchedule"
        }]
      }

      repoServer = {
        nodeSelector = {
          workload = "system"
        }
        tolerations = [{
          key      = "workload"
          operator = "Equal"
          value    = "system"
          effect   = "NoSchedule"
        }]
      }

      global = {
        # Every image from the org mirror, pinned by digest, as on kind
        # (bootstrap/kind/gibson/operators.tf): the tags that argo-cd chart
        # ${var.argocd_chart_version} ships. Moving the chart version means
        # mirroring its new tags first (.github mirror-list.yaml).
        image = {
          repository = "ghcr.io/zeroroot-ai/mirror/argocd"
          tag        = "v3.5.6@sha256:8e5cc5bb008df8a09dba439462e58c94c55b7735888d3ebde0c25fc05e4e5335"
        }
        # Chart 10 creates its own NetworkPolicies by default. This
        # environment ran without them on chart 8, and the upgrade changes the
        # Argo CD version only.
        networkPolicy = {
          create = false
        }
      }
      dex = {
        image = {
          repository = "ghcr.io/zeroroot-ai/mirror/dex"
          tag        = "v2.46.1@sha256:65b72ca0f4b0bf6d4ada84ec21da8851782563404ac7b8f926923d27ceced9ab"
        }
      }
      redis = {
        image = {
          repository = "ghcr.io/zeroroot-ai/mirror/redis"
          tag        = "8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763"
        }
      }
    })
  ]

  lifecycle {
    # Per-provider required-var checks (cross-variable, so they cannot live in a
    # single variable {} validation block). github gates admin on org/team
    # membership, so it needs the org; gitlab/oidc need the endpoint.
    precondition {
      condition     = var.sso_provider != "github" || var.sso_github_org != ""
      error_message = "sso_provider=github requires sso_github_org (the GitHub org whose team membership gates admin)."
    }
    precondition {
      condition     = !contains(["gitlab", "oidc"], var.sso_provider) || var.sso_base_url != ""
      error_message = "sso_provider=gitlab requires sso_base_url (the GitLab base URL); sso_provider=oidc requires sso_base_url (the OIDC issuer URL)."
    }
  }
}

# ----------------------------------------------------------------------------
# ArgoCD credentials are no longer Terraform-owned (ADR-0083, no secret in
# state). The repo-creds Secret (zeroroot-ai-creds) is seeded by
# scripts/keyring-to-cluster.sh from the org GitHub App, so ArgoCD mints and
# refreshes its own installation tokens and no PAT ever lands in Terraform
# state. The umbrella chart's OCI package (ghcr.io/zeroroot-ai/charts/gibson)
# is public, so the repo-server pulls the chart anonymously — no ghcr
# repository credential is needed. kind seeds neither (it syncs from the
# bucket); see scripts/check-kind-terraform-no-seed.py.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# App-of-Apps Application.
# ----------------------------------------------------------------------------

resource "kubectl_manifest" "app_of_apps" {
  # Absent for exactly one window, inside a restore: the secret store comes
  # back before the platform Application exists (ADR-0083, deploy#1746). The
  # recreate verb re-applies this root with the default to create it.
  count = var.app_of_apps_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "app-of-apps"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io"
      ]
    }
    spec = {
      # Scoped to the bootstrap project (deploy#1214): this Application may
      # only write Application CRs into the argocd namespace, from the gitops
      # repo, and may not apply any cluster-scoped resource. See
      # appprojects.tf.
      project = "platform-bootstrap"
      source = {
        repoURL        = var.git_repo_url
        targetRevision = var.git_revision
        path           = var.app_of_apps_path
        directory = {
          # envs/<env>/ (post single-main collapse) holds top-level *.yaml
          # Application CRs — but ALSO plain Helm values files (values.yaml,
          # saas-overlay-*-values.yaml) that are NOT manifests: Argo's
          # directory source parses every unexcluded .yaml and lands the
          # whole app-of-apps in ComparisonError on the first one with no
          # apiVersion/kind. Exclude them. Do NOT recurse — envs/<env>/
          # manifests/ stores per-Application manifest payloads (referenced
          # by child Applications' source.path), and recursing picks up
          # CRD-typed resources before their CRDs are installed.
          recurse = false
          exclude = "{README.md,*/README.md,values.yaml,*-values.yaml}"
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      # THE ONE PER-RUN SEAM (D91). A restore sets three Postgres recovery
      # values, derived from the named backup, as Helm parameters on the
      # gibson Application (scripts/lib/restore-recovery.sh). Without this
      # entry, selfHeal would put the Application back to Git and the
      # recovered cluster would archive into the directory it recovered
      # from. scripts/check-app-of-apps-ignore.py fails any other entry.
      ignoreDifferences = [
        {
          group        = "argoproj.io"
          kind         = "Application"
          name         = "gibson"
          jsonPointers = ["/spec/sources/0/helm/parameters"]
        },
      ]
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "PrunePropagationPolicy=foreground",
          # The ignored path above is also left alone on a sync, not only in
          # the diff (D91).
          "RespectIgnoreDifferences=true",
          # ServerSideDiff: pairs with configs.params."controller.diff.server.side"=true
          # in the helm release. Required for the per-app diff to use the
          # kube-apiserver dry-run output instead of client-side diff.
          "ServerSideDiff=true",
        ]
        retry = {
          limit = 5
          backoff = {
            duration    = "30s"
            factor      = 2
            maxDuration = "10m"
          }
        }
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.project_platform_bootstrap,
  ]
}
