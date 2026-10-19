#!/usr/bin/env bash
# verify-saas-surfaces.sh — live SaaS web-surface verification (deploy#1041).
#
# Covers the surface half of deploy#1041's acceptance criteria:
#   - the docs site renders at docs.<domain>
#   - the dashboard login page serves at app.<domain>
#   - the whole SaaS surface set is green in ONE cluster
#
# The signup criterion ("card-first self-serve signup -> tenant provisioned") is
# NOT re-implemented here — scripts/smoke-signup.sh already drives signup to a
# Ready Tenant CR. This suite asserts the surfaces around it and then names that
# script as the remaining step, so the two compose rather than overlap. On the
# SaaS profile smoke-signup.sh pays the signup step with the Stripe TEST card
# through Stripe Checkout, with the one signup driver (hosted#647).
#
# Usage:
#   scripts/verify-saas-surfaces.sh
#   make verify-saas-surfaces
#
# Env:
#   NAMESPACE   k8s namespace                        (default: gibson)
#   DOMAIN      platform domain; hosts derive as     (default: zeroroot.ai)
#               docs.<DOMAIN>, app.<DOMAIN>
#   EDGE_ADDR   override the derived edge <ip>:<port> (default: derived from
#               the Envoy Service, so /etc/hosts is not required)
#
# Exit: 0 all assertions passed · 1 an assertion failed · 2 preflight failed
#
# Preflight failure is exit 2 and is NOT a pass. If there is no cluster, this
# script refuses to produce a result rather than producing a green one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cluster-probe.sh
source "${SCRIPT_DIR}/lib/cluster-probe.sh"

NAMESPACE="${NAMESPACE:-gibson}"

# ---------------------------------------------------------------------------
step "Preflight"
# ---------------------------------------------------------------------------
probe_cluster "$NAMESPACE"

# This suite is only meaningful on a SaaS-profile cluster. On a self-hosted
# cluster the SaaS-only surfaces are absent BY DESIGN (ADR-0074), so every
# assertion below would fail for the correct reason and report a defect that
# is not one.
require_profile "$NAMESPACE" "saas"

require_workload "$NAMESPACE" deploy gibson-dashboard "the dashboard login surface"

EDGE="$(resolve_edge "$NAMESPACE")" \
  || preflight_die "no usable Envoy edge in ns/${NAMESPACE} — cannot determine the edge address to probe"
pass "edge resolved to ${EDGE} (probes use curl --resolve, not /etc/hosts)"

# The install states its own domain in the gibson-domains ConfigMap. Read it
# here, after the cluster, profile, workload and edge preflights, so each of
# those refusals still names its own cause. DOMAIN stays as an override for
# a ConfigMap under suspicion.
if [ -z "${DOMAIN:-}" ]; then
  DOMAIN="$(kubectl -n "$NAMESPACE" get configmap gibson-domains -o jsonpath='{.data.domain}' 2>/dev/null || true)"
fi
[ -n "${DOMAIN:-}" ] || preflight_die "no DOMAIN and no gibson-domains ConfigMap in ns/${NAMESPACE} to derive it from"
DOCS_HOST="docs.${DOMAIN}"
APP_HOST="app.${DOMAIN}"

# ---------------------------------------------------------------------------
# Marketing surface — deliberately NOT probed here.
# ---------------------------------------------------------------------------
# www.<domain> is an off-cluster surface (ADR-0077): it is served from
# S3 behind CloudFront and is not routed by this edge at all. Probing it
# through the Envoy edge would assert a path that no longer exists, and would
# fail on a perfectly healthy cluster.
#
# Its coverage did not vanish — it moved to where the surface actually lives:
# the publish-site workflow in zeroroot-ai/www asserts /, /pricing/,
# /contact-sales/, a 404 on an unknown path, and the apex 301, against the
# real hostname on every release.

# ---------------------------------------------------------------------------
step "Docs surface — docs.${DOMAIN}"
# ---------------------------------------------------------------------------
code="$(edge_status "$EDGE" "$DOCS_HOST" "/")"
if [ "$code" = "200" ]; then
  pass "GET https://${DOCS_HOST}/ -> 200"
else
  fail "GET https://${DOCS_HOST}/ -> ${code} (expected 200; docs is core optional-by-toggle and enabled by default per helm/gibson-workloads/values.yaml)"
fi

# ---------------------------------------------------------------------------
step "Dashboard login — app.${DOMAIN}"
# ---------------------------------------------------------------------------
code="$(edge_status "$EDGE" "$APP_HOST" "/login")"
if [ "$code" = "200" ]; then
  pass "GET https://${APP_HOST}/login -> 200"
else
  fail "GET https://${APP_HOST}/login -> ${code} (a 500 here is the IncoherentDeploymentProfileError signature — see deploy#1075: WWW_URL unset on a SaaS dashboard fail-closes every route)"
fi

# On the SaaS profile the dashboard must know the marketing origin, or its host
# resolver fail-closes. This is the in-cluster half of the same invariant.
WWW_URL_SET="$(kubectl -n "$NAMESPACE" get deploy gibson-dashboard \
  -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="WWW_URL")].value}' 2>/dev/null || true)"
if [ -n "$WWW_URL_SET" ]; then
  pass "dashboard WWW_URL is set (${WWW_URL_SET})"
else
  fail "dashboard WWW_URL is unset on a SaaS cluster — deploy#1075 / dashboard#920: the host resolver fail-closes and every route 500s"
fi

# ---------------------------------------------------------------------------
step "Signup flow"
# ---------------------------------------------------------------------------
info "surface checks complete; the signup->tenant flow is scripts/smoke-signup.sh"
info "run: make smoke-signup   (and make stripe-listen, for real webhook delivery)"

summary "verify-saas-surfaces"
