#!/usr/bin/env bash
# exit-test-platform-owner.sh — the Platform owner exit test (ADR-0093,
# hosted#201), run on a kind cluster `make recreate ENV=kind` stood up with
# the CI rung and this directory's Mailpit overlay (test/platform-owner/values.yaml).
#
# In plain words: the platform creates exactly one human Zitadel
# administrator from an install value, that person receives a one-time setup
# link, sets a password, enrolls an authenticator app, and signs in — with
# nobody touching the database or the cluster by hand.
#
# What it proves, in order:
#   1. ONLINE leg: the setup link is delivered to Mailpit (no manual DB
#      touch), the Platform owner sets a password and enrolls TOTP through
#      it, and lands signed in on the Zitadel console.
#   2. The Platform owner holds IAM_OWNER in Zitadel and platform_owner in
#      FGA, and NO tenant role anywhere (ADR-0093 decision 6).
#   3. Raising platformOwner.setupGeneration (a `helm upgrade`, never a
#      live-cluster action) sends a NEW setup link, different from the
#      first, and the Platform owner can sign in again with the new factors.
#   4. OFFLINE leg (--offline mode; the baseline profile's default, no
#      overlay): the operator writes a one-time link to a Secret instead of
#      emailing it, and redeeming that link's code twice fails the second
#      time (single-use). Verifying the code's TTL is expiring is not
#      automated here — see the note at the bottom of this file.
#
# Modes:
#   (default)    the online leg (steps 1-3 above). Requires a cluster
#                installed with test/platform-owner/values.yaml layered on
#                the baseline + CI rung.
#   --offline    the offline leg (step 4). Requires a cluster installed with
#                NO overlay (the baseline profile's own offlineSetup: true).
#   --selftest   offline, no cluster: proves the driver's parsing and TOTP
#                derivation assertions can fail.
#
# Env:
#   NS            namespace                          (default: gibson)
#   RELEASE       the umbrella release name           (default: gibson)
#   DIAG_DIR      where the driver drops failure screenshots (default: unset)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS="${NS:-gibson}"
RELEASE="${RELEASE:-gibson}"
MAILPIT_SVC="${MAILPIT_SVC:-${RELEASE}-mailpit}"
ENVOY_SVC="${ENVOY_SVC:-${RELEASE}-envoy}"
MAILPIT_LOCAL_PORT="${MAILPIT_LOCAL_PORT:-18026}"
ZITADEL_ADMIN_LOCAL_PORT="${ZITADEL_ADMIN_LOCAL_PORT:-18080}"
FGA_LOCAL_PORT="${FGA_LOCAL_PORT:-18081}"

log() { printf '\n\033[1;32m▶\033[0m %s\n' "$*"; }
die() { printf '\033[0;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# --selftest
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  command -v node >/dev/null || die "node is required for the selftest"
  log "driver selftest (setup-link parsing and TOTP derivation can fail)"
  node "${SCRIPT_DIR}/driver.mjs" --selftest

  log "overlay sanity (the online-leg values file names the Mailpit sink)"
  grep -q 'provider: "smtp"' "${SCRIPT_DIR}/values.yaml" \
    || die "selftest: the overlay no longer selects the smtp provider"
  grep -q 'offlineSetup: false' "${SCRIPT_DIR}/values.yaml" \
    || die "selftest: the overlay no longer turns offlineSetup off"
  echo "selftest ok: overlay still wires the daemon to Mailpit for the online leg"
  log "selftest passed"
  exit 0
fi

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
log "preconditions"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
kubectl -n "$NS" get pods --no-headers >/dev/null || die "kubectl cannot reach namespace ${NS}"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib/port-forward-loop.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/port-forward-loop.sh"
cleanup() { pf_stop_all; }
trap cleanup EXIT

# The iam-admin PAT and the FGA store/model ids are the SAME credentials the
# platform-operator itself reads (spec.zitadel.adminTokenRef, the
# gibson-fga-config ConfigMap) — this script asserts state the same way the
# operator establishes it, never by a separate side channel.
IAM_ADMIN_PAT="$(kubectl -n "$NS" get secret iam-admin-pat -o jsonpath='{.data.pat}' | base64 -d)"
FGA_STORE_ID="$(kubectl -n "$NS" get configmap gibson-fga-config -o jsonpath='{.data.store_id}')"
FGA_MODEL_ID="$(kubectl -n "$NS" get configmap gibson-fga-config -o jsonpath='{.data.model_id}')"
[ -n "$IAM_ADMIN_PAT" ] || die "iam-admin-pat Secret has no pat key"
[ -n "$FGA_STORE_ID" ] || die "gibson-fga-config ConfigMap has no store_id key"

DOMAIN="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.domain}' 2>/dev/null || true)"
[ -n "${DOMAIN:-}" ] || die "the gibson-domains ConfigMap names no domain"
APP_HOST="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.appHost}' 2>/dev/null || true)"
[ -n "$APP_HOST" ] || APP_HOST="app.${DOMAIN}"
ISSUER_ORIGIN="https://${APP_HOST}"

EDGE_IP="$(kubectl -n "$NS" get svc "$ENVOY_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
[ -n "$EDGE_IP" ] || EDGE_IP="$(kubectl -n "$NS" get svc "$ENVOY_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
[ -n "${EDGE_IP:-}" ] || die "the ${ENVOY_SVC} Service has no LoadBalancer address"

log "port-forwarding Zitadel's admin API and OpenFGA's HTTP API onto localhost"
pf_loop "$NS" "svc/${RELEASE}-zitadel" "${ZITADEL_ADMIN_LOCAL_PORT}:8080"
pf_loop "$NS" "svc/${RELEASE}-openfga" "${FGA_LOCAL_PORT}:8080"

zitadel_curl() { # <method> <path> [body]
  curl -sS -X "$1" "http://127.0.0.1:${ZITADEL_ADMIN_LOCAL_PORT}$2" \
    -H @<(printf 'Authorization: Bearer %s\n' "${IAM_ADMIN_PAT}") -H 'Content-Type: application/json' \
    -H "x-zitadel-instance-host: ${APP_HOST}" ${3:+-d "$3"}
}
fga_check() { # <user> <relation> <object> -> prints "true"/"false"
  curl -sS -X POST "http://127.0.0.1:${FGA_LOCAL_PORT}/stores/${FGA_STORE_ID}/check" \
    -H 'Content-Type: application/json' \
    -d "{\"tuple_key\":{\"user\":\"$1\",\"relation\":\"$2\",\"object\":\"$3\"},\"authorization_model_id\":\"${FGA_MODEL_ID}\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("allowed", False))'
}

# ---------------------------------------------------------------------------
# Resolve the Platform owner's email and user id from the CR + Zitadel
# ---------------------------------------------------------------------------
PLATFORM_OWNER_EMAIL="$(kubectl get platformbootstrap platform -o jsonpath='{.spec.platformOwner.email}')"
[ -n "$PLATFORM_OWNER_EMAIL" ] || die "spec.platformOwner.email is empty on the platform PlatformBootstrap CR"

log "waiting for PlatformOwnerReady on the platform PlatformBootstrap CR"
for _ in $(seq 1 60); do
  ready="$(kubectl get platformbootstrap platform -o jsonpath='{.status.conditions[?(@.type=="PlatformOwnerReady")].status}' 2>/dev/null || true)"
  [ "$ready" = "True" ] && break
  sleep 5
done
[ "$ready" = "True" ] || die "PlatformOwnerReady never reached True"

PLATFORM_OWNER_USER_ID="$(kubectl get platformbootstrap platform -o jsonpath='{.status.platformOwnerUserID}')"
[ -n "$PLATFORM_OWNER_USER_ID" ] || die "status.platformOwnerUserID is empty even though PlatformOwnerReady is True"
echo "Platform owner: ${PLATFORM_OWNER_EMAIL} (${PLATFORM_OWNER_USER_ID})"

# ---------------------------------------------------------------------------
# --offline leg: the offline setup-link Secret is single-use
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--offline" ]; then
  SECRET_NAME="$(kubectl get platformbootstrap platform -o jsonpath='{.spec.platformOwner.setupSecretRef.name}')"
  [ -n "$SECRET_NAME" ] || die "spec.platformOwner.setupSecretRef.name is empty; this cluster is not in offline mode"
  LINK="$(kubectl -n "$NS" get secret "$SECRET_NAME" -o jsonpath='{.data.setup-link}' | base64 -d)"
  [ -n "$LINK" ] || die "offline setup-link Secret ${SECRET_NAME} has no setup-link key"
  CODE="$(python3 -c "from urllib.parse import urlparse, parse_qs; print(parse_qs(urlparse('$LINK').query)['code'][0])")"
  echo "offline setup link: ${LINK}"

  log "redeeming the offline code once (must succeed)"
  first="$(zitadel_curl POST "/zitadel.user.v2.UserService/VerifyInviteCode" "{\"userId\":\"${PLATFORM_OWNER_USER_ID}\",\"verificationCode\":\"${CODE}\"}")"
  echo "$first"
  echo "$first" | grep -q '"code"' && die "the first redemption of the offline code was refused: $first"

  log "redeeming the SAME offline code a second time (must fail — single-use)"
  second="$(zitadel_curl POST "/zitadel.user.v2.UserService/VerifyInviteCode" "{\"userId\":\"${PLATFORM_OWNER_USER_ID}\",\"verificationCode\":\"${CODE}\"}")"
  echo "$second"
  echo "$second" | grep -q '"code"' || die "the SAME offline code redeemed a second time. It is not single-use"
  echo "offline code is single-use, as required"

  # Expiry is not exercised here: it needs either a configurable short TTL on
  # CreateInviteCode (not exposed by Zitadel's v2 API as a per-call
  # parameter, per the API reference) or waiting out the instance default.
  # Confirm the instance default TTL against the live Zitadel admin console
  # (Instance -> Login Behavior and Security) and decide whether a
  # short-TTL test instance is worth standing up separately.
  echo "NOTE: expiry is NOT exercised by this script — see the comment above VerifyInviteCode"
  exit 0
fi

# ---------------------------------------------------------------------------
# Online leg: preconditions specific to the mail path
# ---------------------------------------------------------------------------
command -v node >/dev/null || die "node not on PATH"
[ -d "${SCRIPT_DIR}/node_modules/playwright" ] \
  || die "playwright is not installed next to the driver. Run: npm --prefix ${SCRIPT_DIR} install && npx --prefix ${SCRIPT_DIR} playwright install --with-deps chromium"
kubectl -n "$NS" get deploy "$MAILPIT_SVC" >/dev/null \
  || die "Mailpit Deployment ${MAILPIT_SVC} is absent. Install with test/platform-owner/values.yaml layered on the baseline"

log "port-forwarding Mailpit's read API"
pf_loop "$NS" "svc/${MAILPIT_SVC}" "${MAILPIT_LOCAL_PORT}:8025"
MAILPIT_URL="http://127.0.0.1:${MAILPIT_LOCAL_PORT}"
for _ in $(seq 1 30); do
  [ "$(curl -so /dev/null -w '%{http_code}' "${MAILPIT_URL}/api/v1/messages" || true)" = "200" ] && break
  sleep 2
done


# The Platform owner reaches the console through the private path only
# (ADR-0093, hosted#437): the same proxy that `make zitadel-console` runs, in
# front of the Zitadel core forward above and a Zitadel login forward. The
# browser maps the app host to it, so the whole setup flow and the console
# load at the public origin without the public edge. First the edge must
# refuse the console on the public host.
CONSOLE_PUBLIC="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
  --resolve "${APP_HOST}:443:${EDGE_IP}" "https://${APP_HOST}/ui/console/" || true)"
[ "$CONSOLE_PUBLIC" = 404 ] \
  || die "EXIT TEST FAILED (hosted#437): the public host answered ${CONSOLE_PUBLIC} for /ui/console/, want the edge refusal 404"
echo "the public host refuses /ui/console/ (HTTP 404)"
# shellcheck source=../../scripts/lib/zitadel-console.sh
. "${SCRIPT_DIR}/../../scripts/lib/zitadel-console.sh"
LOGIN_LOCAL_PORT="${LOGIN_LOCAL_PORT:-18481}"
CONSOLE_PORT="${CONSOLE_PORT:-18443}"
pf_loop "$NS" "svc/${RELEASE}-zitadel-login" "${LOGIN_LOCAL_PORT}:3000"
CONSOLE_WORK="$(mktemp -d)"
console_path_start "$APP_HOST" "${ZITADEL_ADMIN_LOCAL_PORT}" "$LOGIN_LOCAL_PORT" "$CONSOLE_PORT" "$CONSOLE_WORK" \
  || { cat "${CONSOLE_WORK}/console-proxy.log" >&2 2>/dev/null; die "the private console path did not answer on 127.0.0.1:${CONSOLE_PORT}"; }
PF_PIDS+=("$CONSOLE_PROXY_PID")

PASSWORD="Xt1!$(openssl rand -hex 12)"
LINK_FILE="$(mktemp)"; TOTP_FILE="$(mktemp)"
chmod 600 "$LINK_FILE" "$TOTP_FILE"

log "drill: the Platform owner (${PLATFORM_OWNER_EMAIL}) sets up their account"
MAILPIT_URL="$MAILPIT_URL" PLATFORM_OWNER_EMAIL="$PLATFORM_OWNER_EMAIL" \
  ISSUER_ORIGIN="$ISSUER_ORIGIN" PLATFORM_OWNER_PASSWORD="$PASSWORD" \
  CONSOLE_ORIGIN="${ISSUER_ORIGIN}/ui/console" \
  EDGE_IP="127.0.0.1:${CONSOLE_PORT}" EDGE_HOSTS="${APP_HOST}" \
  SETUP_LINK_OUT="$LINK_FILE" TOTP_SECRET_OUT="$TOTP_FILE" \
  DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/driver.mjs" --drill

TOTP_SECRET="$(cat "$TOTP_FILE")"

# ---------------------------------------------------------------------------
# Cluster-side truth: IAM_OWNER + platform_owner, and NO tenant role
# ---------------------------------------------------------------------------
log "asserting IAM_OWNER in Zitadel"
members="$(zitadel_curl GET "/admin/v1/members/_search" '{}')"
echo "$members" | python3 -c "
import json,sys
d = json.load(sys.stdin)
mine = [m for m in d.get('result', []) if m.get('userId') == '${PLATFORM_OWNER_USER_ID}']
assert mine, 'the Platform owner is not an IAM member at all'
assert 'IAM_OWNER' in mine[0].get('roles', []), f'IAM_OWNER missing: {mine[0]}'
print('IAM_OWNER: confirmed')
"

log "asserting platform_owner in FGA"
allowed="$(fga_check "user:${PLATFORM_OWNER_USER_ID}" "platform_owner" "system_tenant:_system")"
[ "$allowed" = "True" ] || die "FGA Check user:${PLATFORM_OWNER_USER_ID} platform_owner system_tenant:_system = ${allowed}, want True"
echo "platform_owner: confirmed"

log "asserting NO tenant role"
for rel in owner admin writer member; do
  for tenant in $(kubectl get tenants.gibson.zeroroot.ai -o jsonpath='{.items[*].metadata.name}'); do
    allowed="$(fga_check "user:${PLATFORM_OWNER_USER_ID}" "$rel" "tenant:${tenant}")"
    [ "$allowed" = "False" ] || die "the Platform owner holds ${rel} on tenant:${tenant} — ADR-0093 decision 6 requires no tenant role"
  done
done
echo "no tenant role anywhere: confirmed"

# ---------------------------------------------------------------------------
# setupGeneration bump: a NEW link, and it still signs in
# ---------------------------------------------------------------------------
log "bumping platformOwner.setupGeneration through a helm upgrade (never a live-cluster action)"
CURRENT_GEN="$(kubectl get platformbootstrap platform -o jsonpath='{.spec.platformOwner.setupGeneration}')"
NEXT_GEN=$((CURRENT_GEN + 1))
helm upgrade "$RELEASE" oci://ghcr.io/zeroroot-ai/charts/gibson \
  --reuse-values --set "global.platformOwner.setupGeneration=${NEXT_GEN}" \
  --namespace "$NS" --wait --timeout 10m

log "waiting for a NEW setup link after the generation bump"
MAILPIT_URL="$MAILPIT_URL" PLATFORM_OWNER_EMAIL="$PLATFORM_OWNER_EMAIL" \
  ISSUER_ORIGIN="$ISSUER_ORIGIN" PREVIOUS_LINK_FILE="$LINK_FILE" \
  node "${SCRIPT_DIR}/driver.mjs" --reset

log "asserting the Platform owner's OLD factors were cleared (ClearHumanFactors)"
methods="$(zitadel_curl POST "/zitadel.user.v2.UserService/ListAuthenticationMethodTypes" "{\"userId\":\"${PLATFORM_OWNER_USER_ID}\"}")"
echo "$methods" | grep -q 'AUTHENTICATION_METHOD_TYPE_TOTP' \
  && die "the old TOTP factor is still registered after a setupGeneration bump: $methods"
echo "old factors cleared: confirmed"

rm -f "$LINK_FILE" "$TOTP_FILE"
log "EXIT TEST PASSED: the Platform owner was created from an install value, received a setup link, holds IAM_OWNER + platform_owner and no tenant role, and setupGeneration correctly resets and re-invites"
