#!/usr/bin/env bash
# install-chart.sh — install the PUBLISHED OCI umbrella chart the customer way.
#
# The EKS estate installs the chart through Argo (bootstrap/eks/gibson). This
# verb is the other consumer path: a plain `helm upgrade --install` of the
# signed, versioned OCI artifact a customer installs, so "the published chart
# installs" is proven by a hosted verb, not only by Argo.
#
# The platform is FOUR ordered OCI releases (charts publish-umbrella-chart.yml):
# gibson-operator-crds, then gibson-crds, then the gibson umbrella (operators +
# workloads), then gibson-velero. Each is pulled from the registry at the same
# version.
#
# The CRDs are two releases, not one, since charts#82. gibson-crds alone
# exceeded the 1 MiB cap on the Helm release record, which is a single Secret,
# so `helm install gibson-crds` failed on every cluster while `helm template`
# and Argo both stayed green — neither writes a release record. Splitting the
# operator CRDs out of it is what brought the record back under the cap.
#
# Preconditions the caller owns (this verb does not seed them):
#   - a reachable cluster (KUBECONFIG), with a registry pull credential for the
#     private first-party images (the App path on EKS, or a mirror the customer
#     controls). kind cannot pull the private published images, so this verb
#     targets EKS or a customer cluster, never the kind dev cluster.
#   - the bringup secrets seeded (scripts/keyring-to-cluster.sh), exactly as a
#     recreate seeds them, so the chart's ExternalSecrets resolve.
#
# Usage: install-chart.sh <chart-version> [values-file]
# Env:   NS         release namespace (default gibson)
#        REGISTRY   OCI registry host prefix (default ghcr.io/zeroroot-ai/charts)
set -euo pipefail

VERSION="${1:?usage: install-chart.sh <chart-version> [values-file]}"
VALUES="${2:-}"
NS="${NS:-gibson}"
REGISTRY="${REGISTRY:-ghcr.io/zeroroot-ai/charts}"

log() { printf '\033[1;32m▶\033[0m %s\n' "$*"; }

command -v helm >/dev/null || { echo "helm is required" >&2; exit 2; }

VALUES_ARGS=()
[ -n "$VALUES" ] && { [ -r "$VALUES" ] || { echo "values file $VALUES not readable" >&2; exit 2; }; VALUES_ARGS=(-f "$VALUES"); }

# CRDs first — a CRD and a CR of it cannot land in one Helm release.
log "install gibson-operator-crds $VERSION -> namespace $NS"
helm upgrade --install gibson-operator-crds "oci://${REGISTRY}/gibson-operator-crds" \
  --version "$VERSION" --namespace "$NS" --create-namespace --wait

log "install gibson-crds $VERSION -> namespace $NS"
helm upgrade --install gibson-crds "oci://${REGISTRY}/gibson-crds" \
  --version "$VERSION" --namespace "$NS" --create-namespace --wait

log "install gibson (operators + workloads) $VERSION -> namespace $NS"
helm upgrade --install gibson "oci://${REGISTRY}/gibson" \
  --version "$VERSION" --namespace "$NS" "${VALUES_ARGS[@]}" --wait

log "install gibson-velero $VERSION -> namespace $NS"
helm upgrade --install velero "oci://${REGISTRY}/gibson-velero" \
  --version "$VERSION" --namespace "$NS" --wait

log "published chart $VERSION installed into $NS"
