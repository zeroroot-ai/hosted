#!/usr/bin/env bash
# restricted-probe.sh — each ToolHive pod starts in a namespace that enforces
# the restricted Pod Security level (hosted#454, ADR-0165).
#
# Each tenant namespace gets `pod-security.kubernetes.io/enforce: restricted`
# (gibson#767). ToolHive creates the connector pods there. The API server
# refuses a pod that does not meet the level, so the connector never starts.
# This probe proves the ToolHive install of this cluster on the three pods:
#
#   1. the proxy Deployment of an MCPServer (the operator creates it)
#   2. the MCP server StatefulSet of that MCPServer (the proxy creates it)
#   3. the proxy Deployment of an MCPRemoteProxy (the operator creates it)
#
# Pods 1 and 3 meet the level through bootstrap/toolhive/values.yaml. Pod 2
# meets it through spec.podTemplateSpec below: ToolHive v0.12.1 reads no
# install setting for it. The connector operator of gibson must set the same
# fields on each MCPServer that it creates.
#
# A refused pod never exists, so the probe waits for each workload to be
# ready and prints the FailedCreate events when one is not. The namespace is
# deleted at the end.
#
# Env: PROBE_NS, TIMEOUT (seconds, default 300), MCP_IMAGE.
set -euo pipefail

PROBE_NS="${PROBE_NS:-toolhive-restricted-probe}"
TIMEOUT="${TIMEOUT:-300}"
# The yardstick test server of ToolHive, pinned by digest.
MCP_IMAGE="${MCP_IMAGE:-ghcr.io/stackloklabs/yardstick/yardstick-server@sha256:87a40f4f8f3689682e78e7f3840775833184753bfcb69336dc4ac57f1024008e}"
SERVER=yardstick
REMOTE=yardstick-remote

die()  { printf '\033[0;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
cleanup() { kubectl delete namespace "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# refused <what> -> print why the API server refused the pods, then fail.
refused() {
  echo "--- events in ${PROBE_NS}" >&2
  kubectl -n "$PROBE_NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -30 >&2 || true
  kubectl -n "$PROBE_NS" get pods,deploy,sts 2>/dev/null >&2 || true
  die "$1 did not start in a namespace that enforces restricted"
}

# wait_for <kind/name> -> 0 when the object exists and is ready.
wait_for() {
  local obj="$1" deadline
  deadline=$(( $(date +%s) + TIMEOUT ))
  until kubectl -n "$PROBE_NS" get "$obj" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 3
  done
  kubectl -n "$PROBE_NS" rollout status "$obj" --timeout="${TIMEOUT}s" >/dev/null
}

kubectl delete namespace "$PROBE_NS" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "$PROBE_NS" >/dev/null
kubectl label namespace "$PROBE_NS" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest >/dev/null

kubectl apply -f - >/dev/null <<YAML
apiVersion: toolhive.stacklok.dev/v1alpha1
kind: MCPServer
metadata:
  name: ${SERVER}
  namespace: ${PROBE_NS}
spec:
  image: ${MCP_IMAGE}
  transport: streamable-http
  env:
    - name: TRANSPORT
      value: streamable-http
  mcpPort: 8080
  proxyPort: 8080
  podTemplateSpec:
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: mcp
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
---
apiVersion: toolhive.stacklok.dev/v1alpha1
kind: MCPRemoteProxy
metadata:
  name: ${REMOTE}
  namespace: ${PROBE_NS}
spec:
  remoteURL: http://mcp-${SERVER}-proxy.${PROBE_NS}.svc.cluster.local:8080/mcp
  transport: streamable-http
  proxyPort: 8080
  oidcConfig:
    type: kubernetes
YAML

wait_for "deployment/${SERVER}" || refused "1. the proxy of the MCPServer"
pass "1. the proxy of the MCPServer starts under restricted"
wait_for "statefulset/${SERVER}" || refused "2. the MCP server pod of the MCPServer"
pass "2. the MCP server pod of the MCPServer starts under restricted"
wait_for "deployment/${REMOTE}" || refused "3. the proxy of the MCPRemoteProxy"
pass "3. the proxy of the MCPRemoteProxy starts under restricted"
