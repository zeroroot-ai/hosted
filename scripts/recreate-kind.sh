#!/usr/bin/env bash
# recreate-kind.sh — the recreate verb for ENV=kind (ADR-0083,
# deploy#1737). `make recreate ENV=kind` runs preflight and then this script.
#
# A recreate stands the environment up from nothing (docs/bringup.md § A
# recreate, step by step). When the kind cluster already exists, recreate
# deletes it first: that is the semantics, not a convenience.
#
#   Stage 1  the cluster: kind with /dev/kvm of the host mounted into the node
#            (the setec launcher needs it, ADR-0083), Cilium, and Argo CD
#            from the kind Terraform (bootstrap/kind/gibson). kind itself
#            provides local-path storage. This stage writes the bringup
#            keyring into the cluster (scripts/keyring-to-cluster.sh) — the
#            job the interim producers did until deploy#1737.
#   Stage 2  the platform: the gibson umbrella and the gibson-velero release
#            as Argo CD Applications, synced to Synced+Healthy. The charts
#            come from THIS checkout: the script builds the dependency chain
#            bottom-up, packages gibson-crds, gibson and gibson-velero, and
#            publishes them as a plain Helm repository under the charts/
#            prefix of the durable bucket (anonymous read, set by stage 0).
#            Argo pulls them from there, so a recreate proves the checkout's
#            charts and needs no chart registry and no pushed branch.
#
# RESTORE_FROM=<name> is the restore half (deploy#1739). It restores exactly
# the backup named on the command line and nothing else. With NO name every
# store bootstraps empty, always, even when the bucket holds a hundred
# backups (ADR-0083). There is no `latest`, no auto-detect and no default
# that turns the restore on.
#
# The restore is woven into stage 2 at three points, and the order is not
# negotiable (docs/bringup.md § A recreate, step by step):
#
#   1. the secret store FIRST. The OpenBao archive rides in the same Velero
#      backup as everything else (the Schedule takes the `gibson` namespace
#      whole, volumes included), so it is restored by an OpenBao-only
#      Restore before the umbrella Application exists. The StatefulSet then
#      adopts the restored claim, and the static seal unseals the store from
#      the keyring with no human step.
#   2. External Secrets syncs every Secret out of the restored store. The
#      recreate WAITS for that. A Velero restore that lands a tenant Neo4j
#      pod before its auth Secret exists leaves it in
#      CreateContainerConfigError, so the wait is a gate and not a courtesy.
#   3. the Velero restore proper, in two passes: everything except the
#      cluster-scoped `Tenant` CRs, then the `Tenant` CRs. The tenant
#      operator ADOPTS a restored Neo4j claim rather than re-initialising
#      it, so the built-ins have to be on disk before the CRs arrive.
#
# Postgres is not in that backup: it comes back through its own barman
# archive. The recreate reads the CNPG `Backup` record OUT of the named
# Velero backup, so the base backup it recovers from is the one that name
# points at, and renders the Cluster with `bootstrap.recovery` instead of
# `bootstrap.initdb`.
#
# Usage: recreate-kind.sh <substrate.env>     (make recreate ENV=kind calls it)
# Env:
#   RESTORE_FROM     the backup name a preserve teardown printed. Absent
#                    means every store bootstraps empty (ADR-0083)
#   CLUSTER          kind cluster name                  (default: gibson)
#   NS               release namespace                  (default: gibson)
#   RUNG             a rung of the profile ladder (ADR-0090): developer or ci
#                    (default: developer). The rung file ships IN the chart
#                    (helm/gibson/values-<rung>.yaml and the matching one in
#                    gibson-velero), so this names it rather than carrying a
#                    copy. RUNG=developer is what fits one local node; RUNG=ci
#                    is the same content under its own name. Both rungs turn
#                    on the Mailpit sink, so the daemon, the tenant-operator
#                    and Zitadel deliver mail on every kind cluster
#                    (charts#503, charts#511). The baseline alone has no mail
#                    sink, and the daemon refuses the log provider for an
#                    invitation (gibson#480), so kind never installs it.
#   OVERLAY          one named overlay from a closed list, layered on the
#                    baseline and the rung, last wins (hosted#425):
#                      plugins   test/baseline/plugins.values.yaml
#                      signup    test/signup/values.yaml
#                      demo      test/demo/diagnostics.values.yaml
#                      identity  test/identity/values.yaml
#                    No caller passes a path, so no test installs more than
#                    its rung and its one named overlay. EXTRA_VALUES,
#                    VELERO_EXTRA_VALUES and METRICS_SERVER_VALUES are refused.
#                    metrics-server is not a chart in zeroroot-ai/charts, so
#                    RUNG=ci selects its file, test/baseline/ci-2core-metrics-server.values.yaml.
#   TOOLHIVE_VERSION pinned ToolHive operator version   (default below)
#   WAIT_APPS_TIMEOUT / WAIT_APPS_STALL   seconds       (defaults 3600 / 1200)
#   RESTORE_TIMEOUT  optional: one bound for every restore wait, instead
#                    of the per-step bounds of lib/velero-restore.sh
set -euo pipefail

SUBSTRATE_ENV="${1:-}"
[ -n "$SUBSTRATE_ENV" ] || { echo "usage: recreate-kind.sh <substrate.env>" >&2; exit 2; }
[ -s "$SUBSTRATE_ENV" ] || { echo "FATAL: no substrate.env at ${SUBSTRATE_ENV}. Run make substrate ENV=kind first (ADR-0083)." >&2; exit 2; }
RESTORE_FROM="${RESTORE_FROM:-}"

# Resolved before anything below reads them. REPO is this checkout.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

CLUSTER="${CLUSTER:-gibson}"
NS="${NS:-gibson}"
VELERO_NS="${VELERO_NS:-velero}"
# The rung ships inside the chart, so it is NAMED here, never copied. That is
# the difference from EXTRA_VALUES below: an arbitrary overlay has to travel
# into the chart to be a valueFile, a rung is already there.
RUNG="${RUNG:-developer}"
# The rung is checked before anything else runs, so a wrong one costs no
# cluster. The baseline alone is not a kind install any more (charts#503).
case "$RUNG" in
  developer|ci) : ;;
  baseline) echo "FATAL: RUNG=baseline installs no mail sink, so no invitation can be sent on this cluster (charts#503). Use RUNG=developer (the default) or RUNG=ci." >&2; exit 2 ;;
  *) echo "FATAL: RUNG=${RUNG} is not a kind rung of the profile ladder: developer (the default) or ci (ADR-0090)." >&2; exit 2 ;;
esac
# A free values file is refused (owner decision on hosted#425). Before this
# change a caller could layer any file and so install more than its rung.
for _free in EXTRA_VALUES VELERO_EXTRA_VALUES METRICS_SERVER_VALUES; do
  if [ -n "${!_free:-}" ]; then
    echo "FATAL: ${_free} is not accepted any more (hosted#425). Name one overlay: OVERLAY=plugins|signup|demo|identity" >&2
    exit 2
  fi
done
unset _free
OVERLAY="${OVERLAY:-}"
case "$OVERLAY" in
  '')       EXTRA_VALUES="" ;;
  plugins)  EXTRA_VALUES="test/baseline/plugins.values.yaml" ;;
  signup)   EXTRA_VALUES="test/signup/values.yaml" ;;
  demo)     EXTRA_VALUES="test/demo/diagnostics.values.yaml" ;;
  identity) EXTRA_VALUES="test/identity/values.yaml" ;;
  *) echo "FATAL: OVERLAY=${OVERLAY} is not on the list: plugins, signup, demo, identity (hosted#425)" >&2; exit 2 ;;
esac
# The metrics-server add-on follows the rung. Only the CI rung shrinks it.
case "$RUNG" in
  ci) METRICS_SERVER_VALUES="test/baseline/ci-2core-metrics-server.values.yaml" ;;
  *)  METRICS_SERVER_VALUES="" ;;
esac
# The charts live in zeroroot-ai/charts now, not here. This repo is a CONSUMER
# of that one: it never holds chart source.
#
# CHARTS_ROOT points at a checkout of zeroroot-ai/charts. Default is a sibling
# directory, which is the workstation layout. For a released install, point it
# at a `helm pull`ed and untarred chart, or set CHART_OCI to install the
# published artifact straight from the registry.
#
# The kind inner loop deliberately allows an UNRELEASED checkout, because
# forcing a chart release into a loop run dozens of times a day costs more than
# it buys. The merge is the gate for the released path: each environment
# overlay pins a PUBLISHED chart version.
CHARTS_ROOT="${CHARTS_ROOT:-$(cd "$REPO/../charts" 2>/dev/null && pwd || echo "$REPO/../charts")}"
CHART_DIR="${CHART_DIR:-$CHARTS_ROOT/helm}"
if [ ! -d "$CHART_DIR/gibson" ]; then
  cat >&2 <<MSG
FATAL: no chart source at $CHART_DIR/gibson.

This repo holds no charts. Point CHARTS_ROOT at a checkout of
zeroroot-ai/charts, or at an untarred release:

  git clone git@github.com:zeroroot-ai/charts.git ../charts
  CHARTS_ROOT=/path/to/charts make recreate ENV=kind
MSG
  exit 1
fi
TOOLHIVE_VERSION="${TOOLHIVE_VERSION:-0.12.1}"
WAIT_APPS_TIMEOUT="${WAIT_APPS_TIMEOUT:-3600}"
WAIT_APPS_STALL="${WAIT_APPS_STALL:-1200}"
CNPG_CLUSTER="${CNPG_CLUSTER:-platform-postgres}"
# The prefix the Velero release writes its backups under. It is
# helm/gibson-velero/values.yaml `bucket.prefix`, and the two are held
# together by tests/harness/restore.bats: a chart-side change to the prefix
# has to change this line, or the restore looks in a prefix nothing writes.
VELERO_BUCKET_PREFIX="${VELERO_BUCKET_PREFIX:-backups/velero}"

log()  { printf '\n\033[1;32m▶\033[0m [recreate] %s\n' "$*"; }
die()  { printf '\033[1;31m✗ [recreate] %s\033[0m\n' "$*" >&2; exit 1; }

for tool in kind kubectl helm terraform docker aws git curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

# The rung files, checked here rather than where they are used. Both checks
# need die() and CHART_DIR, and a missing file must fail in the first seconds
# rather than after ten minutes of cluster creation and chart packaging.
# The rung was checked above; here its files must exist in the chart source.
[ -s "$CHART_DIR/gibson/values-${RUNG}.yaml" ] \
  || die "the chart source has no helm/gibson/values-${RUNG}.yaml, so RUNG=${RUNG} cannot be installed. CHARTS_ROOT=${CHARTS_ROOT} may predate the rung (zeroroot-ai/charts#93)."
# Velero installs as its own release, so a rung for the umbrella never
# reaches it and it carries its own.
[ -s "$CHART_DIR/gibson-velero/values-${RUNG}.yaml" ] \
  || die "the chart source has no helm/gibson-velero/values-${RUNG}.yaml, and Velero needs its own rung because it is a separate release (zeroroot-ai/charts#93)."

# Terraform's kubernetes/helm providers read ONE kubeconfig file. A KUBECONFIG
# list would silently pick the wrong half, so refuse it.
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"
case "$KUBECONFIG_PATH" in
  *:*) die "KUBECONFIG is a list ($KUBECONFIG_PATH). recreate needs one file; export KUBECONFIG=<one path>" ;;
esac

substrate_get() { grep -E "^$1=" "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2-; }
BUCKET_ENDPOINT="$(substrate_get BUCKET_ENDPOINT)"
BUCKET_NAME="$(substrate_get BUCKET_NAME)"
BUCKET_REGION="$(substrate_get BUCKET_REGION)"
KEYRING_FILE="${KEYRING_FILE:-$(substrate_get KEYRING_FILE)}"
[ -n "$BUCKET_ENDPOINT" ] && [ -n "$BUCKET_NAME" ] && [ -s "$KEYRING_FILE" ] \
  || die "${SUBSTRATE_ENV} is missing BUCKET_ENDPOINT, BUCKET_NAME or a readable KEYRING_FILE"
# The repository of the signed setec sandbox disks (D85). Stage 0 runs the
# registry (bootstrap/kind/substrate/substrate.sh) and names it here.
SETEC_DISK_REPO="$(substrate_get SETEC_DISK_REPO || true)"
[ -n "$SETEC_DISK_REPO" ] \
  || die "${SUBSTRATE_ENV} has no SETEC_DISK_REPO, the registry of the signed setec disks (D85). Run make substrate ENV=kind again"
SETEC_DISK_REGISTRY="${SETEC_DISK_REPO%%/*}"
# The public key of the keyring seed that signs each disk. Derived here from
# the same member that keyring-to-cluster.sh writes, so the key each launcher
# checks and the seed the disk builder signs with never disagree. While a
# seed rotation keeps the previous seed (keyring.sh, ROTATION), its key is
# the second key, so each launcher also accepts the disks it signed.
SETEC_DISK_KEYS="$("$HERE/keyring.sh" disk-public-keys "$KEYRING_FILE")" \
  || die "could not derive the setec disk public key from ${KEYRING_FILE}. A keyring from before D85 has no SETEC_DISK_SIGNING_SEED: run make substrate ENV=kind with a new state directory"
SETEC_DISK_PUBLIC_KEY="$(printf '%s\n' "$SETEC_DISK_KEYS" | sed -n 1p)"
SETEC_DISK_PREVIOUS_KEY="$(printf '%s\n' "$SETEC_DISK_KEYS" | sed -n 2p)"
disk_key_params_yaml=""
[ -z "$SETEC_DISK_PREVIOUS_KEY" ] || disk_key_params_yaml="
        - name: gibson-workloads.setec.launcher.diskBuilder.publicKeys[1]
          value: \"${SETEC_DISK_PREVIOUS_KEY}\""
keyring_get() { grep -E "^$1=" "$KEYRING_FILE" | head -n1 | cut -d= -f2- || true; }
CHART_REPO_URL="${BUCKET_ENDPOINT}/${BUCKET_NAME}/charts"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# helm_repo_add <name> <url> — add a chart repository, and MEAN it.
#
# The next line always installs FROM the alias this adds, so a failure here is
# never best-effort. It used to be written `helm repo add … >/dev/null 2>&1 ||
# true`, which threw away both the error and the exit code, and the bringup
# then died one line later on "repo metrics-server not found" — a message
# about the consequence that names neither the URL nor the reason. MEASURED
# 2026-09-02 (deploy#1740), run 33688427065: one of three dispatches of the
# blocker 3 loop died there two minutes in.
#
# Same bounded retry as dep_update below, for the same reason: this is a
# network fetch on a shared runner and it flaps. `--force-update` keeps a
# second run from failing on the alias it added itself.
REPO_ADD_ATTEMPTS="${REPO_ADD_ATTEMPTS:-4}"
helm_repo_add() {
  local name="$1" url="$2" attempt pause
  for attempt in $(seq 1 "$REPO_ADD_ATTEMPTS"); do
    if helm repo add --force-update "$name" "$url" >/dev/null 2>"$WORK/repo.err"; then
      [ "$attempt" -gt 1 ] && log "helm repo ${name}: added on attempt ${attempt}"
      return 0
    fi
    if [ "$attempt" -lt "$REPO_ADD_ATTEMPTS" ]; then
      pause=$(( attempt * 15 ))
      log "helm repo ${name}: attempt ${attempt}/${REPO_ADD_ATTEMPTS} failed, retrying in ${pause}s"
      sleep "$pause"
    fi
  done
  cat "$WORK/repo.err" >&2
  die "could not add the helm repository ${name} (${url}) in ${REPO_ADD_ATTEMPTS} attempts. The last error is above. The install that follows reads charts from this alias, so there is nothing to fall back to"
}

# s3 <aws args…> — the durable bucket, read and written with the keyring's
# OWN bucket credential. Nothing here uses the cluster: it has to work
# before stage 1 exists and after stage 1 is gone.
s3() {
  # The keyring's own credential, and nothing of the caller's. On a runner the
  # OIDC role leaves AWS_SESSION_TOKEN in the environment, and a key pair sent
  # with a foreign session token is refused as InvalidToken (drill run
  # 37413963774, 2026-10-06). AWS_PROFILE goes for the same reason.
  env -u AWS_SESSION_TOKEN -u AWS_PROFILE \
  AWS_ACCESS_KEY_ID="$(keyring_get BUCKET_ACCESS_KEY)" \
  AWS_SECRET_ACCESS_KEY="$(keyring_get BUCKET_SECRET_KEY)" \
  AWS_DEFAULT_REGION="${BUCKET_REGION:-us-east-1}" \
    aws --endpoint-url "$BUCKET_ENDPOINT" "$@"
}

# ---------------------------------------------------------------------------
# Stage 0b — the named backup, proven to exist BEFORE anything is destroyed.
#
# The whole restore half is scripts/lib/velero-restore.sh: it speaks kubectl,
# the bucket and Velero and nothing else, so ENV=staging runs the SAME code
# (scripts/recreate-aws.sh). resolve_named_backup sets RECOVERY_BACKUP_ID.
# ---------------------------------------------------------------------------
# shellcheck source=lib/velero-restore.sh
. "$HERE/lib/velero-restore.sh"

if [ -n "$RESTORE_FROM" ]; then
  resolve_named_backup
fi
# ---------------------------------------------------------------------------
# Stage 1a — the kind cluster, from nothing.
# ---------------------------------------------------------------------------
log "stage 1: recreating the kind cluster '${CLUSTER}' from nothing"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
# The LoadBalancer implementation is a host container tied to this cluster, so
# it goes with it. Left behind it would watch a cluster that no longer exists.
docker rm -f "cloud-provider-${CLUSTER}" >/dev/null 2>&1 || true
# The local Terraform state described objects that lived in the deleted
# cluster. A fresh apply against the fresh cluster is the truth; a refresh
# against ghosts is not.
rm -f "$REPO/bootstrap/kind/gibson/terraform.tfstate" "$REPO/bootstrap/kind/gibson/terraform.tfstate.backup"
# Cilium is the network plugin (hosted#436, ADR-0083), so kind installs none.
# The node is not Ready before a plugin exists, so `kind create` does not wait
# for it. The wait is below, after the Cilium install.
# The sandbox runtime of setec is a Firecracker machine, so the node needs
# /dev/kvm (gibson#991, charts#413, charts#414, the same rule as the EKS
# fleet in hosted#446). A kind node is a container, so the device of the host
# is mounted into it. A host with no /dev/kvm stops here: Docker would make an
# empty directory at the path, and every sandbox would then fail on a node
# that looks prepared.
[ -c /dev/kvm ] \
  || die "this host has no /dev/kvm, so the kind node cannot run a setec sandbox. On a GitHub runner, give the runner user access to /dev/kvm before the recreate"
kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG_PATH" --wait 0s --config=- <<'KIND'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  kubeProxyMode: none
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /dev/kvm
        containerPath: /dev/kvm
KIND
kubectl --kubeconfig "$KUBECONFIG_PATH" config use-context "kind-${CLUSTER}" >/dev/null
export KUBECONFIG="$KUBECONFIG_PATH"
docker exec "${CLUSTER}-control-plane" test -c /dev/kvm \
  || die "the kind node ${CLUSTER}-control-plane has no /dev/kvm after the mount, so no setec sandbox can start"
log "stage 1: the kind node exposes /dev/kvm"

# ---------------------------------------------------------------------------
# The network plugin of stage 1 (ADR-0083, hosted#436): Cilium, the same
# version and the same shared values as every other substrate. The bringup
# stops here when the CRD is absent, when an agent is not ready, or when a
# policy with a host name does not permit one host and refuse another.
# ---------------------------------------------------------------------------
# shellcheck source=lib/cilium.sh
. "$HERE/lib/cilium.sh"
log "stage 1: Cilium $(cilium_version) is the network plugin"
cilium_install kind --set "k8sServiceHost=${CLUSTER}-control-plane" \
  || die "Cilium did not install. The node has no network plugin, so no pod can start"
kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null \
  || die "the node did not get Ready after the Cilium install"
cilium_verify \
  || die "Cilium is not ready on this cluster"
cilium_prove_fqdn_policy \
  || die "Cilium does not enforce a policy with a host name on this cluster"

# ---------------------------------------------------------------------------
# The storage row of stage 1 (ADR-0083), on kind: local-path, and its volumes
# have to be BACKED UP.
#
# kind's local-path provisioner emits a `hostPath` PersistentVolume by
# default, and Velero's node-agent SKIPS a hostPath volume: it reads pod
# volumes under /var/lib/kubelet/pods and a hostPath is not there
# (pkg/podvolume/backupper.go). So on a kind cluster with the default
# StorageClass, every backup Completes and carries object JSON and NO volume
# data — no OpenBao store, no Neo4j graph. That is a backup that looks
# healthy and restores nothing.
#
# The provisioner reads `defaultVolumeType` from the StorageClass
# (rancher/local-path-provisioner provisioner.go: the PVC annotation
# `volumeType` first, this annotation second, hostPath last). Setting it here
# makes every claim on this cluster a `local` PV, which the node-agent does
# read. A cloud substrate has a CSI driver and needs none of this.
# ---------------------------------------------------------------------------
log "stage 1: the default StorageClass emits local volumes, so Velero can read them"
sc_deadline=$(( $(date +%s) + 120 ))
until kubectl annotate storageclass standard defaultVolumeType=local --overwrite >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "$sc_deadline" ] \
    || die "the 'standard' StorageClass never appeared, so defaultVolumeType=local could not be set. Without it every volume on this cluster is a hostPath, which Velero silently skips, and a backup taken here restores no data"
  sleep 5
done

node="${CLUSTER}-control-plane"
# The setec disk registry of stage 0 speaks plain HTTP on a private address
# (D85). containerd pulls an image volume over HTTPS unless a hosts.toml names
# the host, so the kubelet could not pull one disk without this file. The disk
# builder needs no file: it uses HTTP for an RFC 1918 address.
log "setec disks: containerd on ${node} pulls from http://${SETEC_DISK_REGISTRY}"
docker exec "$node" mkdir -p "/etc/containerd/certs.d/${SETEC_DISK_REGISTRY}"
printf 'server = "http://%s"\n\n[host."http://%s"]\n  capabilities = ["pull", "resolve"]\n' \
  "$SETEC_DISK_REGISTRY" "$SETEC_DISK_REGISTRY" \
  | docker exec -i "$node" tee "/etc/containerd/certs.d/${SETEC_DISK_REGISTRY}/hosts.toml" >/dev/null
# Restart containerd once, so it reads the host file before the first pull.
docker exec "$node" systemctl restart containerd

# ---------------------------------------------------------------------------
# Stage 1b — Argo CD from the kind Terraform. The workspace installs Argo and
# nothing else (ADR-0083, deploy#1751): every operator is an umbrella
# subchart, and no credential is generated (deploy#1732).
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Stage 1: the LoadBalancer implementation and metrics-server (ADR-0083).
#
# The substrate contract gives every cluster the same six rows, and names
# kind's implementation of two of them: "kind cloud-provider" for the
# LoadBalancer, and a metrics-server add-on. They are not optional garnish.
# The baseline profile ships the Envoy Service as type LoadBalancer, because a
# customer cluster has one. On a bare kind cluster that Service never gets an
# address, and Argo CD holds a sync open waiting for its health: MEASURED
# (runs 33633490342 and 33640379594) the whole platform converged — every Job
# Complete, every ExternalSecret Synced, PlatformBootstrap all-True — while
# the Application sat at "waiting for healthy state of /Service/gibson-envoy"
# until the wait gave up. helm never showed this because `helm --wait` does
# not wait on a LoadBalancer address; only Argo's health model does.
#
# cloud-provider-kind runs on the HOST, not in the cluster: it watches Docker
# for kind clusters and gives their LoadBalancer Services an address. It
# therefore needs the Docker socket, and it is torn down with the cluster.
# ---------------------------------------------------------------------------
CLOUD_PROVIDER_KIND_IMAGE="${CLOUD_PROVIDER_KIND_IMAGE:-ghcr.io/zeroroot-ai/mirror/cloud-provider-kind:v0.7.0}"
METRICS_SERVER_IMAGE_TAG="${METRICS_SERVER_IMAGE_TAG:-v0.8.0}"
CPK_CONTAINER="cloud-provider-${CLUSTER}"

log "stage 1: the kind LoadBalancer implementation (cloud-provider-kind)"
docker rm -f "$CPK_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CPK_CONTAINER" --restart unless-stopped \
  --network kind \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --label zeroroot.ai/recreate-cluster="$CLUSTER" \
  "$CLOUD_PROVIDER_KIND_IMAGE" >/dev/null
log "cloud-provider-kind running as $CPK_CONTAINER"

# metrics-server: the HPA row. kind's kubelet serves its metrics endpoint with
# a self-signed certificate that no cluster CA signed, so the add-on needs
# --kubelet-insecure-tls; that is a property of kind, not a relaxation we
# carry to a real substrate.
log "stage 1: metrics-server"
helm_repo_add metrics-server https://kubernetes-sigs.github.io/metrics-server/
METRICS_SERVER_ARGS=()
for _mv in $METRICS_SERVER_VALUES; do
  [ -s "$REPO/$_mv" ] || die "the metrics-server file ${_mv} of RUNG=${RUNG} does not exist"
  METRICS_SERVER_ARGS+=(-f "$REPO/$_mv")
done
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  ${METRICS_SERVER_ARGS[@]+"${METRICS_SERVER_ARGS[@]}"} \
  --set "image.repository=ghcr.io/zeroroot-ai/mirror/metrics-server" \
  --set "image.tag=${METRICS_SERVER_IMAGE_TAG}" \
  --set-json 'args=["--kubelet-insecure-tls","--kubelet-preferred-address-types=InternalIP"]' \
  --wait --timeout 5m >/dev/null

log "stage 1: terraform apply (Argo CD)"
export TF_VAR_cluster_name="$CLUSTER"
export TF_VAR_kubeconfig_path="$KUBECONFIG_PATH"
terraform -chdir="$REPO/bootstrap/kind/gibson" init -upgrade -input=false >/dev/null
# The Argo CD release waits 5 minutes for its pods. When it misses, the
# apply says only "context deadline exceeded", which names no pod and no
# reason (hosted#235: four runs on 2026-09-27 died here with nothing to read).
# So on failure, print what the pods were doing before stopping.
if ! terraform -chdir="$REPO/bootstrap/kind/gibson" apply -auto-approve -input=false; then
  printf '\n--- Argo CD pods and events at the failure (hosted#235) ---\n' >&2
  kubectl -n argocd get pods -o wide >&2 || true
  kubectl -n argocd describe pods 2>/dev/null | grep -E '^Name:|Image:|State:|Reason:|Message:|Ready:' >&2 || true
  kubectl -n argocd get events --sort-by=.lastTimestamp 2>/dev/null | tail -40 >&2 || true
  die "stage 1: the Argo CD release did not become Ready. The pods and events above name the cause (hosted#235)."
fi

# ---------------------------------------------------------------------------
# The bringup keyring, into the cluster (ADR-0083). recreate owns this step;
# the interim producers (bootstrap/kind/gibson/keyring.tf and the inline blocks in
# baseline-up.sh) are deleted (deploy#1737).
# ---------------------------------------------------------------------------
log "writing the bringup keyring into the cluster"
NS="$NS" KEYRING_FILE="$KEYRING_FILE" "$HERE/keyring-to-cluster.sh" "$SUBSTRATE_ENV"

# ---------------------------------------------------------------------------
# Cluster prerequisite: ToolHive (ADR-0114, connector runtime). A third-party
# release with its own CRD chart, not an umbrella dependency; the gibson
# connector-operator renders MCPServer / MCPRemoteProxy CRs against it.
# Pinned; the ConnectorInstance wrapper absorbs a ToolHive upgrade.
# ---------------------------------------------------------------------------
log "prerequisite: toolhive ${TOOLHIVE_VERSION}"
helm upgrade --install toolhive-operator-crds \
  oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds \
  --namespace toolhive-system --create-namespace --version "$TOOLHIVE_VERSION" \
  --wait --timeout 10m
# The values make each proxy pod meet restricted (hosted#454).
helm upgrade --install toolhive-operator \
  oci://ghcr.io/stacklok/toolhive/toolhive-operator \
  --namespace toolhive-system --version "$TOOLHIVE_VERSION" \
  --values "$REPO/bootstrap/toolhive/values.yaml" \
  --wait --timeout 10m

# ---------------------------------------------------------------------------
# Stage 2 — package this checkout's charts and publish them to the durable
# bucket's charts/ prefix as a plain Helm repository.
#
# Why not git as the Argo source: the umbrella's dependency chain is two
# levels deep (gibson -> gibson-workloads -> gibson-common and remote charts)
# and helm/**/charts/*.tgz are never committed (a stale .tgz ships stale
# code, deploy#1001). Argo's repo-server builds only the top level, so a git
# source cannot render this chart. Packaging locally after a bottom-up
# dependency build produces self-contained archives, and the bucket already
# outlives the cluster and is proven live by preflight.
# ---------------------------------------------------------------------------
log "stage 2: building chart dependencies (bottom-up)"
# Chart dependencies come from third-party repositories over the network, and
# one of them flaps. MEASURED 2026-09-02: cloudnative-pg.github.io/charts
# 301-redirects to cloudnative-pg.io, and that host answered 200 and then
# failed to connect within seconds, repeatedly. A single-shot fetch turns a
# transient DNS or TLS failure into a dead bringup twenty minutes in, with
# "no cached repository for helm-manager-<sha>" as the only clue.
#
# Bounded retry, and it still fails LOUDLY: three attempts with a widening
# pause, then the real helm error. This retries a network fetch, it does not
# hide a broken chart — a genuinely bad dependency fails all three times and
# the last error is printed.
DEP_UPDATE_ATTEMPTS="${DEP_UPDATE_ATTEMPTS:-6}"
dep_update() {
  local chart="$1" attempt rc pause
  for attempt in $(seq 1 "$DEP_UPDATE_ATTEMPTS"); do
    if helm dependency update "$chart" >/dev/null 2>"$WORK/dep.err"; then
      [ "$attempt" -gt 1 ] && log "chart dependencies for $(basename "$chart"): succeeded on attempt ${attempt}"
      return 0
    else
      # Capture INSIDE the else: after `fi`, $? is the status of the if
      # statement itself, which is 0 whenever the condition was merely false.
      # The first version printed "rc=0" on every failure, which is a lie.
      rc=$?
    fi
    if [ "$attempt" -lt "$DEP_UPDATE_ATTEMPTS" ]; then
      pause=$(( attempt * 20 ))
      log "chart dependencies for $(basename "$chart"): attempt ${attempt}/${DEP_UPDATE_ATTEMPTS} failed, retrying in ${pause}s"
      sleep "$pause"
      # A partly-written repository cache is itself a cause of the next
      # failure, so refresh the index before trying again.
      helm repo update >/dev/null 2>&1 || true
    fi
  done
  cat "$WORK/dep.err" >&2
  die "helm dependency update failed ${DEP_UPDATE_ATTEMPTS} times for $chart (rc=$rc). The last error is above. MEASURED 2026-09-02: cloudnative-pg.io, which cloudnative-pg.github.io/charts redirects to, has no A record and answers only on IPv6 that refuses port 443, so on an IPv4-only runner the CNPG chart is unreachable whenever that is true. It flaps, which is why this retries; when it does not recover the honest outcome is this failure."
}

dep_update "$CHART_DIR/gibson-operator-crds"
dep_update "$CHART_DIR/gibson-crds"
dep_update "$CHART_DIR/gibson-operators"
dep_update "$CHART_DIR/gibson-workloads"
dep_update "$CHART_DIR/gibson"
dep_update "$CHART_DIR/gibson-velero"

# One unique version per run, so Argo can never serve a cached archive of an
# older run under the same name.
# The version identifies the CHART SOURCE, not this repo. Stamping $REPO's sha
# here recorded the hosted commit on a gibson chart — provenance pointing at
# the wrong repository, and unfalsifiable once the charts move independently.
STAMP="$(date -u +%Y%m%d%H%M%S)"
VER="0.0.0-recreate.${STAMP}.g$(git -C "$CHARTS_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
# The Postgres archive this bringup writes: <bucket>/backups/postgres/
# <PG_ARCHIVE_NAME>/. Unique per bootstrap, because the durable bucket
# outlives the cluster (ADR-0083) and CNPG refuses to archive into a
# directory that already holds another cluster's WAL (measured 2026-09-07:
# ContinuousArchiving=False on the first segment, every base backup stuck in
# walArchivingFailing, the preserve teardown dead at step 1). A restore reads
# the OLD archive named in the backup record (RECOVERY_ARCHIVE_NAME, set by
# resolve_named_backup) and writes this NEW one.
PG_ARCHIVE_NAME="platform-postgres-${STAMP}"
log "stage 2: packaging gibson-operator-crds, gibson-crds, gibson, gibson-velero as ${VER}"
mkdir -p "$WORK/charts"
helm package "$CHART_DIR/gibson-operator-crds" -d "$WORK/charts" --version "$VER" >/dev/null
helm package "$CHART_DIR/gibson-crds" -d "$WORK/charts" --version "$VER" >/dev/null
# gibson-velero takes its rung only: no overlay layers on it (hosted#425).
cp -a "$CHART_DIR/gibson-velero" "$WORK/chart-velero"
VELERO_VALUE_FILES=()
helm package "$WORK/chart-velero" -d "$WORK/charts" --version "$VER" >/dev/null
# The umbrella is copied so EXTRA_VALUES overlays travel INSIDE the chart:
# a chart-repository source resolves valueFiles inside the chart only.
cp -a "$CHART_DIR/gibson" "$WORK/chart-gibson"
EXTRA_VALUE_FILES=()
i=0
for _ov in $EXTRA_VALUES; do
  i=$((i + 1))
  [ -s "$REPO/$_ov" ] || die "the file ${_ov} of OVERLAY=${OVERLAY} does not exist"
  cp "$REPO/$_ov" "$WORK/chart-gibson/recreate-extra-${i}.yaml"
  EXTRA_VALUE_FILES+=("recreate-extra-${i}.yaml")
done
helm package "$WORK/chart-gibson" -d "$WORK/charts" --version "$VER" >/dev/null
helm repo index "$WORK/charts" --url "$CHART_REPO_URL"

log "stage 2: publishing to ${CHART_REPO_URL}"
env -u AWS_SESSION_TOKEN -u AWS_PROFILE \
AWS_ACCESS_KEY_ID="$(keyring_get BUCKET_ACCESS_KEY)" \
AWS_SECRET_ACCESS_KEY="$(keyring_get BUCKET_SECRET_KEY)" \
AWS_DEFAULT_REGION="${BUCKET_REGION:-us-east-1}" \
  aws s3 cp --recursive --no-progress "$WORK/charts" "s3://${BUCKET_NAME}/charts/" \
    --endpoint-url "$BUCKET_ENDPOINT" >/dev/null
# Argo fetches the repository with a plain anonymous GET. Stage 0 sets the
# download policy on the charts/ prefix; an old stage 0 state has not.
curl -fsS "$CHART_REPO_URL/index.yaml" >/dev/null \
  || die "cannot fetch ${CHART_REPO_URL}/index.yaml anonymously. Stage 0 is stale: re-run make substrate ENV=kind (it sets the charts/ download policy), then re-run recreate"

# ---------------------------------------------------------------------------
# The kubernetes Service ClusterIP, the first address of the Service CIDR. The
# apiserver egress rule below names it. No Envoy ClusterIP is pinned: charts#163
# deleted envoy.service.clusterIP, and a client dials the Envoy Service by name
# (ADR-0092).
# ---------------------------------------------------------------------------
K8S_SVC_IP="$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')"
case "$K8S_SVC_IP" in
  *.*.*.*) ;;
  *) die "could not read the kubernetes Service ClusterIP" ;;
esac

# ---------------------------------------------------------------------------
# The addresses a pod reaches the kube-apiserver through, for the policies that
# narrow egress (OpenBao). `global.networkPolicy.apiServerCIDRs` ships EMPTY,
# and empty renders NO RULE — so an omission here is not a weaker policy, it is
# a missing one, and it is invisible on a CNI that does not enforce
# NetworkPolicy at all.
#
# BOTH names, because the two are the same apiserver and a policy engine may
# judge either. kube-proxy rewrites the destination before a NetworkPolicy is
# evaluated, so a packet to the kubernetes Service leaves as the endpoint
# address; an engine that evaluates the pre-DNAT address sees the ClusterIP.
# scripts/baseline-up.sh computes exactly this pair, and this verb is the one
# that knows it is kind, so it passes it the same way it passes the Envoy
# ClusterIP below.
#
# What the omission costs, measured three times: staging 2026-09-10 (the VPC
# CIDR was allowed and the ClusterIP was not), k3d 2026-09-14
# (zeroroot-ai/charts#80), staging 2026-09-23 (the CIDR was stale after
# ADR-0095). Every one surfaced as OpenBao's Kubernetes-auth login answering a
# bare "permission denied", then the secret store InvalidProviderConfig, then
# every ExternalSecret in SecretSyncedError, and the platform never finished.
API_CIDRS=("${K8S_SVC_IP}/32")
for ep in $(kubectl get endpoints kubernetes -n default \
              -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null); do
  case "$ep" in *.*.*.*) API_CIDRS+=("${ep}/32") ;; esac
done
[ "${#API_CIDRS[@]}" -ge 2 ] || die "read ${#API_CIDRS[@]} apiserver address(es) (${API_CIDRS[*]}): the kubernetes Service ClusterIP answered but its endpoints did not, so the egress rule would name only half the apiserver. Re-run once the control plane settles."
api_cidr_params_yaml=""
i=0
for c in "${API_CIDRS[@]}"; do
  api_cidr_params_yaml="${api_cidr_params_yaml}
        - name: global.networkPolicy.apiServerCIDRs[${i}]
          value: \"${c}\""
  i=$((i + 1))
done
log "apiserver reachable at ${API_CIDRS[*]} -> global.networkPolicy.apiServerCIDRs"

# ---------------------------------------------------------------------------
# CoreDNS answers for the platform's own hosts (hosted#397). api.<domain> has
# no public record on kind. A setec sandbox, a plugin and the e2e runner reach
# the platform through that name, and a sandbox resolves names only through
# its own resolvers (dnsPolicy None), so a hostAlias does not help it: every
# sandboxed agent's heartbeat and callback failed with ENOTFOUND (gibson#13).
# The record maps the host to the Envoy Service NAME, never to an address
# (hosted#186), so it does not depend on the pinned ClusterIP above. CoreDNS on
# kind imports no custom config and the bringup owns the cluster it just
# created, so the record is applied here, before the umbrella installs. The
# domain follows the values the umbrella installs (baseline, then the rung,
# then EXTRA_VALUES, last wins).
# ---------------------------------------------------------------------------
. "$HERE/lib/coredns-platform-hosts.sh"
DOMAIN_VALUES=("$CHART_DIR/gibson/values-baseline.yaml" "$CHART_DIR/gibson/values-${RUNG}.yaml")
for _ov in $EXTRA_VALUES; do DOMAIN_VALUES+=("$REPO/$_ov"); done
PLATFORM_DOMAIN="$(values_domain "${DOMAIN_VALUES[@]}")" \
  || die "the values the umbrella installs name no global.domain; CoreDNS cannot be given a record for the platform's hosts"
ENVOY_SERVICE_FQDN="gibson-envoy.${NS}.svc.cluster.local"
log "stage 1: CoreDNS maps api.${PLATFORM_DOMAIN} and app.${PLATFORM_DOMAIN} to ${ENVOY_SERVICE_FQDN}"
coredns_publish_platform_hosts corefile "$ENVOY_SERVICE_FQDN" "api.${PLATFORM_DOMAIN}" "app.${PLATFORM_DOMAIN}" \
  || die "CoreDNS did not take the record for ${PLATFORM_DOMAIN} (kube-system/coredns)"

# ---------------------------------------------------------------------------
# Stage 2 — the Argo CD Applications. gibson-crds first: Helm cannot validate
# a CR whose CRD the same release carries (deploy#1627), so the CRDs are a
# release of their own, synced to Healthy before the umbrella is applied.
# The syncPolicy mirrors the gitops gibson Application: bounded retries,
# ServerSideApply + ServerSideDiff, and the sa-identity-map label exclusions
# (deploy#865).
# ---------------------------------------------------------------------------
# wait_apps is scripts/lib/wait-apps.sh — the SAME code ENV=staging runs
# (scripts/recreate-aws.sh). Slow is fine; stuck is not, and the definition of
# "moving" belongs in one place.
# shellcheck source=lib/wait-apps.sh
. "$HERE/lib/wait-apps.sh"

# THE CRDs ARE TWO RELEASES (charts#82): the cert-manager, External Secrets
# and CloudNativePG CRDs left gibson-crds because a Helm release record is one
# Secret with a 1 MiB cap and the two together were ten percent over it.
#
# Argo does not hit that cap — it applies server-side and writes no release
# record — so it will install the smaller gibson-crds and say nothing about
# the CRDs that are no longer in it. That is precisely what happened here: the
# exit test went red for three runs with
#
#   error: the server doesn't have a resource type "externalsecrets"
#   error: the server doesn't have a resource type "certificates"
#
# and the guard written for the same trap could not see it, because it only
# examines envs that pin a PUBLISHED version and this path packages its own.
#
# BOTH ARE APPLIED, THEN WAITED ON ONCE. Each chart renders nothing but
# CustomResourceDefinitions, so neither holds a custom resource of the other's
# kinds and there is no order between them. Only the umbrella below needs them
# established. Waiting on each in turn would serialize two Argo syncs that run
# perfectly well side by side, and this verb runs five times per push to main.
log "stage 2: Applications gibson-operator-crds and gibson-crds"
kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gibson-operator-crds
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${CHART_REPO_URL}
    chart: gibson-operator-crds
    targetRevision: "${VER}"
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
YAML
kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gibson-crds
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${CHART_REPO_URL}
    chart: gibson-crds
    targetRevision: "${VER}"
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      # A cold sync runs a hook chain that is minutes long (postgres-setup,
      # then the Zitadel init and setup Jobs). MEASURED (deploy#1737): one
      # slow hook consumed both retries of a limit-2 policy inside four
      # minutes, and the operation then failed for good. The bringup is a
      # one-shot verb, not a steady-state reconcile, so it gets room to
      # finish; wait_apps below is what bounds it.
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
YAML
wait_apps

# ===========================================================================
# The restore, when a backup was named (ADR-0083, deploy#1739).
#
# Everything below goes through a Velero `Restore` object. The recreate never
# copies bytes itself and never edits a live store by hand: the controller
# that wrote the backup is the controller that reads it back.
# ===========================================================================


# The Restore objects, the waits and the counts are
# scripts/lib/velero-restore.sh, sourced at stage 0b: restore_secret_store,
# wait_eso and restore_data below are its functions, and ENV=staging calls
# the same ones (scripts/recreate-aws.sh).

# ---------------------------------------------------------------------------
# Stage 2 — the Velero release, BEFORE the umbrella.
#
# It used to be applied in the same breath as the umbrella. It is applied
# first now because a restore has to be able to run before the platform
# exists: the secret store comes back through Velero, and nothing may read a
# Secret until it has. On a bringup with no RESTORE_FROM the only difference
# is ordering — one Application converging on its own instead of two racing
# for a cold node.
#
# Named velero so the Helm release name matches the one
# scripts/baseline-up.sh installs (helm upgrade --install velero): the
# upstream subchart derives resource names from the release name, and two
# names for one deployment is drift. No backtick may appear in this heredoc:
# it is unquoted for variable substitution, so a backtick EXECUTES (the
# deploy#1765 failure class).
# ---------------------------------------------------------------------------
log "stage 2: Application velero"
velero_rung_value_file_yaml="
        - values-${RUNG}.yaml"
velero_value_files_yaml=""
for f in ${VELERO_VALUE_FILES[@]+"${VELERO_VALUE_FILES[@]}"}; do
  velero_value_files_yaml="${velero_value_files_yaml}
        - ${f}"
done
kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  # Named velero so the Helm release name matches the one
  # scripts/baseline-up.sh installs (helm upgrade --install velero): the
  # upstream subchart derives resource names from the release name, and two
  # names for one deployment is drift. No backtick may appear in this
  # heredoc: it is unquoted for variable substitution, so a backtick
  # EXECUTES (the deploy#1765 failure class).
  name: velero
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${CHART_REPO_URL}
    chart: gibson-velero
    targetRevision: "${VER}"
    helm:
      valueFiles:
        - values.yaml${velero_rung_value_file_yaml}${velero_value_files_yaml}
      parameters:
        - name: bucket.name
          value: ${BUCKET_NAME}
        - name: bucket.endpoint
          value: ${BUCKET_ENDPOINT}
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  ignoreDifferences:
    # The Velero schedule controller REWRITES spec.skipImmediately to false as
    # soon as it has honoured it: the field is a one-shot instruction, not
    # desired state. The chart sets it true so the first backup waits for the
    # first cron tick instead of racing the node-agent rollout. Those two
    # facts together mean the rendered Schedule and the live Schedule can
    # never agree, and the Application would sit OutOfSync forever with no
    # defect behind it. Measured on kind 2026-09-02 (deploy#1739).
    - group: velero.io
      kind: Schedule
      name: platform-hourly
      namespace: velero
      jsonPointers:
        - /spec/skipImmediately
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      # A cold sync runs a hook chain that is minutes long (postgres-setup,
      # then the Zitadel init and setup Jobs). MEASURED (deploy#1737): one
      # slow hook consumed both retries of a limit-2 policy inside four
      # minutes, and the operation then failed for good. The bringup is a
      # one-shot verb, not a steady-state reconcile, so it gets room to
      # finish; wait_apps below is what bounds it.
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - ServerSideDiff=true
      - RespectIgnoreDifferences=true
YAML
wait_apps

if [ -n "$RESTORE_FROM" ]; then
  restore_secret_store
  restore_redis
fi


log "stage 2: Application gibson"
# The rung comes first, so an EXTRA_VALUES overlay still wins last.
rung_value_file_yaml="
        - values-${RUNG}.yaml"
extra_value_files_yaml=""
for f in ${EXTRA_VALUE_FILES[@]+"${EXTRA_VALUE_FILES[@]}"}; do
  extra_value_files_yaml="${extra_value_files_yaml}
        - ${f}"
done
kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gibson
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${CHART_REPO_URL}
    chart: gibson
    targetRevision: "${VER}"
    helm:
      valueFiles:
        - values-baseline.yaml${rung_value_file_yaml}${extra_value_files_yaml}
      parameters:
        # kind keeps ONE Postgres instance (ADR-0083: three instances with
        # synchronous replication is the staging and prod posture, and "kind
        # keeps one instance as a profile value"). values-baseline.yaml cannot
        # carry it: it is the BASE every substrate layers on, so prod renders
        # baseline + values-eks.yaml and would inherit the single instance.
        # The kind verb is what knows it is kind, so the kind posture is set
        # here.
        #
        # MEASURED (kind, deploy#1737, 2026-09-02) without this: the umbrella
        # applied the prod posture to a one-node cluster — instances 3,
        # synchronous.dataDurability: required, and required pod
        # anti-affinity on topology.kubernetes.io/zone, a label the kind
        # node does not carry at all. The Cluster wedged in "Failing over"
        # with the primary 0/1: a commit needs a synchronous standby that can
        # never be scheduled, so Postgres never listened,
        # gibson-openfga-migrate died on connection refused until its
        # backoffLimit was spent, OpenFGA crashlooped on "datastore is not
        # ready", and every workload behind it stayed in Init. At one
        # instance the chart renders no synchronous block (CNPG rejects
        # synchronous.number >= instances) and the anti-affinity is trivially
        # satisfiable.
        - name: platformPostgres.instances
          value: "1"
        - name: platformPostgres.recovery.backupID
          # EMPTY on a bringup with no RESTORE_FROM, and the Cluster then
          # renders bootstrap.initdb: an empty database, always, even when
          # the barman catalog in the bucket is full (ADR-0083). With a name,
          # this is the base backup id read OUT of that named Velero backup,
          # so Postgres recovers from the backup that was asked for and never
          # from the newest one in the catalog.
          value: "${RECOVERY_BACKUP_ID}"
        - name: platformPostgres.recovery.serverName
          # The archive the named backup was written under, read from the
          # same CNPG Backup record as the id. Empty with no RESTORE_FROM.
          value: "${RECOVERY_ARCHIVE_NAME}"
        - name: platformPostgres.backup.serverName
          # The archive THIS cluster writes, stamped per bootstrap (see
          # PG_ARCHIVE_NAME above). Never the one it recovers from.
          value: "${PG_ARCHIVE_NAME}"
        - name: platformPostgres.backup.destinationPath
          value: s3://${BUCKET_NAME}/backups/postgres/
        - name: platformPostgres.backup.endpointURL
          value: ${BUCKET_ENDPOINT}
        # The registry of the signed setec sandbox disks, from stage 0 (D85).
        # The setec chart fails the render without it.
        - name: gibson-workloads.setec.launcher.diskRepo
          value: "${SETEC_DISK_REPO}"
        # The public key of the keyring seed SETEC_DISK_SIGNING_SEED, and of
        # the previous seed during a rotation. Each launcher refuses a disk
        # that none of these keys signed.
        - name: gibson-workloads.setec.launcher.diskBuilder.publicKeys[0]
          value: "${SETEC_DISK_PUBLIC_KEY}"${disk_key_params_yaml}${api_cidr_params_yaml}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NS}
  ignoreDifferences:
    - group: ""
      kind: ConfigMap
      name: gibson-sa-identity-map
      namespace: ${NS}
      jqPathExpressions:
        - '.metadata.labels["app.kubernetes.io/managed-by"]'
        - '.metadata.labels["gibson.zeroroot.ai/component"]'
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      # A cold sync runs a hook chain that is minutes long (postgres-setup,
      # then the Zitadel init and setup Jobs). MEASURED (deploy#1737): one
      # slow hook consumed both retries of a limit-2 policy inside four
      # minutes, and the operation then failed for good. The bringup is a
      # one-shot verb, not a steady-state reconcile, so it gets room to
      # finish; wait_apps below is what bounds it.
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
    # Pod Security on the release namespace (D8, ADR-0165, hosted#438): it
    # enforces restricted. This Application is the one place that sets the
    # labels on kind; the kind Terraform creates the namespace with none
    # (scripts/check-namespace-pod-security.py).
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: restricted
        pod-security.kubernetes.io/enforce-version: latest
        pod-security.kubernetes.io/audit: restricted
        pod-security.kubernetes.io/warn: restricted
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - ServerSideDiff=true
      - RespectIgnoreDifferences=true
YAML

if [ -n "$RESTORE_FROM" ]; then
  wait_eso
  restore_data
fi

log "stage 2: waiting for every Application to reach Synced+Healthy"
wait_apps
log "stage 2: every ExternalSecret is Ready (hosted#174)"
wait_externalsecrets

# The same proof the AWS arm runs, from the same file: Ready and Healthy say
# nothing about whether a WAL segment ever reached the bucket (ADR-0083).
# shellcheck source=lib/wait-archiving.sh
. "$HERE/lib/wait-archiving.sh"
log "the platform Postgres archives its WAL (ADR-0083, blocker 3)"
NS="$NS" wait_archiving

log "recreate ENV=kind complete: every Argo Application is Synced+Healthy"
kubectl -n argocd get applications \
  -o jsonpath='{range .items[*]}    {.metadata.name}: sync={.status.sync.status} health={.status.health.status}{"\n"}{end}'
printf '    cluster   kind-%s (kubeconfig %s)\n' "$CLUSTER" "$KUBECONFIG_PATH"
printf '    charts    %s (version %s)\n' "$CHART_REPO_URL" "$VER"
printf '    archive   s3://%s/backups/postgres/%s/ (this bringup writes here)\n' "$BUCKET_NAME" "$PG_ARCHIVE_NAME"
printf '    verify    make baseline-verify\n'
if [ -n "$RESTORE_FROM" ]; then
  printf '    stores    restored from backup %s (ADR-0083)\n' "$RESTORE_FROM"
  printf '    postgres  recovered from base backup %s in archive %s\n' "$RECOVERY_BACKUP_ID" "$RECOVERY_ARCHIVE_NAME"
  kubectl -n "$VELERO_NS" get restores.velero.io \
    -o jsonpath='{range .items[*]}    restore   {.metadata.name}: {.status.phase}{"\n"}{end}'
else
  printf '    stores    bootstrapped empty (no RESTORE_FROM, ADR-0083)\n'
fi
