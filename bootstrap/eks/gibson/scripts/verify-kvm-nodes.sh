#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-kvm-nodes.sh — each node of the sandbox fleet exposes /dev/kvm
# (hosted#446, ADR-0083).
#
# Every sandbox is a Firecracker machine, so a fleet node with no /dev/kvm
# runs no sandbox, and nothing else says so. The fleet is each node with the
# label setec.zeroroot.ai/sandbox-host=true. For each one this runs a short
# pod on that node that tests the device, and fails on the first node where
# the device is absent.
#
# Env: KVM_PROBE_NS (default kube-system), KVM_PROBE_IMAGE, KVM_TIMEOUT.
# Exit: 0 each fleet node has /dev/kvm · 1 a node has none, or no fleet node
# exists.
# ---------------------------------------------------------------------------
set -euo pipefail

NS="${KVM_PROBE_NS:-kube-system}"
IMAGE="${KVM_PROBE_IMAGE:-ghcr.io/zeroroot-ai/mirror/curl:8.10.1}"
TIMEOUT="${KVM_TIMEOUT:-180}"
LABEL="setec.zeroroot.ai/sandbox-host=true"

nodes="$(kubectl get nodes -l "$LABEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
[ -n "$nodes" ] || { echo "verify-kvm-nodes: no node carries ${LABEL}, so the cluster has no sandbox fleet" >&2; exit 1; }

for node in $nodes; do
  pod="kvm-probe-$(printf '%s' "$node" | tr -c 'a-z0-9' '-' | cut -c1-40)"
  kubectl -n "$NS" delete pod "$pod" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
spec:
  nodeName: ${node}
  restartPolicy: Never
  tolerations: [{ operator: Exists }]
  containers:
    - name: probe
      image: ${IMAGE}
      command: ["sh", "-c", "test -c /host-dev/kvm && echo kvm-present"]
      volumeMounts: [{ name: dev, mountPath: /host-dev, readOnly: true }]
  volumes:
    - name: dev
      hostPath: { path: /dev, type: Directory }
YAML
  phase=""
  deadline=$(( $(date +%s) + TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    phase="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 3
  done
  out="$(kubectl -n "$NS" logs "$pod" 2>/dev/null || true)"
  kubectl -n "$NS" delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [ "$phase" != Succeeded ] || [ "$out" != kvm-present ]; then
    echo "verify-kvm-nodes: node ${node} has no /dev/kvm (probe phase ${phase:-none}). Its instance type needs nested virtualization or metal" >&2
    exit 1
  fi
  printf '  ✓ node %s exposes /dev/kvm\n' "$node"
done
