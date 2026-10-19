#!/usr/bin/env bash
# verify-profile.sh — assert a LIVE cluster runs the deployment profile it claims.
#
# WHY LOCAL AND NOT CI
#
# The kind cluster used to be the only place the self-hosted profile ever ran;
# gitops#353 flipped it to SaaS so card-first signup could be exercised the way
# staging and prod run it, and the OSS posture customers install lost its live
# coverage (deploy#1137). The obvious fix — a CI kind bringup — is ruled out by
# CICD-CONTEXT decision #3: `make make-dev` stays local-only, no full-umbrella
# bringup in CI. That is why kind-standup-nightly.yml was deleted (deploy#1070),
# and re-adding it would just re-open a settled argument.
#
# So coverage is split. The render-time half runs in CI on every chart PR
# (helm/gibson-workloads/tests/kind-profile-coherence.bats). This is the live
# half: run it by hand against whatever cluster you have standing, before a
# release or after flipping a profile.
#
# Render-time checks alone cannot see what this sees: an image that pulls, a
# daemon that actually chose the embedded provider, a /login that serves rather
# than 500ing on an incoherent profile.
#
# Usage:
#   scripts/verify-profile.sh self-hosted
#   scripts/verify-profile.sh saas
#   make verify-profile PROFILE=self-hosted
#
# Env:
#   NAMESPACE    k8s namespace                (default: gibson)
#   CLUSTER_URL  dashboard external origin    (default: gibson-domains/externalOrigin)
#   EDGE_ADDR    <ip>:<port> of the edge       (default: from the Envoy Service)
#
# Exit: 0 all assertions passed · 1 an assertion failed · 2 preflight failed
set -uo pipefail

PROFILE="${1:-}"
NAMESPACE="${NAMESPACE:-gibson}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cluster-probe.sh
source "${SCRIPT_DIR}/lib/cluster-probe.sh"
# The install states its own origin in the gibson-domains ConfigMap. The old
# default app.zeroroot.ai:30443 named a host no baseline install serves, so
# the two edge probes answered 000 against a working edge (2026-09-07).
if [ -z "${CLUSTER_URL:-}" ]; then
  CLUSTER_URL="$(kubectl -n "${NAMESPACE:-gibson}" get configmap gibson-domains -o jsonpath='{.data.externalOrigin}' 2>/dev/null || true)"
fi
[ -n "${CLUSTER_URL:-}" ] || { echo "verify-profile: no CLUSTER_URL and no gibson-domains ConfigMap to derive it from" >&2; exit 2; }
CLUSTER_HOST="$(printf '%s' "$CLUSTER_URL" | sed -E 's#^https?://([^/:]+).*#\1#')"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
fails=0
pass() { printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$1"; fails=$((fails + 1)); }
step() { printf '\n%s=== %s ===%s\n' "$CYAN" "$1" "$NC"; }

case "$PROFILE" in
  self-hosted|saas) ;;
  *) printf 'usage: %s <self-hosted|saas>\n' "$0" >&2; exit 2 ;;
esac

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }
kubectl -n "$NAMESPACE" get ns "$NAMESPACE" >/dev/null 2>&1 || \
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || { echo "namespace $NAMESPACE unreachable" >&2; exit 2; }

printf '%s▶%s verifying the %s profile on %s (ns=%s)\n' \
  "$GREEN" "$NC" "$PROFILE" "$(kubectl config current-context)" "$NAMESPACE"

# ---------------------------------------------------------------------------
# Env-var facts, read from the live workloads rather than from any values file.
# ---------------------------------------------------------------------------
env_present() { # env_present <workload-substring> <ENV_NAME>
  kubectl -n "$NAMESPACE" get deploy,statefulset -o json 2>/dev/null \
    | python3 -c '
import json, sys
name_hint, var = sys.argv[1], sys.argv[2]
docs = json.load(sys.stdin)
for item in docs.get("items", []):
    if name_hint not in item["metadata"]["name"]:
        continue
    for c in item["spec"]["template"]["spec"].get("containers", []):
        for e in c.get("env", []) or []:
            if e.get("name") == var:
                print(e.get("value", ""))
                sys.exit(0)
sys.exit(1)
' "$1" "$2"
}

step "images"
closed_refs="$(kubectl -n "$NAMESPACE" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c 'ghcr.io/zeroroot-ai/billing' || true)"
if [ "$PROFILE" = "self-hosted" ]; then
  [ "$closed_refs" -eq 0 ] \
    && pass "no closed billing image running (found 0)" \
    || fail "closed billing image is running in a self-hosted cluster (found $closed_refs container(s))"
else
  [ "$closed_refs" -gt 0 ] \
    && pass "closed billing image running as expected (found $closed_refs container(s))" \
    || fail "SaaS profile but no ghcr.io/zeroroot-ai/billing container is running — the entitlements/webhook overlays are missing"
fi

step "daemon entitlements seam"
endpoint="$(env_present gibson-workloads ENTITLEMENTS_ENDPOINT || true)"
required="$(env_present gibson-workloads GIBSON_ENTITLEMENTS_REQUIRED || true)"
if [ "$PROFILE" = "self-hosted" ]; then
  [ -z "$endpoint" ] && pass "ENTITLEMENTS_ENDPOINT absent (embedded ConfigProvider)" \
                     || fail "ENTITLEMENTS_ENDPOINT=$endpoint set on a self-hosted daemon"
  [ -z "$required" ] && pass "GIBSON_ENTITLEMENTS_REQUIRED absent (fail-open is correct here)" \
                     || fail "GIBSON_ENTITLEMENTS_REQUIRED=$required set on a self-hosted daemon"
  if kubectl -n "$NAMESPACE" logs statefulset/gibson-gibson-workloads -c gibson --tail=2000 2>/dev/null \
      | grep -qi 'grpcProvider'; then
    fail "daemon logs mention grpcProvider — it is dialing a remote seam"
  else
    pass "daemon logs show no remote-seam provider"
  fi
else
  [ -n "$endpoint" ] && pass "ENTITLEMENTS_ENDPOINT=$endpoint" \
                     || fail "SaaS profile but the daemon has no ENTITLEMENTS_ENDPOINT"
  [ "$required" = "true" ] && pass "GIBSON_ENTITLEMENTS_REQUIRED=true (fails closed)" \
                           || fail "SaaS profile without GIBSON_ENTITLEMENTS_REQUIRED=true — the seam is fail-OPEN (deploy#1055)"
fi

step "dashboard deployment profile"
billing="$(env_present gibson-dashboard DASHBOARD_BILLING_PAID_TIERS_ENABLED || true)"
www="$(env_present gibson-dashboard WWW_URL || true)"
if [ "$PROFILE" = "self-hosted" ]; then
  [ -z "$billing" ] && pass "billing off (card-free signup)" || fail "DASHBOARD_BILLING_PAID_TIERS_ENABLED=$billing on a self-hosted dashboard"
  [ -z "$www" ] && pass "WWW_URL absent (no marketing surface)" || fail "WWW_URL=$www on a self-hosted dashboard (dashboard#920)"
else
  [ "$billing" = "true" ] && pass "billing on (card-first signup)" || fail "SaaS profile with billing off"
  [ -n "$www" ] && pass "WWW_URL=$www" || fail "billing on with no WWW_URL — the resolver fail-closes and 500s every route (deploy#1075)"
fi

step "signup front door"
daemon_signup="$(env_present gibson-workloads SIGNUP_SELF_SERVE || true)"
dash_signup="$(env_present gibson-dashboard SIGNUP_SELF_SERVE || true)"
[ "$daemon_signup" = "$dash_signup" ] \
  && pass "SIGNUP_SELF_SERVE agrees across daemon and dashboard ('${daemon_signup:-<absent>}')" \
  || fail "SIGNUP_SELF_SERVE disagrees — daemon='${daemon_signup:-<absent>}' dashboard='${dash_signup:-<absent>}'"

step "edge serves (the failure mode an incoherent profile produces)"
# Through the edge the install exposes, by SNI and Host, so a workstation
# with no DNS for the install's domain still reaches it (scripts/lib/
# cluster-probe.sh pins the host to the edge address with --resolve).
if EDGE="$(resolve_edge "${NAMESPACE:-gibson}")"; then
  code="$(edge_status "$EDGE" "$CLUSTER_HOST" "/login")"
  [ "$code" = "200" ] && pass "GET /login → 200" || fail "GET /login → $code (a 500 here is the IncoherentDeploymentProfileError signature)"
  code="$(edge_status "$EDGE" "$CLUSTER_HOST" "/signup?plan=team")"
  [ "$code" = "200" ] && pass "GET /signup?plan=team → 200" || fail "GET /signup?plan=team → $code"
else
  fail "no usable Envoy edge in ns/${NAMESPACE:-gibson} — the two edge probes cannot run"
fi

printf '\n%s=== summary ===%s\n' "$CYAN" "$NC"
if [ "$fails" -gt 0 ]; then
  printf '%s[FAIL]%s %s assertion(s) failed — this cluster does not run a clean %s profile\n' "$RED" "$NC" "$fails" "$PROFILE"
  exit 1
fi
printf '%s[PASS]%s cluster runs a coherent %s profile\n' "$GREEN" "$NC" "$PROFILE"
printf '  next: run the flow itself — make smoke-signup%s\n' \
  "$([ "$PROFILE" = "saas" ] && echo " (and make stripe-listen for webhook delivery)" || echo "")"
