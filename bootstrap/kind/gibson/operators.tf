# ----------------------------------------------------------------------------
# Stage 1 on kind installs Argo CD and nothing else (ADR-0083, deploy#1728).
#
# cert-manager, external-secrets, external-dns and the CloudNativePG operator
# are subcharts of the gibson umbrella, which Argo syncs as stage 2. The
# helm_releases that used to sit here for ESO, cert-manager and CNPG are gone
# with the seam that selected them (`cnpg.enabled`), and
# scripts/check-no-operator-helm-release.py fails CI if one comes back.
#
# There is no kind secret backend any more (ADR-0083, deploy#1732): the
# openbao-auto-init sidecar seeds the platform's OpenBao, credentials.tf is
# deleted, and scripts/check-kind-terraform-no-seed.py fails the build if a
# seed producer comes back. The bringup keyring reaches the cluster through
# scripts/keyring-to-cluster.sh, run by `make recreate ENV=kind`
# (deploy#1737); keyring.tf is deleted.
#
# wait = true so Terraform does not return until Argo is Running.
# ----------------------------------------------------------------------------

# The release namespace. The bringup keyring Secret (written by
# scripts/keyring-to-cluster.sh during a recreate) lives here, and the
# umbrella syncs into it.
resource "kubernetes_namespace_v1" "gibson" {
  metadata {
    name = "gibson"
  }
}

# ============================================================================
# ArgoCD
# ============================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  wait             = true
  timeout          = 300

  values = [yamlencode({
    configs = {
      cm = {
        # ARGO DECIDES OWNERSHIP BY ANNOTATION, NOT BY LABEL (deploy#1739).
        #
        # Argo's default tracking method is `label`: it owns every live
        # resource carrying app.kubernetes.io/instance = <application name>.
        # A controller that COPIES that label onto objects it creates
        # therefore hands Argo ownership of them. Velero does exactly that:
        # it copies a Schedule's labels and annotations onto every Backup it
        # creates from that Schedule. Measured on kind 2026-09-02: the velero
        # Application reported OutOfSync forever with one extraneous resource,
        # a Backup the server had just synced from the durable bucket, and
        # `prune: true` would have DELETED the platform's backups.
        #
        # Annotation tracking carries the resource's own group, kind, name and
        # namespace inside the tracking id, and Argo refuses an id that does
        # not describe the object holding it. A copied id is then inert, for
        # any controller and any kind, including objects written before this
        # setting existed. That is why it is the root fix, and the
        # IgnoreExtraneous annotation on the Schedule in helm/gibson-velero is
        # the second half: it travels with the CHART to substrates whose Argo
        # this workspace does not install.
        "application.resourceTrackingMethod" = "annotation"
      }
      params = {
        # ServerSideDiff controller gate — pairs with per-app ServerSideDiff=true
        # syncOption. Without this key, the per-app option is silently ignored
        # and StatefulSet/Deployment/ExternalSecret manifests drift permanently
        # on k8s server-side default-fill. Replaces the inline `kubectl patch`
        # in `make argo-install` (deploy#369, gitops#93).
        "controller.diff.server.side" = "true"
        "server.insecure"             = "true"
      }
    }
    global = {
      # kind dev: no node affinity constraints.
      nodeSelector = {}
      tolerations  = []
      # Every image from the org mirror, pinned by digest, like every other
      # image this repo installs. Pulled from upstream, the Redis image hit
      # public ECR's rate limit ("429 Too Many Requests: Data limit
      # exceeded") and the release timed out: five exit-test runs lost on
      # 2026-09-27 (hosted#235). The tags are the ones argo-cd chart
      # ${var.argocd_version} ships. Moving the chart version means mirroring
      # its new tags first (.github mirror-list.yaml).
      image = {
        repository = "ghcr.io/zeroroot-ai/mirror/argocd"
        tag        = "v3.0.11@sha256:1cb4ede2fc4a6332c128d9ba29d19e8cb5b76f9260dc47550a4b3b154269ff86"
      }
    }
    dex = {
      image = {
        repository = "ghcr.io/zeroroot-ai/mirror/dex"
        tag        = "v2.43.1@sha256:0881d3c9359b436d585b2061736ce271c100331e073be9178ef405ce5bf09557"
      }
    }
    redis = {
      image = {
        repository = "ghcr.io/zeroroot-ai/mirror/redis"
        tag        = "7.2.8-alpine@sha256:c88ea2979a49ca497bbf7d39241b237f86c98e58cb2f6b1bc2dd167621f819bb"
      }
    }
  })]
}

# No repository credential lives here (deploy#1737). Stage 2 on kind syncs
# from the charts/ prefix of the durable bucket, which Argo reads with a
# plain anonymous GET on the kind Docker network (scripts/recreate-kind.sh).
# The old `zeroroot-ai-creds` and `ghcr-charts-oci` Secrets served the
# retired gitops dev root; they left with kind-up, as
# scripts/check-kind-terraform-no-seed.py documents.

# SPIRE is intentionally absent from this workspace.
# ArgoCD installs it as part of the umbrella (spire-crds in gibson-crds,
# spire in the gibson chart). A Terraform-owned SPIRE in a separate namespace
# would create a second trust domain root on the same cluster.
