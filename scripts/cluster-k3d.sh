#!/usr/bin/env bash
# cluster-k3d.sh — the local cluster, on k3d. Stage 1 and nothing else.
#
# LOCAL ONLY. This does not run in CI and is not meant to (owner call,
# 2026-09-15). kind and k3d are the developer story, run on a developer's own
# machine; CI is a different thing with its own rung of the profile ladder.
#
# It was tried in CI once, on exit-test-published-install. A GitHub 2-vCPU
# runner does not fit this platform plus a k3s control plane: the node evicted
# 35 pods, the operators cycled through five generations each, and the install
# died at the first-admin hook. A developer's machine has the room.
#
# What it is FOR is a k3s cluster on a workstation, which is what staging
# runs. Cilium is the network plugin here, as on every substrate (hosted#436),
# so each policy that the chart ships is enforced.
#
# kind was the only local cluster this estate knew how to build. k3d is the
# second, and this file is deliberately ONLY the cluster: it creates one, or
# deletes one, and installs no platform. scripts/baseline-up.sh installs onto
# whatever the current context is, so the two compose without either knowing
# about the other (hosted#84).
#
# WHAT IS DIFFERENT FROM KIND, and why each difference is handled here
#
#   the Docker network   Stage 0 runs MinIO and CoreDNS as containers
#     on a Docker network it creates, and derives their addresses from
#     whatever /16 that network got. kind joins a network of the same name by
#     default; k3d does not. Without it the cluster cannot reach the bucket
#     and every Postgres archive fails.
#
#     It is ATTACHED AFTER creation rather than passed to --network, and that
#     is not a preference. Stage 0's network is dual-stack, Docker reports its
#     IPv6 config first, and k3d then announces "HostIP: using network gateway
#     fc00:...::1 address" and the server never comes up — it rolls the
#     cluster back reporting a node that is in fact running. k3d has no
#     host-IP override. So the cluster is built on its own network, where k3d
#     picks an IPv4 gateway, and the node joins stage 0's network afterwards.
#     Measured on this workstation 2026-09-14.
#
#   Traefik              k3s installs Traefik as the ingress. The platform
#     brings Envoy and terminates its own TLS, so two ingress controllers
#     would both claim :80 and :443 on the node. Disabled.
#
#   servicelb            k3s assigns an external address to a LoadBalancer
#     Service through klipper-lb, a DaemonSet that binds the node's ports.
#     The Envoy Service is a LoadBalancer, so klipper would bind those ports
#     on the node and collide with the port mappings below. Disabled: on a
#     local cluster the Service is reached through the mapped ports, exactly
#     as it is on kind.
#
#   the StorageClass     k3s's default is `local-path`, kind's is `standard`.
#     Both are the same provisioner and both carry the SAME defect: a
#     hostPath PersistentVolume is invisible to Velero's node-agent, which
#     reads pod volumes under /var/lib/kubelet/pods. Every backup then
#     Completes carrying object JSON and no volume data, which is a backup
#     that looks healthy and restores nothing. The annotation that fixes it
#     is the same on both.
#
# Usage:
#   cluster-k3d.sh create     create the cluster, or recreate it from scratch
#   cluster-k3d.sh delete     remove it
#   cluster-k3d.sh verify     prove it is usable by the platform
set -euo pipefail

VERB="${1:-}"
CLUSTER="${CLUSTER:-gibson}"
# Stage 0 names its Docker network `kind`, and derives the bucket address from
# that network's subnet. The name is stage 0's, not kind's: a k3d cluster that
# joins it reaches the same MinIO at the same address.
NET="${SUBSTRATE_NETWORK:-kind}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/k3d-${CLUSTER}.kubeconfig}"
# The k3s channel. Pinned, and bumped deliberately, like every other runtime
# version in this estate.
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.31.5-k3s1}"
# k3d 5.9.0 or newer. 5.6.0 reports "stopped returning log lines ... status=
# restarting" and rolls the cluster back against Docker 29, on a node that is
# in fact Ready — it is k3d's readiness wait that breaks, not the cluster, so
# the failure looks like a broken cluster and is not. Measured on this
# workstation 2026-09-14 with Docker 29.6.1.
K3D_MIN="5.9.0"
# The node ports the platform exposes, mapped to the same host ports kind
# maps. A host port belongs to ONE container: a kind cluster and a k3d cluster
# cannot both hold 30002, and the second to start fails with "Bind for
# 0.0.0.0:30002 failed: port is already allocated". That is Docker telling the
# truth, not a defect. Override these to run both at once.
GRPC_PORT="${GRPC_PORT:-30002}"
METRICS_PORT="${METRICS_PORT:-30910}"

log() { printf '\n\033[1;32m▶\033[0m [k3d %s] %s\n' "$CLUSTER" "$*"; }
die() { printf '\033[1;31m✗ [k3d %s] %s\033[0m\n' "$CLUSTER" "$*" >&2; exit 1; }

for tool in k3d docker kubectl helm; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cilium.sh
. "$HERE/lib/cilium.sh"

have="$(k3d version 2>/dev/null | sed -n 's/^k3d version v\{0,1\}//p' | head -1)"
if [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$K3D_MIN" "$have" | sort -V | head -1)" != "$K3D_MIN" ]; then
  die "k3d ${have} is too old; ${K3D_MIN} or newer is required. Older k3d rolls back a cluster whose node is actually Ready, because its readiness wait cannot follow Docker's logs — the error names the cluster and the fault is in k3d. Install: curl -fsSL https://github.com/k3d-io/k3d/releases/download/v${K3D_MIN}/k3d-linux-amd64 -o ~/.local/bin/k3d && chmod +x ~/.local/bin/k3d"
fi

delete_cluster() {
  log "deleting"
  k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
  rm -f "$KUBECONFIG_PATH"
  printf '  ✓ gone\n'
}

create_cluster() {
  docker network inspect "$NET" >/dev/null 2>&1 \
    || die "no Docker network '${NET}'. That network is stage 0's: it runs the bucket, the relay and the DNS server on it and derives their addresses from its subnet. Run: make substrate ENV=kind"

  # Recreate from scratch. A cluster half-built by an interrupted run is
  # indistinguishable from a good one until the platform fails on it.
  k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true

  for port in "$GRPC_PORT" "$METRICS_PORT"; do
    if docker ps --format '{{.Ports}}' | grep -q ":${port}->"; then
      holder="$(docker ps --filter "publish=${port}" --format '{{.Names}}' | head -1)"
      die "host port ${port} is already held by ${holder:-another container}. A host port belongs to one container, so two local clusters cannot both map it. Delete that cluster, or set GRPC_PORT and METRICS_PORT to run both"
    fi
  done

  # The sandbox runtime of setec is a Firecracker machine, so the node needs
  # /dev/kvm (ADR-0083, charts#413, the same rule as the kind node of
  # recreate-kind.sh and the EKS fleet of hosted#446). A k3d node is a
  # container, so the device of the host is mounted into it. A host with no
  # /dev/kvm stops here: Docker would make an empty directory at the path,
  # and every sandbox would then fail on a node that looks prepared.
  [ -c /dev/kvm ] \
    || die "this host has no /dev/kvm, so the k3d node cannot run a setec sandbox. On a GitHub runner, give the runner user access to /dev/kvm before the create"

  log "creating"
  k3d cluster create "$CLUSTER" \
    --image "$K3S_IMAGE" \
    --servers 1 --agents 0 \
    --volume "/dev/kvm:/dev/kvm@server:0" \
    --k3s-arg "--disable=traefik@server:*" \
    --k3s-arg "--disable=servicelb@server:*" \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*" \
    --k3s-arg "--disable-kube-proxy@server:*" \
    --port "${GRPC_PORT}:30002@server:0" \
    --port "${METRICS_PORT}:30910@server:0" \
    --kubeconfig-update-default=false \
    --kubeconfig-switch-context=false \
    --wait \
    || die "k3d could not create the cluster"

  node="k3d-${CLUSTER}-server-0"
  docker exec "$node" test -c /dev/kvm \
    || die "the k3d node ${node} has no /dev/kvm after the mount, so no setec sandbox can start"
  log "the k3d node exposes /dev/kvm"

  log "joining the stage 0 network ${NET}, so the cluster can reach the bucket"
  docker network connect "$NET" "$node" >/dev/null 2>&1 \
    || docker network inspect "$NET" -f '{{range .Containers}}{{.Name}} {{end}}' | grep -q "$node" \
    || die "could not attach ${node} to the ${NET} network; the platform's Postgres would archive nowhere"

  k3d kubeconfig get "$CLUSTER" > "$KUBECONFIG_PATH"
  chmod 0600 "$KUBECONFIG_PATH"
  export KUBECONFIG="$KUBECONFIG_PATH"

  # Cilium is the network plugin (hosted#436, ADR-0083). k3s starts with
  # flannel off and with its own policy controller off.
  #
  # The k3s node image does not mount the BPF file system and does not share
  # its mounts. The Cilium agent needs both. kind's node image has both
  # already, so only this script has the step.
  log "preparing ${node} for Cilium: the BPF file system and a shared cgroup2 mount"
  docker exec "$node" sh -c '
    set -e
    mountpoint -q /sys/fs/bpf || mount -t bpf bpffs /sys/fs/bpf
    mount --make-shared /sys/fs/bpf
    mkdir -p /run/cilium/cgroupv2
    mountpoint -q /run/cilium/cgroupv2 || mount -t cgroup2 none /run/cilium/cgroupv2
    mount --make-shared /run/cilium/cgroupv2
  ' || die "could not prepare ${node} for Cilium"
  log "Cilium $(cilium_version) is the network plugin"
  cilium_install k3d --set "k8sServiceHost=k3d-${CLUSTER}-server-0" \
    || die "Cilium did not install. The node has no network plugin, so no pod can start"
  kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null \
    || die "the node did not get Ready after the Cilium install"

  log "the default StorageClass emits local volumes, so Velero can read them"
  # Identical reasoning to the kind path, different class name. The
  # provisioner reads defaultVolumeType from the StorageClass; without it
  # every claim is a hostPath, Velero's node-agent skips it, and a backup
  # taken here restores no data.
  sc_deadline=$(( $(date +%s) + 120 ))
  until kubectl annotate storageclass local-path defaultVolumeType=local --overwrite >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$sc_deadline" ] \
      || die "the 'local-path' StorageClass never appeared, so defaultVolumeType=local could not be set. Without it every volume here is a hostPath, which Velero silently skips, and a backup taken on this cluster restores no data"
    sleep 5
  done

  printf '  ✓ cluster up, kubeconfig %s\n' "$KUBECONFIG_PATH"
  printf '    install onto it with: KUBECONFIG=%s scripts/baseline-up.sh\n' "$KUBECONFIG_PATH"
}

# verify — the cluster is usable BY THE PLATFORM, which is more than "the API
# server answers". Three things the platform needs on day one, each of which
# has its own way of being quietly absent.
verify_cluster() {
  export KUBECONFIG="$KUBECONFIG_PATH"
  [ -r "$KUBECONFIG_PATH" ] || die "no kubeconfig at ${KUBECONFIG_PATH}; run: $0 create"

  log "the node is Ready"
  kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null \
    || die "no node reached Ready"

  log "Cilium is the network plugin, and it enforces a policy with a host name"
  cilium_verify || die "Cilium is not ready on this cluster"
  cilium_prove_fqdn_policy || die "Cilium does not enforce a policy with a host name on this cluster"

  log "neither Traefik nor klipper-lb is running"
  # Both would claim ports the platform's own edge needs. A cluster that has
  # them is one where Envoy comes up and nothing reaches it.
  for unwanted in traefik svclb; do
    if kubectl get pods -A --no-headers 2>/dev/null | grep -q "$unwanted"; then
      die "${unwanted} is running; the platform brings its own edge and the two collide on the node's ports"
    fi
  done
  printf '  ✓ the node ports belong to the platform\n'

  log "a PersistentVolumeClaim binds, and its volume is one Velero can read"
  kubectl delete pvc k3d-verify --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: k3d-verify
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 64Mi
YAML
  # WaitForFirstConsumer: the claim binds when a pod wants it, so the pod
  # below is what proves the storage path, not the claim on its own.

  log "a pod reads an object out of the stage 0 bucket"
  # THE reason this file passes --network: the platform's Postgres archives
  # every WAL segment to that bucket. A cluster that cannot reach it installs
  # fine and has no backups, which is the failure this proves absent.
  # The IPv4 subnet, specifically. Stage 0's network is dual-stack and Docker
  # lists the IPv6 config first, so taking "the subnet" concatenates the two
  # into something that parses as neither. Stage 0 derives the addresses from
  # the IPv4 subnet, so this must read the same one.
  bucket_ip="$(docker network inspect "$NET" \
      -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' \
    | grep -E '^[0-9]+\.' | head -1 \
    | python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.stdin.read().strip())[-6])')"
  [ -n "$bucket_ip" ] || die "the ${NET} network has no IPv4 subnet, so stage 0's bucket has no address"
  kubectl delete pod k3d-verify --ignore-not-found >/dev/null 2>&1 || true
  kubectl run k3d-verify --image=ghcr.io/zeroroot-ai/mirror/curl:8.10.1 --restart=Never \
    --overrides="{\"spec\":{\"volumes\":[{\"name\":\"v\",\"persistentVolumeClaim\":{\"claimName\":\"k3d-verify\"}}],\"containers\":[{\"name\":\"k3d-verify\",\"image\":\"ghcr.io/zeroroot-ai/mirror/curl:8.10.1\",\"args\":[\"-sS\",\"-o\",\"/dev/null\",\"-w\",\"%{http_code}\",\"http://${bucket_ip}:9000/minio/health/live\"],\"volumeMounts\":[{\"name\":\"v\",\"mountPath\":\"/data\"}]}]}}" \
    >/dev/null || die "could not start the probe pod"
  kubectl wait --for=condition=Ready=false --timeout=120s pod/k3d-verify >/dev/null 2>&1 || true
  deadline=$(( $(date +%s) + 120 ))
  until [ "$(kubectl get pod k3d-verify -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ]; do
    phase="$(kubectl get pod k3d-verify -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "$phase" != Failed ] || die "the probe pod could not reach the bucket at ${bucket_ip}:9000. The cluster is not on the stage 0 network, so Postgres would archive nowhere"
    [ "$(date +%s)" -lt "$deadline" ] \
      || die "the probe pod never finished; last phase ${phase:-<none>}"
    sleep 3
  done
  code="$(kubectl logs k3d-verify 2>/dev/null | tr -d '[:space:]')"
  [ "$code" = 200 ] || die "the bucket answered HTTP ${code:-<nothing>} at ${bucket_ip}:9000, not 200"
  printf '  ✓ the bucket at %s:9000 answers from inside the cluster\n' "$bucket_ip"

  bound="$(kubectl get pvc k3d-verify -o jsonpath='{.status.phase}' 2>/dev/null)"
  [ "$bound" = Bound ] || die "the PersistentVolumeClaim is ${bound:-<none>}, not Bound"
  vol="$(kubectl get pv "$(kubectl get pvc k3d-verify -o jsonpath='{.spec.volumeName}')" \
    -o jsonpath='{.spec.local.path}{.spec.hostPath.path}' 2>/dev/null)"
  kubectl get pv "$(kubectl get pvc k3d-verify -o jsonpath='{.spec.volumeName}')" \
    -o jsonpath='{.spec.local}' 2>/dev/null | grep -q path \
    || die "the volume is a hostPath, not a local volume. Velero's node-agent skips hostPath, so every backup taken here would restore no data"
  printf '  ✓ a claim binds to a LOCAL volume (%s), which Velero can read\n' "$vol"

  kubectl delete pod k3d-verify --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pvc k3d-verify --ignore-not-found >/dev/null 2>&1 || true
  printf '\n\033[0;32mk3d cluster %s is usable by the platform.\033[0m\n' "$CLUSTER"
}

case "$VERB" in
  create) create_cluster ;;
  delete) delete_cluster ;;
  verify) verify_cluster ;;
  *) echo "usage: $0 {create|delete|verify}" >&2; exit 2 ;;
esac
