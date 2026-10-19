#!/usr/bin/env bash
# deny-probe.sh — the identity exit test runs under enforced policy (hosted#428).
#
# The daily kind run is the enforced-policy proof (owner decision of
# 2026-10-05): kind runs Cilium since hosted#436, and Cilium enforces each
# NetworkPolicy of the chart. This probe proves that the enforcement is real
# on the cluster of this run, on an identity call:
#
#   1. a pod in a namespace of its own fetches the OIDC discovery document at
#      https://<app host>/.well-known/openid-configuration. Cluster DNS maps
#      the app host to the Envoy Service (hosted#397), so this is the identity
#      call that a plugin or a sandbox makes. Zitadel itself admits only the
#      callers that the chart names, so the probe calls it through the edge.
#   2. with test/identity/deny-probe.yaml applied, the same call fails
#   3. with the policy deleted, the call works again
#
# Step 2 is the deliberate deny policy. If the call succeeds there, the
# network plugin does not enforce policy, and an identity test on this
# cluster proves nothing about policy. The namespace is deleted at the end.
#
# Env: NS (default gibson), RELEASE (default gibson), CURL_IMAGE.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-gibson}"
RELEASE="${RELEASE:-gibson}"
PROBE_NS="${PROBE_NS:-identity-deny-probe}"
CURL_IMAGE="${CURL_IMAGE:-ghcr.io/zeroroot-ai/mirror/curl:8.10.1}"
APP_HOST="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.appHost}' 2>/dev/null || true)"
if [ -z "$APP_HOST" ]; then
  DOMAIN="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.domain}' 2>/dev/null || true)"
  [ -n "$DOMAIN" ] || { echo "FATAL: the gibson-domains ConfigMap names no domain" >&2; exit 1; }
  APP_HOST="app.${DOMAIN}"
fi
TARGET="https://${APP_HOST}/.well-known/openid-configuration"

die()  { printf '\033[0;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
cleanup() { kubectl delete namespace "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# call -> the curl exit code of one identity call from the probe pod.
call() {
  local rc=0
  # -k: the edge certificate of a CI install chains to a CA of its own. Any
  # HTTP answer is a reached edge, so the exit code of curl is the measure.
  kubectl -n "$PROBE_NS" exec probe -- curl -ksS -o /dev/null --connect-timeout 5 --max-time 8 "$TARGET" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

kubectl delete namespace "$PROBE_NS" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
kubectl create namespace "$PROBE_NS" >/dev/null
kubectl -n "$PROBE_NS" run probe --image="$CURL_IMAGE" --restart=Never --command -- sleep 600 >/dev/null
kubectl -n "$PROBE_NS" wait --for=condition=Ready pod/probe --timeout=180s >/dev/null \
  || die "the probe pod did not get ready in ${PROBE_NS}"

rc="$(call)"
[ "$rc" = 0 ] || die "1. with no policy, the probe cannot reach the identity provider (curl exit ${rc}). The probe has no baseline, so step 2 would prove nothing"
pass "1. with no policy, the probe reaches the identity provider"

kubectl -n "$PROBE_NS" apply -f "$HERE/deny-probe.yaml" >/dev/null
# The agent needs a moment to program a new policy. Wait for the deny, bounded.
for _ in $(seq 1 12); do rc="$(call)"; [ "$rc" != 0 ] && break; sleep 5; done
[ "$rc" != 0 ] || die "2. the deny policy is in place, and the probe still reaches the identity provider. This cluster does not enforce NetworkPolicy"
pass "2. with the deny policy, the identity call fails (curl exit ${rc})"

kubectl -n "$PROBE_NS" delete networkpolicy deny-identity-calls >/dev/null
for _ in $(seq 1 12); do rc="$(call)"; [ "$rc" = 0 ] && break; sleep 5; done
[ "$rc" = 0 ] || die "3. the deny policy is deleted, and the probe still cannot reach the identity provider (curl exit ${rc})"
pass "3. with the policy deleted, the identity call works again"
