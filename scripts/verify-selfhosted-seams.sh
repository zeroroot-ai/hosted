#!/usr/bin/env bash
# verify-selfhosted-seams.sh — live self-hosted seam verification (deploy#1039).
#
# Covers deploy#1039's acceptance criteria on a running self-hosted cluster:
#   - GET / resolves to the login page (no marketing surface)
#   - the SignupService self-serve path agrees with the deployed signup seam
#   - the operator-seeded first tenant converges and its Owner bootstrap Job succeeded
#   - docs are served at docs.<domain>, version-matched to the install
#   - www/marketing is not served by this cluster at all (404, no vhost)
#
# A NOTE ON THE SIGNUP CRITERION, because it is not as written
# ------------------------------------------------------------
# deploy#1039 says the self-serve path must return admin-only PermissionDenied.
# That is true only when the front door is closed. ADR-0074 §4 (as amended
# 2026-08-13, deploy#1039) matches the shipped default: self-serve signup is
# ON in both profiles (signupSelfServe: true — GitLab self-managed model),
# and closed registration is the operator override signupSelfServe: false.
# See helm/gibson/values-baseline.yaml (+ values-eks.yaml on
# EKS) and the assertion at
# helm/gibson/tests/signup-seam.bats ("open card-free signup is the shipped
# OSS default").
#
# The suite therefore reads the deployed SIGNUP_SELF_SERVE value and asserts
# the RPC BEHAVIOUR MATCHES IT in both directions:
#   SIGNUP_SELF_SERVE unset/false -> Signup MUST return PermissionDenied
#   SIGNUP_SELF_SERVE true        -> Signup MUST NOT return PermissionDenied
# Either way the seam is proven coherent — both postures are owner-endorsed,
# so neither direction is hard-coded as "the" correct one.
#
# Usage:
#   scripts/verify-selfhosted-seams.sh
#   make verify-selfhosted-seams
#
# Env:
#   NAMESPACE      k8s namespace                     (default: gibson)
#   DOMAIN         platform domain                   (default: from the gibson-domains ConfigMap)
#   EDGE_ADDR      override derived edge <ip>:<port> (default: from the Envoy Service)
#   FIRST_TENANT       operator-seeded first tenant slug   (default: the one seeded Tenant CR)
#   FIRST_ADMIN_SECRET offline setup-link Secret name, checked only if present
#                      (default: gibson-first-tenant-owner-setup)
#   GRPCURL_IMAGE  (default: fullstorydev/grpcurl:v1.9.1-alpine)
#
# Exit: 0 all assertions passed · 1 an assertion failed · 2 preflight failed
#
# Preflight failure is exit 2 and is NOT a pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cluster-probe.sh
source "${SCRIPT_DIR}/lib/cluster-probe.sh"

NAMESPACE="${NAMESPACE:-gibson}"

# The install states its own domain in the gibson-domains ConfigMap, so read
# it from the cluster instead of guessing. The previous default (zeroroot.ai)
# probed hosts the install's Envoy does not serve: the SNI filter chains reset
# the handshake, every probe answered 000, and the suite reported ten product
# failures that were all the same wrong host (deploy#1766, run 33609089563).
# The env var stays as an override for probing an install whose ConfigMap is
# itself under suspicion.
if [ -z "${DOMAIN:-}" ]; then
  DOMAIN="$(kubectl -n "$NAMESPACE" get configmap gibson-domains     -o jsonpath='{.data.domain}' 2>/dev/null || true)"
fi
[ -n "${DOMAIN:-}" ] || DOMAIN="zeroroot.ai"

# The first tenant is seeded by the tenant-operator (global.firstTenant), not
# by this script — gibson#1496. Read the seeded Tenant CR from the cluster: a
# fresh install has exactly one, and a hardcoded default cannot work ("default"
# is on the reserved-names denylist, so no install can ever seed it). The env
# var stays as an override for a cluster with more than one tenant.
if [ -z "${FIRST_TENANT:-}" ]; then
  FIRST_TENANT="$(kubectl get tenants.gibson.zeroroot.ai     -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
fi
[ -n "${FIRST_TENANT:-}" ] || FIRST_TENANT="default"
FIRST_ADMIN_SECRET="${FIRST_ADMIN_SECRET:-gibson-first-tenant-owner-setup}"
GRPCURL_IMAGE="${GRPCURL_IMAGE:-fullstorydev/grpcurl:v1.9.1-alpine}"

WWW_HOST="www.${DOMAIN}"
DOCS_HOST="docs.${DOMAIN}"
APP_HOST="app.${DOMAIN}"

# ---------------------------------------------------------------------------
step "Preflight"
# ---------------------------------------------------------------------------
probe_cluster "$NAMESPACE"

# Refuse to run against a SaaS cluster: these assertions would be checking the
# opposite of that cluster's correct behaviour.
require_profile "$NAMESPACE" "self-hosted"

require_workload "$NAMESPACE" deploy gibson-dashboard "the login front door"

EDGE="$(resolve_edge "$NAMESPACE")" \
  || preflight_die "no usable Envoy edge in ns/${NAMESPACE} — cannot determine the edge address to probe"
pass "edge resolved to ${EDGE}"

# ---------------------------------------------------------------------------
step "Front door — GET / is login, not marketing"
# ---------------------------------------------------------------------------
# ADR-0074 §4: "Self-hosted GET / is the login page (no marketing)."
# dashboard/src/lib/host-routing.ts:19-20: with WWW_URL unset there is no host
# split, so GET / renders the root page, which redirects to /login.
ROOT_CODE="$(edge_status "$EDGE" "$APP_HOST" "/")"
case "$ROOT_CODE" in
  200|302|307)
    pass "GET https://${APP_HOST}/ -> ${ROOT_CODE}"
    ;;
  *)
    fail "GET https://${APP_HOST}/ -> ${ROOT_CODE} (expected 200 or a redirect to /login)"
    ;;
esac

ROOT_BODY="$(edge_body "$EDGE" "$APP_HOST" "/")"
if [ -z "$ROOT_BODY" ] && [ "$ROOT_CODE" = "200" ]; then
  fail "GET / returned 200 with an empty body — cannot establish what it served"
elif printf '%s' "$ROOT_BODY" | grep -qiE 'sign in|log in|login'; then
  pass "GET / serves the login surface"
else
  fail "GET / body carries no login affordance — self-hosted must not serve marketing here"
fi

# The marketing pages the dashboard shed (dashboard#911 / ADR-0074) must not be
# reachable on the self-hosted app host.
for path in /pricing /contact-sales /features; do
  code="$(edge_status "$EDGE" "$APP_HOST" "$path")"
  if [ "$code" = "404" ] || [ "$code" = "302" ] || [ "$code" = "307" ]; then
    pass "GET ${path} -> ${code} (marketing page not served on self-hosted)"
  elif [ "$code" = "200" ]; then
    fail "GET https://${APP_HOST}${path} -> 200 — a marketing page is being served on a self-hosted install (ADR-0074: marketing is SaaS-only)"
  else
    fail "GET https://${APP_HOST}${path} -> ${code} (unexpected; expected 404 or a redirect)"
  fi
done

# ---------------------------------------------------------------------------
step "www is not served by this cluster"
# ---------------------------------------------------------------------------
# The marketing site is an off-cluster surface (ADR-0077): no chart
# deploys it in either audience, and the www virtual_host has been removed from
# the edge entirely.
#
# The assertion therefore INVERTED. It used to be 503 — vhost present, no
# endpoints. A 503 now would mean the vhost came back, which is the regression
# this guards: a cluster claiming www.<domain> takes the hostname from the CDN
# and black-holes the public marketing site. With no vhost, the edge matches no
# virtual_host and answers 404.
WWW_CODE="$(edge_status "$EDGE" "$WWW_HOST" "/")"
case "$WWW_CODE" in
  404)
    pass "GET https://${WWW_HOST}/ -> 404 (no www vhost — the marketing site is off-cluster)"
    ;;
  503)
    fail "GET https://${WWW_HOST}/ -> 503 — a www vhost has returned to the edge. Remove it: this cluster must not claim www.<domain> (ADR-0077)."
    ;;
  200)
    fail "GET https://${WWW_HOST}/ -> 200 — this cluster is serving a marketing surface it must not own"
    ;;
  *)
    fail "GET https://${WWW_HOST}/ -> ${WWW_CODE} (expected 404; 000 means the edge itself is unreachable, which is a different defect)"
    ;;
esac

# ---------------------------------------------------------------------------
step "Signup seam coherence"
# ---------------------------------------------------------------------------
SELF_SERVE="$(kubectl -n "$NAMESPACE" get statefulset,deploy -o json 2>/dev/null \
  | grep -o '"name":"SIGNUP_SELF_SERVE","value":"[^"]*"' \
  | head -1 | sed 's/.*"value":"\([^"]*\)"/\1/' || true)"

if [ -z "$SELF_SERVE" ]; then
  SELF_SERVE="false"
  info "SIGNUP_SELF_SERVE is absent from every workload -> the seam's fail-safe (admin-only) is active"
else
  info "SIGNUP_SELF_SERVE=${SELF_SERVE} on the deployed workloads"
fi

# The probe pod runs IN the cluster, so it dials the Envoy edge Service by
# DNS — never $EDGE, which is where the OPERATOR reaches the edge from
# outside (with EDGE_ADDR=127.0.0.1:443 the pod would dial its own loopback
# and read the refusal as a product failure — deploy#1766, run 33609089563).
IN_CLUSTER_EDGE="gibson-envoy.${NAMESPACE}.svc.cluster.local:443"
API_HOST_PORT="api.${DOMAIN} at ${IN_CLUSTER_EDGE}"
# NOTE: this script runs under `set -uo pipefail` WITHOUT -e, deliberately, so a
# failing probe increments the counter instead of aborting the suite (the
# verify-profile.sh convention). Do not add a `set -e` around these probes —
# cutover-smoke.sh needs the `set +e`/`set -e` dance only because it runs with
# errexit on. Here errexit is already off and `set -e` would silently change the
# failure semantics of everything after this point.
SIGNUP_OUT="$(kubectl -n "$NAMESPACE" run "signup-seam-probe-$$" \
  --rm -i --restart=Never --quiet --timeout=90s \
  --image="$GRPCURL_IMAGE" --command -- \
  /bin/grpcurl -insecure -d '{"email":"seam-probe@invalid.test","tenant_slug":"seam-probe"}' \
  -authority "api.${DOMAIN}" \
  "$IN_CLUSTER_EDGE" gibson.signup.v1.SignupService/Signup 2>&1)"
SIGNUP_RC=$?

if [ "$SIGNUP_RC" -eq 0 ] && printf '%s' "$SIGNUP_OUT" | grep -qi 'unable to\|could not\|no such host\|connection refused'; then
  fail "SignupService probe could not reach the daemon (${API_HOST_PORT}): ${SIGNUP_OUT}"
elif printf '%s' "$SIGNUP_OUT" | grep -qi 'permissiondenied\|permission denied'; then
  if [ "$SELF_SERVE" = "true" ]; then
    fail "SignupService returned PermissionDenied while SIGNUP_SELF_SERVE=true — the seam and the deployed config disagree"
  else
    pass "SignupService returns PermissionDenied with self-serve off (admin-only fail-safe active)"
  fi
else
  if [ "$SELF_SERVE" = "true" ]; then
    pass "SignupService does not deny with SIGNUP_SELF_SERVE=true (seam coherent; the shipped open default per ADR-0074 §4 as amended, deploy#1039)"
  else
    fail "SignupService did NOT return PermissionDenied with self-serve off — the admin-only fail-safe is not enforced. Response: ${SIGNUP_OUT}"
  fi
fi

# ---------------------------------------------------------------------------
step "First-admin bring-up — operator-seeded tenant + setup-link Owner"
# ---------------------------------------------------------------------------
# gibson#1496: the first tenant is seeded WITHOUT a session. The tenant-operator
# enqueues it over its SPIFFE identity (EnqueueTenantProvisioning), because the
# interactive AdminProvisionTenant RPC is gated by a session-revocation check no
# headless caller satisfies — the very failure this design removes. So the seam
# is verified by its OBSERVABLE END STATE on the running install, not by poking
# the removed path: the seeded tenant CR converges, and the first-admin Job
# succeeded. Both are idempotent, so re-running this suite is safe.
#
# ADR-0093 (hosted#202): no password is ever generated or stored. The Job's
# own success is the proof of completion; the offline setup-link Secret, if
# present, is checked for a link and asserted to carry no password.
if ! kubectl -n "$NAMESPACE" get tenant "$FIRST_TENANT" >/dev/null 2>&1; then
  fail "first tenant ${FIRST_TENANT} does not exist — the operator seed (global.firstTenant → EnqueueTenantProvisioning) never produced a Tenant CR"
else
  # The seeded tenant must converge, not merely exist.
  DEADLINE=$(( $(date +%s) + 180 ))
  PHASE=""
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    PHASE="$(kubectl -n "$NAMESPACE" get tenant "$FIRST_TENANT" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$PHASE" in Ready|Active) break ;; esac
    sleep 5
  done
  case "$PHASE" in
    Ready|Active)
      pass "operator-seeded tenant ${FIRST_TENANT} reached phase=${PHASE}"
      ;;
    *)
      fail "operator-seeded tenant ${FIRST_TENANT} did not reach Ready within 180s (phase=${PHASE:-<absent>})"
      kubectl -n "$NAMESPACE" get tenant "$FIRST_TENANT" \
        -o go-template='{{range .status.conditions}}  {{.type}}: {{.status}} ({{.reason}}) {{.message}}{{"\n"}}{{end}}' 2>/dev/null || true
      ;;
  esac

  # The seeded tenant must report a Zitadel org — it is what the first-admin Job
  # waits on before it can create the owner user.
  ORG="$(kubectl -n "$NAMESPACE" get tenant "$FIRST_TENANT" -o jsonpath='{.status.zitadelOrgID}' 2>/dev/null || true)"
  if [ -n "$ORG" ]; then
    pass "tenant ${FIRST_TENANT} reports a Zitadel org (${ORG})"
  else
    fail "tenant ${FIRST_TENANT} has no status.zitadelOrgID — the first-admin Job cannot create the owner"
  fi

  # The first-admin Job's proof of completion (ADR-0093, hosted#202): the Job
  # itself succeeded. No password Secret exists to check for any more.
  JOB_SUCCEEDED="$(kubectl -n "$NAMESPACE" get job gibson-gibson-workloads-first-admin \
    -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  if [ "$JOB_SUCCEEDED" = "1" ]; then
    pass "first-admin Job succeeded (owner provisioned with no password; a one-time setup link was sent)"
  else
    fail "first-admin Job did not report success (status.succeeded=${JOB_SUCCEEDED:-<absent>}) — the first-admin Job did not complete, so nobody can log in"
  fi

  # Offline installs only: the setup-link Secret exists and holds a link,
  # never a password.
  if kubectl -n "$NAMESPACE" get secret "$FIRST_ADMIN_SECRET" >/dev/null 2>&1; then
    if kubectl -n "$NAMESPACE" get secret "$FIRST_ADMIN_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | grep -q .; then
      fail "offline setup-link Secret ${FIRST_ADMIN_SECRET} carries a password field — no password may ever be written to a Secret (ADR-0093)"
    else
      pass "offline setup-link Secret ${FIRST_ADMIN_SECRET} exists and carries no password"
    fi
  fi
fi

# ---------------------------------------------------------------------------
step "Docs surface — served and version-matched"
# ---------------------------------------------------------------------------
DOCS_CODE="$(edge_status "$EDGE" "$DOCS_HOST" "/")"
if [ "$DOCS_CODE" = "200" ]; then
  pass "GET https://${DOCS_HOST}/ -> 200"
else
  fail "GET https://${DOCS_HOST}/ -> ${DOCS_CODE} (docs is core optional-by-toggle and default-on)"
fi

# Version-match: the dashboard's DOCS_URL must point at THIS install's docs host,
# not at the public fallback, when local docs are enabled.
DOCS_URL="$(kubectl -n "$NAMESPACE" get deploy gibson-dashboard \
  -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="DOCS_URL")].value}' 2>/dev/null || true)"
if [ -z "$DOCS_URL" ]; then
  fail "dashboard DOCS_URL is unset — the docs seam is not wired"
elif printf '%s' "$DOCS_URL" | grep -q "${DOCS_HOST}"; then
  pass "dashboard DOCS_URL points at the in-cluster docs host (${DOCS_URL})"
else
  fail "dashboard DOCS_URL=${DOCS_URL} does not reference ${DOCS_HOST} — local docs are enabled but the dashboard links elsewhere"
fi

# The running docs image must be the one this chart release pinned. A drifted
# docs-svc is the concrete failure mode behind "version-matched to the install".
DOCS_IMAGE="$(kubectl -n "$NAMESPACE" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
  | grep -m1 'docs' | cut -d= -f2- || true)"
if [ -z "$DOCS_IMAGE" ]; then
  fail "no docs-svc Deployment found — docs.enabled is true at the edge but no workload serves it"
else
  pass "docs-svc runs ${DOCS_IMAGE}"
  info "version-match caveat: helm/gibson-workloads/values.yaml pins docs.image.digest, which overrides the .Chart.AppVersion default — so the shipped image tracks a docs-site build, not the install version. The toggle-off fallback path is covered offline by helm/gibson-workloads/tests/docs-seam.bats."
fi

summary "verify-selfhosted-seams"
