#!/usr/bin/env bash
# exit-test-identity.sh — the identity model exit test (hosted#208): one
# install proves the whole model the way a customer meets it. Supersedes
# charts#160, whose password sign-in no longer exists (ADR-0093).
#
# In plain words: the Platform owner and the first tenant's Owner each set
# themselves up from a one-time link and enroll TOTP, the Owner invites a
# teammate who accepts and lands with the invited role, the Owner changes
# that role and FGA reflects it, the Owner recovers a teammate's lost
# authenticator, and the Owner removes a teammate — each step proven against
# a live cluster, never against a database or a Secret assumption.
#
# Reuses, never duplicates:
#   - test/platform-owner/driver.mjs for every password+TOTP browser step
#     (the Platform owner, the first tenant's Owner, and the invitee all
#     complete their setup link through this ONE driver — ADR-0027).
#   - the gibson-login device-flow shape test/demo/exit-test-enrollment.sh
#     established (Zitadel Session API + OIDC device grant, approved with no
#     browser through the cluster's own login-client credential) for minting
#     the bearer tokens the daemon's customer-callable RPCs need. Mirrored
#     here, not sourced, so a change to one exit test's shape cannot silently
#     break the other (the same choice driver.mjs's own header comment
#     documents for its mirrored findMessageFor helper).
#
# Modes:
#   --selftest   offline, no cluster: proves the driver's own assertions can
#                fail (delegates to test/platform-owner/driver.mjs --selftest)
#                and that this overlay still selects Mailpit for both legs.
#   --online     (default) the online leg: steps 1 to 6 below, against a
#                cluster installed with test/identity/values.yaml layered on
#                the baseline + CI rung.
#   --offline    the offline leg: a cluster installed with NO overlay (the
#                baseline profile's own offlineSetup: true for both). Proves
#                both setup links start at the public host from Secrets, and
#                that no password Secret is ever created (gibson-first-admin
#                must be NotFound — the pre-ADR-0093 model charts#160 tested
#                is gone).
#
# Steps (online leg), each a hard assertion that fails loudly and names
# itself:
#   1. The Platform owner's AND the first tenant's Owner's setup links arrive
#      in Mailpit (not only in a Secret) and start at the public host.
#   2. Both set a password and enroll TOTP through driver.mjs, programmatically.
#   3. The Owner invites a new address; the invite mail arrives with a link at
#      the app host; the invitee accepts, enrolls, and lands in the tenant
#      with the invited role.
#   4. The Owner changes that role; the FGA tuple reflects it within seconds.
#   5. MFA reset: the target's session is refused, and the notice email goes
#      to the target's own address only.
#   6. Removal: the removed user's open session is refused, and the Zitadel
#      account is gone.
#
# Env:
#   NS, RELEASE                namespace / umbrella release (default: gibson)
#   GIBSON_BIN                 the adk CLI                  (default: gibson)
#   GIBSON_SRC                 a zeroroot-ai/gibson checkout, for the tenant
#                               proto schema
#   FIRST_TENANT_OWNER_EMAIL   the seeded Owner's email (default:
#                               admin@localhost.zeroroot.ai)
#   INVITEE_EMAIL              the address the Owner invites (default:
#                               teammate@localhost.zeroroot.ai)
#   DIAG_DIR                   where failure screenshots/diagnostics land
#
# Needs: kubectl, curl, jq, openssl, python3, node (+ test/platform-owner's
# playwright/otpauth deps), buf, the adk CLI (gibson).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS="${NS:-gibson}"
RELEASE="${RELEASE:-gibson}"
MAILPIT_SVC="${MAILPIT_SVC:-${RELEASE}-mailpit}"
ENVOY_SVC="${ENVOY_SVC:-${RELEASE}-envoy}"
ZITADEL_SVC="${ZITADEL_SVC:-${RELEASE}-zitadel}"
FGA_SVC="${FGA_SVC:-${RELEASE}-openfga}"
MAILPIT_LOCAL_PORT="${MAILPIT_LOCAL_PORT:-18026}"
ZITADEL_LOCAL_PORT="${ZITADEL_LOCAL_PORT:-18080}"
FGA_LOCAL_PORT="${FGA_LOCAL_PORT:-18081}"
GIBSON_BIN="${GIBSON_BIN:-gibson}"
# The sdk schema is the one the installed gibson was built against: the
# BSR label of the sdk version in gibson's go.mod. The unpinned module is
# BSR's latest push, which lagged the release gibson used and broke every
# proto option (run 36633990113: sdk v0.183.1 never reached BSR).
if [ -z "${SDK_SCHEMA:-}" ] && [ -f "${GIBSON_SRC:-}/go.mod" ]; then
  SDK_VERSION="$(awk '$1 == "github.com/zeroroot-ai/sdk" {print $2; exit}' "${GIBSON_SRC}/go.mod")"
  [ -n "$SDK_VERSION" ] && SDK_SCHEMA="buf.build/zeroroot-ai/sdk:${SDK_VERSION}"
fi
SDK_SCHEMA="${SDK_SCHEMA:-buf.build/zeroroot-ai/sdk}"

log() { printf '\n\033[1;32m▶\033[0m %s\n' "$*"; }
die() { printf '\033[0;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Pure helpers (selftested indirectly through the driver + fixtures below)
# ---------------------------------------------------------------------------

# jwt_sub prints the `sub` claim of a JWT, or nothing. Mirrors
# test/demo/exit-test-enrollment.sh's helper of the same name: the api edge
# only accepts JWTs, so an opaque token here is a real defect, not this
# script's problem to paper over.
jwt_sub() {
  local payload
  payload="$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.sub // empty' 2>/dev/null || true
}

# extract_invite_link <mail body> <app origin> -> the accept link, or nothing.
# InviteMember's link shape is "<GIBSON_APP_URL>/invite/<token>"
# (internal/server/admin/invitation_handlers.go), never a query-param link
# like the setup-link flow — a different shape, so a different extractor.
extract_invite_link() {
  local raw
  raw="$(grep -oE "https?://[^\"'<> ]+/invite/[A-Za-z0-9_.~-]+" <<<"$1" | head -1)"
  case "$raw" in
    "$2"/invite/*) printf '%s' "$raw" ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# --selftest: offline, no cluster
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  command -v node >/dev/null || die "node is required for the selftest"
  log "driver selftest (setup-link parsing and TOTP derivation can fail)"
  node "${SCRIPT_DIR}/../platform-owner/driver.mjs" --selftest

  log "overlay sanity (this leg selects the Mailpit sink for BOTH setup links)"
  grep -q 'provider: "smtp"' "${SCRIPT_DIR}/values.yaml" \
    || die "selftest: the overlay no longer selects the smtp provider"
  grep -q 'offlineSetup: false' "${SCRIPT_DIR}/values.yaml" \
    || die "selftest: the overlay must turn offlineSetup off"
  grep -A2 'platformOwner:' "${SCRIPT_DIR}/values.yaml" | grep -q 'offlineSetup: false' \
    || die "selftest: the Platform owner's offlineSetup is not turned off"
  grep -A2 'firstTenant:' "${SCRIPT_DIR}/values.yaml" | grep -q 'offlineSetup: false' \
    || die "selftest: the first tenant's offlineSetup is not turned off"
  echo "selftest ok: the overlay wires the daemon to Mailpit for both setup links"

  log "extract_invite_link"
  link="$(extract_invite_link 'Hi,
Accept your invitation:
https://app.localhost.zeroroot.ai/invite/tok-abc123

Thanks' "https://app.localhost.zeroroot.ai")"
  [ "$link" = "https://app.localhost.zeroroot.ai/invite/tok-abc123" ] \
    || die "selftest: extract_invite_link parsed '${link}', want the accept link"
  echo "selftest ok: the accept link is extracted"

  if extract_invite_link 'click https://evil.example.com/invite/tok-abc123' "https://app.localhost.zeroroot.ai" >/dev/null 2>&1; then
    die "selftest: a link on a non-product origin was accepted"
  fi
  echo "selftest ok: a non-product-origin invite link is refused"

  if extract_invite_link 'no link here at all' "https://app.localhost.zeroroot.ai" >/dev/null 2>&1; then
    die "selftest: a mail with no invite link was accepted"
  fi
  echo "selftest ok: a mail with no invite link is refused"

  log "jwt_sub"
  hdr="$(printf '{"alg":"RS256"}' | base64 -w0 | tr -d '=')"
  body="$(printf '{"sub":"123456","iat":1}' | base64 -w0 | tr -d '=')"
  sub="$(jwt_sub "${hdr}.${body}.sig")"
  [ "$sub" = "123456" ] || die "selftest: jwt_sub gave '${sub}', want 123456"
  sub="$(jwt_sub "opaque-token-with-no-dots")"
  [ -z "$sub" ] || die "selftest: an opaque token yielded a subject"
  echo "selftest ok: the subject comes from a JWT and an opaque token gives none"

  log "selftest passed: every assertion can fail"
  exit 0
fi

# ---------------------------------------------------------------------------
# Shared preconditions (both legs)
# ---------------------------------------------------------------------------
MODE="online"
case "${1:-}" in
  --online) MODE="online" ;;
  --offline) MODE="offline" ;;
  "") MODE="online" ;;
  *) die "usage: $0 [--online|--offline|--selftest]" ;;
esac

command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v curl >/dev/null || die "curl not on PATH"
command -v jq >/dev/null || die "jq not on PATH"
command -v python3 >/dev/null || die "python3 not on PATH"
kubectl -n "$NS" get pods --no-headers >/dev/null || die "kubectl cannot reach namespace ${NS}"

WORK="${WORK_DIR:-$(mktemp -d)}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib/port-forward-loop.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/port-forward-loop.sh"
cleanup() { pf_stop_all; }
trap cleanup EXIT

DOMAIN="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.domain}' 2>/dev/null || true)"
[ -n "${DOMAIN:-}" ] || die "the gibson-domains ConfigMap names no domain"
APP_HOST="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.appHost}' 2>/dev/null || true)"
[ -n "$APP_HOST" ] || APP_HOST="app.${DOMAIN}"
API_HOST="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.apiHost}' 2>/dev/null || true)"
[ -n "$API_HOST" ] || API_HOST="api.${DOMAIN}"
ISSUER_ORIGIN="https://${APP_HOST}"
export ISSUER_ORIGIN

EDGE_IP="$(kubectl -n "$NS" get svc "$ENVOY_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
[ -n "$EDGE_IP" ] || EDGE_IP="$(kubectl -n "$NS" get svc "$ENVOY_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
[ -n "${EDGE_IP:-}" ] || die "the ${ENVOY_SVC} Service has no LoadBalancer address"

# ===========================================================================
# --offline leg: the baseline as shipped. No mail, no password Secret.
# ===========================================================================
if [ "$MODE" = "offline" ]; then
  log "offline leg: both setup links start at the public host, from Secrets"

  PLATFORM_SECRET="$(kubectl get platformbootstrap platform -o jsonpath='{.spec.platformOwner.setupSecretRef.name}' 2>/dev/null || true)"
  [ -n "$PLATFORM_SECRET" ] || die "spec.platformOwner.setupSecretRef.name is empty; this cluster is not in offline mode"
  PLATFORM_LINK=""
  for _ in $(seq 1 60); do
    PLATFORM_LINK="$(kubectl -n "$NS" get secret "$PLATFORM_SECRET" -o jsonpath='{.data.setup-link}' 2>/dev/null | base64 -d || true)"
    [ -n "$PLATFORM_LINK" ] && break
    sleep 5
  done
  [ -n "$PLATFORM_LINK" ] || die "Secret ${PLATFORM_SECRET} has no setup-link — the Platform owner was never created"
  case "$PLATFORM_LINK" in
    "${ISSUER_ORIGIN}"/*) pass "the Platform owner's offline link starts at the public host (${ISSUER_ORIGIN})" ;;
    *) die "the Platform owner's offline link '${PLATFORM_LINK}' does not start at ${ISSUER_ORIGIN} — it must never name the in-cluster Zitadel Service (gibson#254 class of bug)" ;;
  esac

  # firstTenant is a Helm value (global.firstTenant), not a PlatformBootstrap
  # CR field — there is nothing on the CR to read this back from, so the
  # Secret name is the baseline profile's own value, overridable for a
  # non-default install.
  FIRST_TENANT_SECRET="${FIRST_TENANT_SECRET:-gibson-first-tenant-owner-setup}"
  FIRST_TENANT_LINK=""
  for _ in $(seq 1 60); do
    FIRST_TENANT_LINK="$(kubectl -n "$NS" get secret "$FIRST_TENANT_SECRET" -o jsonpath='{.data.setup-link}' 2>/dev/null | base64 -d || true)"
    [ -n "$FIRST_TENANT_LINK" ] && break
    sleep 5
  done
  [ -n "$FIRST_TENANT_LINK" ] || die "Secret ${FIRST_TENANT_SECRET} has no setup-link — the first-admin Job did not complete"
  case "$FIRST_TENANT_LINK" in
    "${ISSUER_ORIGIN}"/*) pass "the first tenant Owner's offline link starts at the public host (${ISSUER_ORIGIN})" ;;
    *) die "the first tenant Owner's offline link '${FIRST_TENANT_LINK}' does not start at ${ISSUER_ORIGIN} — it must never name the in-cluster Zitadel Service (gibson#254 class of bug)" ;;
  esac

  log "no password Secret exists anywhere on this install (ADR-0093 supersedes charts#160's password model)"
  if kubectl -n "$NS" get secret gibson-first-admin >/dev/null 2>&1; then
    die "Secret gibson-first-admin EXISTS — the pre-ADR-0093 password model is back. No password is ever generated or stored (ADR-0093 decision 8)."
  fi
  pass "gibson-first-admin is NotFound, as required"

  log "EXIT TEST PASSED (offline leg): both setup links are delivered by Secret, start at the public host, and no password Secret exists"
  exit 0
fi

# ===========================================================================
# --online leg
# ===========================================================================
command -v node >/dev/null || die "node not on PATH"
command -v buf >/dev/null || die "buf not on PATH"
command -v openssl >/dev/null || die "openssl not on PATH"
command -v "$GIBSON_BIN" >/dev/null || die "the adk CLI is not on PATH (GIBSON_BIN=${GIBSON_BIN})"
[ -d "${SCRIPT_DIR}/../platform-owner/node_modules/playwright" ] \
  || die "playwright is not installed next to the driver. Run: npm --prefix ${SCRIPT_DIR}/../platform-owner install && npx --prefix ${SCRIPT_DIR}/../platform-owner playwright install --with-deps chromium"
if [ -z "${GIBSON_SRC:-}" ] || [ ! -d "${GIBSON_SRC}/internal/server/daemon/api" ]; then
  die "GIBSON_SRC must point at a zeroroot-ai/gibson checkout with internal/server/daemon/api (the tenant proto schema)"
fi
kubectl -n "$NS" get deploy "$MAILPIT_SVC" >/dev/null \
  || die "Mailpit Deployment ${MAILPIT_SVC} is absent. Install with test/identity/values.yaml layered on the baseline"

FIRST_TENANT_OWNER_EMAIL="${FIRST_TENANT_OWNER_EMAIL:-admin@localhost.zeroroot.ai}"
INVITEE_EMAIL="${INVITEE_EMAIL:-teammate@localhost.zeroroot.ai}"

log "waiting for the seeded tenant to be Ready and its founding member Active"
TENANT="$(kubectl get tenants.gibson.zeroroot.ai -o jsonpath='{.items[0].metadata.name}')"
[ -n "$TENANT" ] || die "the install seeded no Tenant CR"
kubectl wait --for=jsonpath='{.status.phase}'=Ready "tenant/${TENANT}" --timeout=15m
# ADR-0093, hosted#202: no password is ever generated or stored, so the
# first-admin Job's own completion is the signal, not a credential Secret's
# existence (mirrors .github/actions/demo-enrollment-install/action.yml).
kubectl -n "$NS" wait --for=condition=complete "job/${RELEASE}-gibson-workloads-first-admin" --timeout=15m
phase=""
for _ in $(seq 1 90); do
  phase="$(kubectl -n "tenant-${TENANT}" get tenantmembers.gibson.zeroroot.ai -o jsonpath='{.items[?(@.spec.role=="owner")].status.phase}' 2>/dev/null || true)"
  [ "$phase" = "Active" ] && break
  sleep 10
done
[ "$phase" = "Active" ] || die "the founding member's phase is '${phase:-<absent>}', want Active (gibson#1510)"
pass "tenant ${TENANT} is Ready, founding member Active"

log "port-forwarding Mailpit, Zitadel, and OpenFGA"
pf_loop "$NS" "svc/${MAILPIT_SVC}" "${MAILPIT_LOCAL_PORT}:8025"
pf_loop "$NS" "svc/${ZITADEL_SVC}" "${ZITADEL_LOCAL_PORT}:8080"
pf_loop "$NS" "svc/${FGA_SVC}" "${FGA_LOCAL_PORT}:8080"
MAILPIT_URL="http://127.0.0.1:${MAILPIT_LOCAL_PORT}"
ZURL="http://127.0.0.1:${ZITADEL_LOCAL_PORT}"
for _ in $(seq 1 30); do
  [ "$(curl -so /dev/null -w '%{http_code}' "${MAILPIT_URL}/api/v1/messages" || true)" = "200" ] && break
  sleep 2
done

FGA_STORE_ID="$(kubectl -n "$NS" get configmap gibson-fga-config -o jsonpath='{.data.store_id}')"
[ -n "$FGA_STORE_ID" ] || die "gibson-fga-config ConfigMap has no store_id key"
FGA_MODEL_ID="$(kubectl -n "$NS" get configmap gibson-fga-config -o jsonpath='{.data.model_id}' 2>/dev/null || true)"
# OpenFGA's HTTP API is TLS on :8080 (charts: gibson-openfga-http-tls).
# curl reaches it through the port-forward under the certificate's own
# name, so the certificate is verified, not skipped. Run 36455195697 sent
# plain http here, got a non-JSON reply, and read it as a missing role.
FGA_HOST="${FGA_SVC}.${NS}.svc"
FGA_CA="${WORK}/openfga-ca.crt"
kubectl -n "$NS" get secret gibson-openfga-http-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$FGA_CA" \
  || die "cannot read ca.crt from Secret gibson-openfga-http-tls in ns/${NS}"
[ -s "$FGA_CA" ] || die "Secret gibson-openfga-http-tls in ns/${NS} has an empty ca.crt"
# OpenFGA requires the preshared key (charts#645, hosted#634). The key goes to
# curl on stdin, never on an argv.
FGA_KEY="$(kubectl -n "$NS" get secret gibson-openfga-preshared-key -o jsonpath='{.data.key}' | base64 -d)"
[ -n "$FGA_KEY" ] || die "the Secret gibson-openfga-preshared-key in ns/${NS} holds no key"
fga_post() { # <api path under the store> <json body> -> the 200 reply body, or die
  local out code body
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$FGA_KEY" \
    | curl -sS -K - --max-time 30 --cacert "$FGA_CA" \
    --resolve "${FGA_HOST}:${FGA_LOCAL_PORT}:127.0.0.1" \
    -w '\n%{http_code}' -X POST "https://${FGA_HOST}:${FGA_LOCAL_PORT}/stores/${FGA_STORE_ID}/$1" \
    -H 'Content-Type: application/json' -d "$2" 2>&1)" \
    || die "OpenFGA $1 failed: ${out}"
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  [ "$code" = "200" ] || die "OpenFGA $1 answered HTTP ${code}: ${body}"
  printf '%s' "$body"
}
fga_check() { # <user> <relation> <object> -> "True"/"False", or die
  local body
  body="$(fga_post check "$(jq -nc --arg u "$1" --arg r "$2" --arg o "$3" --arg m "${FGA_MODEL_ID:-}" \
    '{tuple_key:{user:$u,relation:$r,object:$o}} + (if $m == "" then {} else {authorization_model_id:$m} end)')")" || exit 1
  # A reply with no boolean "allowed" is an error, never a "False": a
  # silent False would pass every negative assertion below.
  jq -er 'if (.allowed | type) == "boolean" then (if .allowed then "True" else "False" end) else error("no allowed") end' <<<"$body" \
    || die "OpenFGA check ($1 $2 $3) returned no boolean allowed: ${body}"
}
# fga_tuple_exists <user> <relation> <object> -> "True"/"False", or die.
# A check answers the computed relation: in the tenant model admin implies
# writer (`define writer: [user] or admin`), so a check cannot show that a
# direct writer grant was removed. The stored tuple can.
fga_tuple_exists() {
  local body
  body="$(fga_post read "$(jq -nc --arg u "$1" --arg r "$2" --arg o "$3" '{tuple_key:{user:$u,relation:$r,object:$o}}')")" || exit 1
  jq -er 'if (.tuples | type) == "array" then (if (.tuples | length) > 0 then "True" else "False" end) else error("no tuples") end' <<<"$body" \
    || die "OpenFGA read ($1 $2 $3) returned no tuples array: ${body}"
}

LOGIN_PAT="$(kubectl -n "$NS" get secret login-client -o jsonpath='{.data.pat}' | base64 -d | tr -d '\r\n')"
[ -n "$LOGIN_PAT" ] || die "Secret login-client in ns/${NS} has no pat. The login page's own credential is missing"
zitadel_api() {
  curl -sS --max-time 30 -H "Host: ${APP_HOST}" -H @<(printf 'Authorization: Bearer %s\n' "${LOGIN_PAT}") \
    -H 'Content-Type: application/json' -H 'Accept: application/json' "$@"
}
IAM_ADMIN_PAT="$(kubectl -n "$NS" get secret iam-admin-pat -o jsonpath='{.data.pat}' | base64 -d)"
[ -n "$IAM_ADMIN_PAT" ] || die "iam-admin-pat Secret has no pat key"
zitadel_admin() { # <method> <path> [extra curl args...]
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" "http://127.0.0.1:${ZITADEL_LOCAL_PORT}${path}" \
    -H @<(printf 'Authorization: Bearer %s\n' "${IAM_ADMIN_PAT}") -H 'Content-Type: application/json' \
    -H "x-zitadel-instance-host: ${APP_HOST}" "$@"
}

EDGE_CA="${WORK}/edge-ca.crt"
kubectl -n "$NS" get secret gibson-envoy-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$EDGE_CA" || true
[ -s "$EDGE_CA" ] || kubectl -n "$NS" get secret gibson-envoy-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$EDGE_CA" || true
[ -s "$EDGE_CA" ] || die "cannot read the edge CA from Secret gibson-envoy-tls in ns/${NS}"
# The gibson CLI verifies the edge's certificate against this CA, as
# test/demo/exit-test-enrollment.sh already does. Without it `gibson login`
# fails "x509: certificate signed by unknown authority" on
# /.well-known/gibson-login (run 36395194960).
export GIBSON_CA_CERT="$EDGE_CA"

# The adk CLI dials the api host by name; map it to the edge, mirroring
# test/demo/exit-test-enrollment.sh.
if ! getent hosts "$API_HOST" | awk '{print $1}' | grep -qx "$EDGE_IP" 2>/dev/null; then
  echo "${EDGE_IP} ${API_HOST} ${APP_HOST}" | sudo tee -a /etc/hosts >/dev/null
fi

# tenant_schema builds the buf module the daemon-local tenant RPCs need,
# mirroring test/demo/exit-test-enrollment.sh's helper of the same name.
SCHEMA_DIR="${WORK}/tenant-schema"
mkdir -p "${SCHEMA_DIR}/proto"
cp -r "${GIBSON_SRC}/internal/server/daemon/api/gibson" "${SCHEMA_DIR}/proto/"
cat > "${SCHEMA_DIR}/buf.yaml" <<EOF
version: v2
modules:
  - path: proto
deps:
  - ${SDK_SCHEMA}
EOF
(cd "$SCHEMA_DIR" && buf dep update >/dev/null)

# grpc_call <Service/Method> <json body>: one RPC as the OWNER (HUMAN_TOKEN,
# TENANT set by zitadel_login below). Mirrors exit-test-enrollment.sh's
# grpc_call helper.
# No x-gibson-tenant header: a person's tenant comes only from their token's
# verified Zitadel org (ADR-0093 decision 4), and ext-authz refuses the header
# for a user outright ("tenant header refused for a user", run 36398706690).
# stdout of each call is the answer and nothing else. buf writes warnings
# about the schema workspace to stderr on each call, and a caller that reads
# `2>&1` would get them in front of the JSON (the cause of hosted#630 in the
# enrollment test). The stderr of a call that succeeds is dropped; the stderr
# of a call that fails is printed, so the reason still reaches the caller.
grpc_call() {
  local rc=0
  buf curl --schema "$SCHEMA_DIR" --protocol grpc --cacert "$EDGE_CA" --timeout 30s \
    -H @<(printf 'authorization: Bearer %s\n' "${HUMAN_TOKEN}") \
    -d "$2" "https://${API_HOST}/$1" 2>"${WORK}/grpc-call.err" || rc=$?
  [ "$rc" -eq 0 ] || cat "${WORK}/grpc-call.err" >&2
  return "$rc"
}
# dashboard_sa_token: the bearer the dashboard's own service account mints,
# the same client_credentials grant src/lib/auth/service-token.ts makes, with
# the gibson-zitadel-dashboard machine account and the gibson-platform audience. The
# public /invite/<token> page redeems an invitation through
# acceptInvitationAction, which calls AcceptInvitation as THIS account
# (serviceClient), because the invitee has no session yet. An anonymous call
# is not a path the product takes: ext-authz refuses a request with no
# credential at all (run 36407151618).
dashboard_sa_token() {
  local id secret tok
  # The dashboard pod's ZITADEL_DASHBOARD_CLIENT_ID/SECRET come from this
  # Secret, the dashboard's machine account. gibson-dashboard-oidc is its
  # sign-in app, which has no client_credentials grant ("client not found",
  # run 36414912355).
  id="$(kubectl -n "$NS" get secret gibson-zitadel-dashboard -o jsonpath='{.data.ZITADEL_CLIENT_ID}' | base64 -d)"
  secret="$(kubectl -n "$NS" get secret gibson-zitadel-dashboard -o jsonpath='{.data.ZITADEL_CLIENT_SECRET}' | base64 -d)"
  if [ -z "$id" ] || [ -z "$secret" ]; then
    die "Secret gibson-zitadel-dashboard holds no ZITADEL_CLIENT_ID/ZITADEL_CLIENT_SECRET"
  fi
  local resp
  # The client secret goes in a Basic header through a pipe, never on the
  # curl command line (drill sweep row 28). printf and base64 read it on
  # stdin, so no argv holds it.
  resp="$(curl -sS --max-time 30 --cacert "$EDGE_CA" \
    -H @<(printf 'authorization: Basic %s\n' "$(printf '%s:%s' "$id" "$secret" | base64 -w0)") \
    -w '\nHTTP %{http_code}' \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode "scope=openid urn:zitadel:iam:org:project:id:gibson-platform:aud" \
    "https://${APP_HOST}/oauth/v2/token" 2>&1 || true)"
  tok="$(sed '$d' <<<"$resp" | jq -r '.access_token // empty' 2>/dev/null || true)"
  # Zitadel's error body carries no secret (error, error_description), and it
  # is the only thing that says why the grant was refused.
  [ -n "$tok" ] || die "the dashboard service account could not mint a token: ${resp}"
  printf '%s' "$tok"
}
# grpc_call_as <token> <Service/Method> <json body>: as a NAMED caller, for
# proving a stale/removed identity's token is refused. No tenant header, for
# the reason above. With one, ext-authz refused the HEADER, so a removed
# identity's call was "refused" whether or not the token still worked.
# grpc_call_sdk <Service/Method> <json body>: grpc_call for a service the
# sdk module defines (gibson.daemon.v1.*). The local tenant schema holds
# gibson's daemon-local protos; its sdk dependency resolves their imports
# but does not expose the sdk's own services (run 36669877756).
grpc_call_sdk() {
  local rc=0
  buf curl --schema "$SDK_SCHEMA" --protocol grpc --cacert "$EDGE_CA" --timeout 30s \
    -H @<(printf 'authorization: Bearer %s\n' "${HUMAN_TOKEN}") \
    -d "$2" "https://${API_HOST}/$1" 2>"${WORK}/grpc-call.err" || rc=$?
  [ "$rc" -eq 0 ] || cat "${WORK}/grpc-call.err" >&2
  return "$rc"
}
grpc_call_as() {
  local rc=0
  buf curl --schema "$SCHEMA_DIR" --protocol grpc --cacert "$EDGE_CA" --timeout 30s \
    -H @<(printf 'authorization: Bearer %s\n' "$1") \
    -d "$3" "https://${API_HOST}/$2" 2>"${WORK}/grpc-call.err" || rc=$?
  [ "$rc" -eq 0 ] || cat "${WORK}/grpc-call.err" >&2
  return "$rc"
}
assert_refused() { # <label> <token>
  local out rc=0
  # A refusal is the EXPECTED, PASSING outcome here, so the call is guarded
  # by an `if` (exempt from set -e) rather than `out=$(...); rc=$?`, which
  # would abort the whole script on the very call this function expects to
  # fail.
  if out="$(grpc_call_as "$2" gibson.tenant.v1.MembershipService/ListMembers '{}' 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    echo "$out" >&2
    die "$1: the call was ACCEPTED with a token that must be refused"
  fi
  pass "$1: refused ($(head -1 <<<"$out" | tr -d '\n'))"
}

# parse_user_code mirrors test/demo/exit-test-enrollment.sh's helper.
parse_user_code() { sed -n -E 's/^and confirm this code:[[:space:]]+([A-Za-z0-9-]+).*$/\1/p' | head -1; }

# zitadel_login <email> <password> — mints a fresh bearer for <email> via the
# same OIDC device grant `gibson login` uses, approved with no browser
# through the login-client credential and a Zitadel password session. This
# mirrors (never sources — see the file header) the step-1 shape
# test/demo/exit-test-enrollment.sh already proved. Sets HUMAN_TOKEN, TENANT,
# HUMAN_SUB. Called once for the Owner and TWICE for the invitee (before and
# after the MFA reset, to prove each one's own "open session" independently).
# With a third argument --no-tenant (the Platform owner, who administers the
# install and belongs to no tenant) it requires no active tenant and leaves
# TENANT as it was (run 36597865856).
zitadel_login() {
  local email="$1" pass="$2" tenant_mode="${3:-}" got_tenant login_out user_code device_req device_id session session_id session_token approve_code login_rc creds
  rm -rf "${HOME:?}/.gibson"
  login_out="$(mktemp)"
  "$GIBSON_BIN" login --gibson-url "https://${API_HOST}" --no-browser --timeout 5m >"$login_out" 2>&1 &
  local login_pid=$!
  user_code=""
  for _ in $(seq 1 60); do
    user_code="$(parse_user_code <"$login_out")"
    [ -n "$user_code" ] && break
    kill -0 "$login_pid" 2>/dev/null || break
    sleep 2
  done
  [ -n "$user_code" ] || { cat "$login_out" >&2; die "gibson login (${email}) printed no device code"; }

  device_req="$(zitadel_api "${ZURL}/v2/oidc/device_authorization/${user_code}" || true)"
  device_id="$(jq -r '.deviceAuthorizationRequest.id // empty' <<<"$device_req" 2>/dev/null || true)"
  [ -n "$device_id" ] || { echo "$device_req" >&2; die "Zitadel did not resolve the device code for ${email}"; }

  session="$(zitadel_api -X POST "${ZURL}/v2/sessions" \
    -d "$(jq -n --arg u "$email" --arg p "$pass" '{checks:{user:{loginName:$u},password:{password:$p}}}')" || true)"
  session_id="$(jq -r '.sessionId // empty' <<<"$session" 2>/dev/null || true)"
  session_token="$(jq -r '.sessionToken // empty' <<<"$session" 2>/dev/null || true)"
  if [ -z "$session_id" ] || [ -z "$session_token" ]; then
    jq -c 'del(.sessionToken)' <<<"$session" 2>/dev/null >&2 || echo "$session" >&2
    die "Zitadel refused a password session for ${email} — the credential does not sign in"
  fi

  approve_code="$(zitadel_api -o "${WORK}/approve.out" -w '%{http_code}' -X POST \
    "${ZURL}/v2/oidc/device_authorization/${device_id}" \
    -d "$(jq -n --arg id "$session_id" --arg tok "$session_token" '{session:{sessionId:$id,sessionToken:$tok}}')" || true)"
  [ "$approve_code" = "200" ] || { cat "${WORK}/approve.out" >&2; die "Zitadel refused the device approval for ${email} (HTTP ${approve_code:-<none>})"; }

  login_rc=0
  wait "$login_pid" || login_rc=$?
  [ "$login_rc" -eq 0 ] || { cat "$login_out"; die "gibson login exited ${login_rc} for ${email}"; }

  creds="${HOME}/.gibson/auth/credentials"
  [ -s "$creds" ] || die "gibson login wrote no session for ${email}"
  HUMAN_TOKEN="$(jq -r '.access_token // empty' "$creds")"
  got_tenant="$(jq -r '.active_tenant // empty' "$creds")"
  HUMAN_SUB="$(jwt_sub "$HUMAN_TOKEN")"
  [ -n "$HUMAN_TOKEN" ] || die "no access token minted for ${email}"
  if [ "$tenant_mode" != "--no-tenant" ]; then
    [ -n "$got_tenant" ] || die "gibson login pinned no active tenant for ${email}"
    TENANT="$got_tenant"
  fi
  [ -n "$HUMAN_SUB" ] || die "the access token for ${email} is not a JWT with a subject"
  echo "logged in as ${email} (subject ${HUMAN_SUB}, tenant ${got_tenant:-<none>})"
}

# poll_invite_link <email> -> the accept link, or empty after 120s.
poll_invite_link() {
  local deadline msgs id body link
  deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    msgs="$(curl -sS "${MAILPIT_URL}/api/v1/messages?limit=200" || true)"
    id="$(jq -r --arg e "$1" '[.messages[]? | select([.To[]?.Address // "" | ascii_downcase] | index(($e|ascii_downcase)))] | sort_by(.Created) | last | .ID // empty' <<<"$msgs" 2>/dev/null || true)"
    if [ -n "$id" ]; then
      body="$(curl -sS "${MAILPIT_URL}/api/v1/message/${id}" | jq -r '.Text // .HTML // empty')"
      link="$(extract_invite_link "$body" "$ISSUER_ORIGIN" || true)"
      [ -n "$link" ] && { printf '%s' "$link"; return 0; }
    fi
    sleep 2
  done
  return 1
}

# poll_new_invite_link <email> <old link> -> the newest invite link sent to
# <email> that is not <old link>, or empty after <seconds> (default 300).
# Unlike poll_invite_link it scans every message to the address, newest first,
# because a later mail without a link (a welcome or a notice) may be newest.
poll_new_invite_link() {
  local deadline msgs id body link
  deadline=$((SECONDS + ${3:-300}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    msgs="$(curl -sS "${MAILPIT_URL}/api/v1/messages?limit=500" || true)"
    for id in $(jq -r --arg e "$1" '[.messages[]? | select([.To[]?.Address // "" | ascii_downcase] | index(($e|ascii_downcase)))] | sort_by(.Created) | reverse | .[].ID' <<<"$msgs" 2>/dev/null || true); do
      body="$(curl -sS "${MAILPIT_URL}/api/v1/message/${id}" | jq -r '.Text // .HTML // empty')"
      link="$(extract_invite_link "$body" "$ISSUER_ORIGIN" || true)"
      if [ -n "$link" ] && [ "$link" != "$2" ]; then
        printf '%s' "$link"; return 0
      fi
    done
    sleep 5
  done
  return 1
}

# mailpit_recipients_for_subject <subject substring> -> newline-separated
# lowercased To: addresses across every message whose subject contains it.
mailpit_recipients_for_subject() {
  curl -sS "${MAILPIT_URL}/api/v1/messages?limit=500" \
    | jq -r --arg s "$1" '.messages[]? | select(.Subject // "" | contains($s)) | .To[]?.Address // "" | ascii_downcase'
}

# ---------------------------------------------------------------------------
# Step 1 + 2: the Platform owner AND the first tenant's Owner each get a
# setup link in Mailpit, starting at the public host, and complete it
# (password + TOTP) through driver.mjs.
# ---------------------------------------------------------------------------
log "waiting for PlatformOwnerReady"
for _ in $(seq 1 60); do
  ready="$(kubectl get platformbootstrap platform -o jsonpath='{.status.conditions[?(@.type=="PlatformOwnerReady")].status}' 2>/dev/null || true)"
  [ "$ready" = "True" ] && break
  sleep 5
done
[ "$ready" = "True" ] || die "PlatformOwnerReady never reached True"
PLATFORM_OWNER_EMAIL="$(kubectl get platformbootstrap platform -o jsonpath='{.spec.platformOwner.email}')"
[ -n "$PLATFORM_OWNER_EMAIL" ] || die "spec.platformOwner.email is empty"


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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib/zitadel-console.sh
. "${SCRIPT_DIR}/../../scripts/lib/zitadel-console.sh"
LOGIN_LOCAL_PORT="${LOGIN_LOCAL_PORT:-18481}"
CONSOLE_PORT="${CONSOLE_PORT:-18443}"
pf_loop "$NS" "svc/${RELEASE}-zitadel-login" "${LOGIN_LOCAL_PORT}:3000"
CONSOLE_WORK="$(mktemp -d)"
console_path_start "$APP_HOST" "${ZITADEL_LOCAL_PORT}" "$LOGIN_LOCAL_PORT" "$CONSOLE_PORT" "$CONSOLE_WORK" \
  || { cat "${CONSOLE_WORK}/console-proxy.log" >&2 2>/dev/null; die "the private console path did not answer on 127.0.0.1:${CONSOLE_PORT}"; }
PF_PIDS+=("$CONSOLE_PROXY_PID")

PLATFORM_PASSWORD="Xt1!$(openssl rand -hex 12)"
PLATFORM_TOTP_FILE="${WORK}/platform-owner-totp"
log "step 1+2: the Platform owner (${PLATFORM_OWNER_EMAIL}) receives a Mailpit link at the public host and completes setup"
MAILPIT_URL="$MAILPIT_URL" PLATFORM_OWNER_EMAIL="$PLATFORM_OWNER_EMAIL" \
  PLATFORM_OWNER_PASSWORD="$PLATFORM_PASSWORD" \
  CONSOLE_ORIGIN="${ISSUER_ORIGIN}/ui/console" \
  EDGE_IP="127.0.0.1:${CONSOLE_PORT}" EDGE_HOSTS="${APP_HOST}" \
  TOTP_SECRET_OUT="$PLATFORM_TOTP_FILE" DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/../platform-owner/driver.mjs" --drill
pass "step 1+2 (Platform owner): setup-link mail delivered at the public host, password set, TOTP enrolled, signed in"

OWNER_PASSWORD="Xt1!$(openssl rand -hex 12)"
OWNER_TOTP_FILE="${WORK}/owner-totp"
log "step 1+2: the first tenant's Owner (${FIRST_TENANT_OWNER_EMAIL}) receives a Mailpit link at the public host and completes setup"
MAILPIT_URL="$MAILPIT_URL" PLATFORM_OWNER_EMAIL="$FIRST_TENANT_OWNER_EMAIL" \
  PLATFORM_OWNER_PASSWORD="$OWNER_PASSWORD" \
  LANDING_ORIGIN="${ISSUER_ORIGIN}" \
  EDGE_IP="$EDGE_IP" EDGE_HOSTS="${APP_HOST} ${DOMAIN}" \
  TOTP_SECRET_OUT="$OWNER_TOTP_FILE" DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/../platform-owner/driver.mjs" --drill
pass "step 1+2 (first tenant's Owner): setup-link mail delivered at the public host, password set, TOTP enrolled, signed in"

# ---------------------------------------------------------------------------
# The Owner's bearer, for every customer-callable RPC below.
# ---------------------------------------------------------------------------
log "logging in as the Owner (${FIRST_TENANT_OWNER_EMAIL}) to mint a bearer for the daemon's RPCs"
zitadel_login "$FIRST_TENANT_OWNER_EMAIL" "$OWNER_PASSWORD"
OWNER_TENANT="$TENANT"
pass "the Owner is authenticated against the daemon (tenant ${OWNER_TENANT})"

# ---------------------------------------------------------------------------
# Read-backs: what the identity model must hold in Zitadel itself, read from
# the live instance rather than inferred from a unit test (epic hosted#189).
# ---------------------------------------------------------------------------
log "read-back (hosted#191): exactly the allowed Zitadel administrators, so gibson-dashboard-service holds none"
# The charts check allows only iam-admin, login-client, gibson-daemon,
# gibson-tenant-operator and the Platform owner, each with one named role,
# and fails on any other administrator, the dashboard service included.
NS="$NS" RELEASE="$RELEASE" bash "${CHARTS_ROOT:?CHARTS_ROOT is not set}/scripts/acceptance/instance-admin-roles-live-check.sh" \
  || die "EXIT TEST FAILED (hosted#191): the Zitadel administrators are not exactly the allowed set"
pass "read-back (hosted#191): the Zitadel administrators are exactly the allowed set"

log "read-back (hosted#193): the live sign-in policy offers no SMS or email factor"
factors() { # <second_factors|multi_factors> -> sorted, comma-joined
  local out
  out="$(zitadel_admin POST "/admin/v1/policies/login/$1/_search" -d '{}')" \
    || die "could not read the login policy's $1: ${out}"
  jq -er '.result // [] | sort | join(",")' <<<"$out" \
    || die "the login policy's $1 answer has no result list: ${out}"
}
SECOND="$(factors second_factors)"
MULTI="$(factors multi_factors)"
[ "$SECOND" = "SECOND_FACTOR_TYPE_OTP,SECOND_FACTOR_TYPE_U2F" ] \
  || die "EXIT TEST FAILED (hosted#193): second factors are [${SECOND}], want exactly the authenticator app and a security key"
[ "$MULTI" = "MULTI_FACTOR_TYPE_U2F_WITH_VERIFICATION" ] \
  || die "EXIT TEST FAILED (hosted#193): multifactors are [${MULTI}], want exactly a passkey"
pass "read-back (hosted#193): second factors [${SECOND}], multifactors [${MULTI}], no SMS or email"

log "read-back (hosted#194): the gibson project holds the four tenant roles, and tenant ${TENANT}'s org holds the project grant"
PROJECT_ID="$(kubectl -n "$NS" get secret gibson-zitadel-tenant-operator -o jsonpath='{.data.project_id}' | base64 -d)"
[ -n "$PROJECT_ID" ] || die "Secret gibson-zitadel-tenant-operator has no project_id"
TENANT_ORG="$(kubectl get tenants.gibson.zeroroot.ai "$TENANT" -o jsonpath='{.status.zitadelOrgID}')"
[ -n "$TENANT_ORG" ] || die "Tenant ${TENANT} has no status.zitadelOrgID"
WANT_ROLES="admin,editor,owner,viewer"
ROLES_OUT="$(zitadel_admin POST /zitadel.project.v2.ProjectService/ListProjectRoles \
  -d "$(jq -nc --arg p "$PROJECT_ID" '{projectId:$p}')")" || die "ListProjectRoles failed: ${ROLES_OUT}"
GOT_ROLES="$(jq -er '[.projectRoles[]?.key] | sort | join(",")' <<<"$ROLES_OUT")" \
  || die "ListProjectRoles returned no projectRoles: ${ROLES_OUT}"
[ "$GOT_ROLES" = "$WANT_ROLES" ] \
  || die "EXIT TEST FAILED (hosted#194): project ${PROJECT_ID} roles are [${GOT_ROLES}], want [${WANT_ROLES}]"
GRANTS_OUT="$(zitadel_admin POST /zitadel.project.v2.ProjectService/ListProjectGrants \
  -d "$(jq -nc --arg p "$PROJECT_ID" --arg o "$TENANT_ORG" \
    '{filters:[{inProjectIdsFilter:{ids:[$p]}},{grantedOrganizationIdFilter:{id:$o}}]}')")" \
  || die "ListProjectGrants failed: ${GRANTS_OUT}"
GOT_GRANT="$(jq -er --arg o "$TENANT_ORG" \
  '[.projectGrants[]? | select(.grantedOrganizationId == $o) | .grantedRoleKeys[]] | sort | join(",")' <<<"$GRANTS_OUT")" \
  || die "ListProjectGrants returned no projectGrants: ${GRANTS_OUT}"
[ "$GOT_GRANT" = "$WANT_ROLES" ] \
  || die "EXIT TEST FAILED (hosted#194): tenant org ${TENANT_ORG} holds grant roles [${GOT_GRANT}], want [${WANT_ROLES}]"
pass "read-back (hosted#194): project ${PROJECT_ID} has [${GOT_ROLES}], and tenant org ${TENANT_ORG} holds the grant"

log "read-back (hosted#193): Zitadel refuses a second account for ${FIRST_TENANT_OWNER_EMAIL}, even in another org"
# Login names are emails and the domain policy keeps them unique across the
# instance (userLoginMustBeDomain: false). The first tenant Owner lives in the
# tenant's org; the Platform owner's org is a different one. The request is
# the one gibson itself makes (idp/zitadel.EnsureHumanUserNoPassword).
OWNER_UID="$(kubectl get platformbootstrap platform -o jsonpath='{.status.platformOwnerUserID}')"
[ -n "$OWNER_UID" ] || die "PlatformBootstrap platform has no status.platformOwnerUserID"
OTHER_ORG="$(zitadel_admin GET "/v2/users/${OWNER_UID}" | jq -r '.user.details.resourceOwner // empty')"
[ -n "$OTHER_ORG" ] || die "could not read the Platform owner's org"
[ "$OTHER_ORG" != "$TENANT_ORG" ] || die "the Platform owner's org is the tenant's org; the check needs two orgs"
DUP_EMAIL="$(tr '[:upper:]' '[:lower:]' <<<"$FIRST_TENANT_OWNER_EMAIL")"
# assert_no_second_account <label>: Zitadel refuses a second account for
# DUP_EMAIL in OTHER_ORG. Run twice: here, and after the self-rename attempts
# below (hosted#210).
assert_no_second_account() {
  local code id
  code="$(zitadel_admin POST /zitadel.user.v2.UserService/AddHumanUser \
    -H "x-zitadel-orgid: ${OTHER_ORG}" -o "${WORK}/dup-user.out" -w '%{http_code}' \
    -d "$(jq -nc --arg e "$DUP_EMAIL" '{username:$e,profile:{givenName:"Duplicate",familyName:"Check"},email:{email:$e,isVerified:true}}')" || true)"
  if [ "$code" = "200" ]; then
    id="$(jq -r '.userId // empty' "${WORK}/dup-user.out")"
    if [ -n "$id" ]; then
      zitadel_admin DELETE "/v2/users/${id}" >/dev/null || true
    fi
    die "EXIT TEST FAILED ($1): Zitadel created a second account for ${DUP_EMAIL} in org ${OTHER_ORG} (removed again)"
  fi
  [ "$code" = "409" ] || { cat "${WORK}/dup-user.out" >&2; die "EXIT TEST FAILED ($1): AddHumanUser for a used email answered HTTP ${code}, want 409 already exists"; }
  pass "read-back ($1): a second account for ${DUP_EMAIL} in org ${OTHER_ORG} is refused (HTTP 409)"
}
assert_no_second_account hosted#193

# ---------------------------------------------------------------------------
# hosted#210: a tenant user cannot change their own username or email
# through any public route. A rename would free the email for a second
# account (ADR-0093 decision 1). The Owner's own token goes to the public
# host, the way a browser or a script of that user sends it. The edge must
# answer each call with 403, before Zitadel reads it (charts#177). Then the Owner's email is unchanged, and a second account for it is
# still refused.
# ---------------------------------------------------------------------------
log "hosted#210: the public edge refuses each self-rename of ${FIRST_TENANT_OWNER_EMAIL}"
RENAME_TO="renamed-$(date +%s)@localhost.zeroroot.ai"
edge_call() { # <method> <path> [extra curl args...] -> "<http code> <body>"
  local method="$1" path="$2"
  shift 2
  curl -sS --max-time 30 --cacert "$EDGE_CA" -X "$method" -o "${WORK}/edge.out" -w '%{http_code}' \
    -H @<(printf 'Authorization: Bearer %s\n' "${HUMAN_TOKEN}") -H 'Content-Type: application/json' \
    "$@" "https://${APP_HOST}${path}" || true
  printf ' %s' "$(tr -d '\n' < "${WORK}/edge.out" 2>/dev/null)"
}
assert_edge_refuses() { # <label> <method> <path> [extra curl args...]
  local label="$1" got
  shift
  got="$(edge_call "$@")"
  [ "${got%% *}" = 403 ] \
    || die "EXIT TEST FAILED (hosted#210): ${label} answered '${got}', want the edge refusal 403"
  pass "hosted#210: the edge refuses ${label}"
}
NEW_EMAIL_BODY="$(jq -nc --arg e "$RENAME_TO" '{email:$e}')"
assert_edge_refuses "PUT /auth/v1/users/me/username" PUT /auth/v1/users/me/username -d "$(jq -nc --arg u "$RENAME_TO" '{userName:$u}')"
assert_edge_refuses "PUT /auth/v1/users/me/email" PUT /auth/v1/users/me/email -d "$NEW_EMAIL_BODY"
assert_edge_refuses "POST /auth/v1/users/me/email" POST /auth/v1/users/me/email -d "$NEW_EMAIL_BODY"
assert_edge_refuses "a percent-encoded email path" PUT /auth/v1/users/me/e%6Dail -d "$NEW_EMAIL_BODY"
assert_edge_refuses "a method override header" POST /auth/v1/users/me/email -H 'X-HTTP-Method-Override: PUT' -d "$NEW_EMAIL_BODY"
for api in v2 v2beta; do
  assert_edge_refuses "POST /${api}/users/<self>/email" POST "/${api}/users/${HUMAN_SUB}/email" -d "$NEW_EMAIL_BODY"
done
assert_edge_refuses "PUT /v2/users/human/<self>" PUT "/v2/users/human/${HUMAN_SUB}" -d "$(jq -nc --arg e "$RENAME_TO" '{username:$e,email:{email:$e}}')"
assert_edge_refuses "PATCH /v2/users/<self>" PATCH "/v2/users/${HUMAN_SUB}" -d "$(jq -nc --arg e "$RENAME_TO" '{username:$e}')"
assert_edge_refuses "PUT /v2beta/users/<self>" PUT "/v2beta/users/${HUMAN_SUB}" -d "$(jq -nc --arg e "$RENAME_TO" '{username:$e}')"
# CONTROL: a read of the own email still routes to Zitadel, so the refusals
# above are the deny routes and not a blanket block of the API.
CONTROL="$(edge_call GET /auth/v1/users/me/email)"
[ "${CONTROL%% *}" != 403 ] || die "EXIT TEST FAILED (hosted#210): GET /auth/v1/users/me/email answered '${CONTROL}'. The edge blocks the whole API, so the refusals above prove nothing"
pass "hosted#210 CONTROL: GET /auth/v1/users/me/email reaches Zitadel (HTTP ${CONTROL%% *})"
NOW_EMAIL="$(zitadel_admin GET "/v2/users/${HUMAN_SUB}" | jq -r '.user.human.email.email // empty' | tr '[:upper:]' '[:lower:]')"
[ "$NOW_EMAIL" = "$DUP_EMAIL" ] \
  || die "EXIT TEST FAILED (hosted#210): the Owner's email is '${NOW_EMAIL}' after the refused renames, want ${DUP_EMAIL}"
pass "hosted#210: the Owner's email is still ${DUP_EMAIL}"
assert_no_second_account "hosted#210 after the self-rename attempts"

# ---------------------------------------------------------------------------
# Step 3: invite, accept, enroll, land with the invited role.
# ---------------------------------------------------------------------------
log "step 3: the Owner invites ${INVITEE_EMAIL} as writer"
INVITE_OUT="$(grpc_call gibson.tenant.v1.MembershipService/InviteMember "$(jq -n --arg e "$INVITEE_EMAIL" '{email:$e,role:"writer"}')" 2>&1)" \
  || die "InviteMember refused: ${INVITE_OUT}"
echo "$INVITE_OUT"
INVITATION_ID="$(jq -r '.invitationId // empty' <<<"$INVITE_OUT")"
[ -n "$INVITATION_ID" ] || die "InviteMember returned no invitation_id: ${INVITE_OUT}"

log "step 3: the invite mail arrives with a link at the app host (${ISSUER_ORIGIN})"
INVITE_LINK="$(poll_invite_link "$INVITEE_EMAIL")" \
  || die "EXIT TEST FAILED: no invite mail with an accept link at ${ISSUER_ORIGIN} was delivered to ${INVITEE_EMAIL} within 120s"
pass "invite mail delivered: ${INVITE_LINK}"
INVITE_TOKEN="${INVITE_LINK##*/invite/}"
[ -n "$INVITE_TOKEN" ] || die "could not read a token out of ${INVITE_LINK}"

log "step 3: the invitee accepts (through the dashboard's service account, as the /invite page does; the token is the whole capability)"
# The invitation token is the whole capability: the body goes on stdin
# (buf curl -d @-), and jq reads the token from its environment.
ACCEPT_OUT="$(T="$INVITE_TOKEN" jq -n '{token:env.T}' \
  | grpc_call_as "$(dashboard_sa_token)" gibson.tenant.v1.MembershipService/AcceptInvitation @- 2>&1)" \
  || die "AcceptInvitation refused: ${ACCEPT_OUT}"
echo "$ACCEPT_OUT"
INVITEE_USER_ID="$(jq -r '.userId // empty' <<<"$ACCEPT_OUT")"
SETUP_URL="$(jq -r '.setupUrl // empty' <<<"$ACCEPT_OUT")"
[ -n "$INVITEE_USER_ID" ] || die "AcceptInvitation returned no user_id: ${ACCEPT_OUT}"
[ -n "$SETUP_URL" ] || die "AcceptInvitation returned no setup_url: ${ACCEPT_OUT}"
case "$SETUP_URL" in
  "${ISSUER_ORIGIN}"/*) ;;
  *) die "the invitee's setup_url '${SETUP_URL}' does not start at ${ISSUER_ORIGIN}" ;;
esac

INVITEE_PASSWORD="Xt1!$(openssl rand -hex 12)"
INVITEE_TOTP_FILE="${WORK}/invitee-totp"
log "step 3: the invitee sets a password and enrolls TOTP through driver.mjs, then lands in the tenant"
PLATFORM_OWNER_PASSWORD="$INVITEE_PASSWORD" SETUP_LINK="$SETUP_URL" \
  LANDING_ORIGIN="${ISSUER_ORIGIN}" \
  EDGE_IP="$EDGE_IP" EDGE_HOSTS="${APP_HOST} ${DOMAIN}" \
  TOTP_SECRET_OUT="$INVITEE_TOTP_FILE" DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/../platform-owner/driver.mjs" --drill
pass "the invitee completed setup and landed signed in"

log "step 3: FGA shows the invited role (writer), never a different one"
[ "$(fga_check "user:${INVITEE_USER_ID}" writer "tenant:${TENANT}")" = "True" ] \
  || die "user:${INVITEE_USER_ID} does not hold writer on tenant:${TENANT} after accepting a writer invite"
[ "$(fga_check "user:${INVITEE_USER_ID}" admin "tenant:${TENANT}")" = "False" ] \
  || die "user:${INVITEE_USER_ID} unexpectedly holds admin before any role change"
pass "step 3 PASSED: invited, accepted, enrolled, landed with role writer"

# ---------------------------------------------------------------------------
# Step 4: role change, FGA reflects it within seconds.
# ---------------------------------------------------------------------------
log "step 4: the Owner promotes ${INVITEE_EMAIL} from writer to admin"
SET_ROLE_OUT="$(grpc_call gibson.tenant.v1.MembershipService/SetTenantRole "$(jq -n --arg u "$INVITEE_USER_ID" '{user_id:$u,role:"admin"}')" 2>&1)" \
  || die "SetTenantRole refused: ${SET_ROLE_OUT}"
echo "$SET_ROLE_OUT"

ok=""
for _ in $(seq 1 15); do
  if [ "$(fga_check "user:${INVITEE_USER_ID}" admin "tenant:${TENANT}")" = "True" ] \
    && [ "$(fga_tuple_exists "user:${INVITEE_USER_ID}" writer "tenant:${TENANT}")" = "False" ]; then
    ok=1; break
  fi
  sleep 1
done
[ -n "$ok" ] || die "EXIT TEST FAILED (gibson#235): SetTenantRole returned, but FGA did not grant admin and drop the direct writer tuple within 15s"
pass "step 4 PASSED: FGA grants admin, and the direct writer tuple is gone, within seconds"

# ---------------------------------------------------------------------------
# Step 4b (hosted#204): an Admin, not the Owner, demotes a user, and a
# request that uses the removed right is refused.
# ---------------------------------------------------------------------------
SECOND_EMAIL="${SECOND_EMAIL:-second@localhost.zeroroot.ai}"
# A writer-only RPC that changes nothing: ListMissionDrafts is writer in
# the registry, and since gibson#402 its handler gates on writer too.
# ExportFindings was the probe until gibson#424 made every read member-gated,
# so a demoted writer (now member) was correctly still allowed it
# (runs 36647738112, 36653261602).
WRITER_RPC=gibson.tenant.v1.TenantService/ListMissionDrafts
WRITER_BODY='{}'
log "step 4b: the Owner invites ${SECOND_EMAIL} as writer"
INVITE2_OUT="$(grpc_call gibson.tenant.v1.MembershipService/InviteMember "$(jq -n --arg e "$SECOND_EMAIL" '{email:$e,role:"writer"}')" 2>&1)" \
  || die "InviteMember (${SECOND_EMAIL}) refused: ${INVITE2_OUT}"
INVITE2_LINK="$(poll_invite_link "$SECOND_EMAIL")" \
  || die "no invite mail reached ${SECOND_EMAIL} within 120s"
ACCEPT2_OUT="$(grpc_call_as "$(dashboard_sa_token)" gibson.tenant.v1.MembershipService/AcceptInvitation "$(jq -n --arg t "${INVITE2_LINK##*/invite/}" '{token:$t}')" 2>&1)" \
  || die "AcceptInvitation (${SECOND_EMAIL}) refused: ${ACCEPT2_OUT}"
SECOND_USER_ID="$(jq -r '.userId // empty' <<<"$ACCEPT2_OUT")"
SECOND_SETUP_URL="$(jq -r '.setupUrl // empty' <<<"$ACCEPT2_OUT")"
if [ -z "$SECOND_USER_ID" ] || [ -z "$SECOND_SETUP_URL" ]; then
  die "AcceptInvitation (${SECOND_EMAIL}) returned no user or setup link: ${ACCEPT2_OUT}"
fi
SECOND_PASSWORD="Xt1!$(openssl rand -hex 12)"
PLATFORM_OWNER_PASSWORD="$SECOND_PASSWORD" SETUP_LINK="$SECOND_SETUP_URL" \
  LANDING_ORIGIN="${ISSUER_ORIGIN}" \
  EDGE_IP="$EDGE_IP" EDGE_HOSTS="${APP_HOST} ${DOMAIN}" \
  TOTP_SECRET_OUT="${WORK}/second-totp" DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/../platform-owner/driver.mjs" --drill
zitadel_login "$SECOND_EMAIL" "$SECOND_PASSWORD"
SECOND_TOKEN="$HUMAN_TOKEN"
WRITER_OUT="$(grpc_call_as "$SECOND_TOKEN" "$WRITER_RPC" "$WRITER_BODY" 2>&1)" \
  || die "EXIT TEST FAILED (hosted#204): ${SECOND_EMAIL} as writer was refused ${WRITER_RPC} before any demotion: ${WRITER_OUT}"
pass "step 4b: ${SECOND_EMAIL} holds writer and may call ${WRITER_RPC}"

log "step 4b: the Admin (${INVITEE_EMAIL}), not the Owner, demotes ${SECOND_EMAIL} to member"
zitadel_login "$INVITEE_EMAIL" "$INVITEE_PASSWORD"
ADMIN_TOKEN="$HUMAN_TOKEN"
DEMOTE_OUT="$(grpc_call_as "$ADMIN_TOKEN" gibson.tenant.v1.MembershipService/SetTenantRole "$(jq -n --arg u "$SECOND_USER_ID" '{user_id:$u,role:"member"}')" 2>&1)" \
  || die "EXIT TEST FAILED (hosted#204): the Admin's SetTenantRole was refused: ${DEMOTE_OUT}"
ok=""
for _ in $(seq 1 15); do
  if [ "$(fga_check "user:${SECOND_USER_ID}" writer "tenant:${TENANT}")" = "False" ] \
    && [ "$(fga_check "user:${SECOND_USER_ID}" member "tenant:${TENANT}")" = "True" ]; then
    ok=1; break
  fi
  sleep 1
done
if [ -z "$ok" ]; then
  # Name the broken half (run 36587978263 showed no tuple change and no
  # reason). SetTenantRole writes the Zitadel grant, then Sync copies the
  # grants into FGA. The tenant-operator repeats that Sync every 60s.
  GRANT_OUT="$(zitadel_admin POST /zitadel.authorization.v2.AuthorizationService/ListAuthorizations \
    -d "$(jq -nc --arg o "$TENANT_ORG" --arg p "$PROJECT_ID" --arg u "$SECOND_USER_ID" \
      '{filters:[{organizationId:{id:$o}},{projectId:{id:$p}},{inUserIds:{ids:[$u]}}]}')" 2>&1)" || true
  echo "Zitadel grants for ${SECOND_USER_ID}: $(jq -c '[.authorizations[]? | {state, roles: [.roles[]?.key], org: .organization.id, userOrg: .user.organizationId}]' <<<"$GRANT_OUT" 2>/dev/null || echo "$GRANT_OUT")" >&2
  echo "FGA tuples for ${SECOND_USER_ID} on tenant:${TENANT}: $(fga_post read "$(jq -nc --arg u "user:${SECOND_USER_ID}" --arg o "tenant:${TENANT}" '{tuple_key:{user:$u,object:$o}}')" | jq -c '[.tuples[].key.relation]')" >&2
  repaired=""
  for _ in $(seq 1 15); do
    sleep 5
    if [ "$(fga_tuple_exists "user:${SECOND_USER_ID}" member "tenant:${TENANT}")" = "True" ] \
      && [ "$(fga_tuple_exists "user:${SECOND_USER_ID}" writer "tenant:${TENANT}")" = "False" ]; then
      repaired=1; break
    fi
  done
  if [ -n "$repaired" ]; then
    die "EXIT TEST FAILED (hosted#204): SetTenantRole's inline Sync left FGA unchanged, and the 60s drift timer repaired it later. A demotion must hold within seconds"
  fi
  die "EXIT TEST FAILED (hosted#204): FGA did not drop writer and keep member for ${SECOND_EMAIL}, not within 15s and not after the 60s drift timer"
fi

# The removed right must fail as an authorization refusal, never as a
# transport error that would pass for the wrong reason. ext-authz caches an
# FGA verdict for EXT_AUTHZ_FGA_CACHE_TTL (5s since gibson v0.143.5, #412),
# so the old right may hold that long (run 36592908597 held it 21s under the
# old 30s TTL). Seconds, not token expiry, is the contract: allow the TTL
# plus a margin, and no more.
REFUSE_WITHIN=15
refused_at=""
for i in $(seq 1 "$REFUSE_WITHIN"); do
  if ! OLD_OUT="$(grpc_call_as "$SECOND_TOKEN" "$WRITER_RPC" "$WRITER_BODY" 2>&1)"; then
    refused_at="$i"; break
  fi
  sleep 1
done
if [ -z "$refused_at" ]; then
  echo "$OLD_OUT" >&2
  # ext-authz's own decisions for this user (debug level in the overlay),
  # and a fresh FGA answer, so the miss names the layer that still allows.
  # Every replica (ext-authz runs 2, and deploy/ reads one pod), every line
  # (a selector defaults to --tail=10), matched on the RPC: a debug decision
  # line carries the method, not always the subject (run 36653261602 printed
  # nothing).
  echo "ext-authz lines for ${WRITER_RPC} in the last 3 minutes, all replicas:" >&2
  kubectl -n "$NS" logs -l app.kubernetes.io/component=ext-authz --all-containers --prefix \
    --since=3m --tail=-1 --max-log-requests=10 2>&1 \
    | grep -F "${WRITER_RPC##*/}" | tail -60 >&2 || true
  echo "ext-authz debug lines in the last 3 minutes: $(kubectl -n "$NS" logs -l app.kubernetes.io/component=ext-authz --all-containers --since=3m --tail=-1 2>/dev/null | grep -c '"level":"DEBUG"' || true)" >&2
  echo "FGA now: writer=$(fga_check "user:${SECOND_USER_ID}" writer "tenant:${TENANT}") member=$(fga_check "user:${SECOND_USER_ID}" member "tenant:${TENANT}")" >&2
  die "EXIT TEST FAILED (hosted#204): ${SECOND_EMAIL}'s ${WRITER_RPC} was still ACCEPTED ${REFUSE_WITHIN}s after FGA dropped writer"
fi
log "step 4b: the old writer right was refused after about ${refused_at}s"
grep -q 'permission_denied' <<<"$OLD_OUT" \
  || die "EXIT TEST FAILED (hosted#204): ${WRITER_RPC} failed after the demotion, but not as permission_denied: ${OLD_OUT}"
pass "step 4b PASSED: an Admin demoted ${SECOND_EMAIL}, and a request using the old writer right is refused (permission_denied)"

# Every later step runs as the Owner.
zitadel_login "$FIRST_TENANT_OWNER_EMAIL" "$OWNER_PASSWORD"

# ---------------------------------------------------------------------------
# Step 5: MFA reset — the target's session is refused; the notice goes to
# the target's own address only.
# ---------------------------------------------------------------------------
log "step 5: minting the invitee's OWN session before the reset (the one the reset must refuse)"
zitadel_login "$INVITEE_EMAIL" "$INVITEE_PASSWORD"
INVITEE_TOKEN_BEFORE="$HUMAN_TOKEN"

# Restore the Owner's bearer (zitadel_login overwrote HUMAN_TOKEN/TENANT) —
# every admin RPC from here on is called by the Owner, never the invitee.
zitadel_login "$FIRST_TENANT_OWNER_EMAIL" "$OWNER_PASSWORD"

log "step 5: the Owner resets ${INVITEE_EMAIL}'s MFA"
RESET_OUT="$(grpc_call gibson.tenant.v1.UserService/ResetUserMFA "$(jq -n --arg u "$INVITEE_USER_ID" '{target_user_id:$u}')" 2>&1)" \
  || die "ResetUserMFA refused: ${RESET_OUT}"
echo "$RESET_OUT"
jq -e '.otpCleared == true' <<<"$RESET_OUT" >/dev/null || die "ResetUserMFA did not report otp_cleared=true: ${RESET_OUT}"

assert_refused "the invitee's pre-reset session" "$INVITEE_TOKEN_BEFORE"

log "step 5: the reset notice went to the target's own address ONLY"
sleep 3
TARGETED="$(mailpit_recipients_for_subject "two-factor authentication was reset" | grep -Fxc "$(tr '[:upper:]' '[:lower:]' <<<"$INVITEE_EMAIL")" || true)"
LEAKED="$(mailpit_recipients_for_subject "two-factor authentication was reset" | grep -Fxc "$(tr '[:upper:]' '[:lower:]' <<<"$FIRST_TENANT_OWNER_EMAIL")" || true)"
[ "${TARGETED:-0}" -ge 1 ] || die "EXIT TEST FAILED: no MFA-reset notice reached ${INVITEE_EMAIL}"
[ "${LEAKED:-0}" -eq 0 ] || die "EXIT TEST FAILED: the MFA-reset notice ALSO reached the Owner (${FIRST_TENANT_OWNER_EMAIL}) — it must go to the target's own address only"
pass "step 5 PASSED: the invitee's pre-reset session is refused, and the notice reached only ${INVITEE_EMAIL}"

# ---------------------------------------------------------------------------
# Step 6: removal — the removed user's open session is refused, and the
# Zitadel account is gone.
# ---------------------------------------------------------------------------
log "step 6: minting a FRESH session for the invitee (their password is unchanged by an MFA reset)"
zitadel_login "$INVITEE_EMAIL" "$INVITEE_PASSWORD"
INVITEE_TOKEN_AFTER="$HUMAN_TOKEN"

# hosted#205: work the removed user created stays, attributed. The invitee
# (Admin since step 4) creates a mission before the removal. The target
# needs a connection url (run 36783655727: "target must have either
# Connection parameters or URL"); the .invalid host is never dialed, since
# the mission is created, not run. An empty-nodes definition is valid
# (test/smoke/cutover-smoke.sh, deploy#1489).
log "step 6: ${INVITEE_EMAIL} creates a mission before the removal (hosted#205)"
ATTR_RUN="$(openssl rand -hex 4)"
TARGET_OUT="$(grpc_call_sdk gibson.daemon.v1.DaemonService/CreateTarget \
  "$(jq -n --arg n "identity-target-${ATTR_RUN}" '{target:{name:$n,description:"identity exit test",connection:{url:"https://target.invalid"}}}')" 2>&1)" \
  || die "CreateTarget (as ${INVITEE_EMAIL}) refused: ${TARGET_OUT}"
ATTR_TARGET_ID="$(jq -r '.targetId // empty' <<<"$TARGET_OUT")"
[ -n "$ATTR_TARGET_ID" ] || die "CreateTarget returned no targetId: ${TARGET_OUT}"
MDEF_OUT="$(grpc_call_sdk gibson.daemon.v1.DaemonService/CreateMissionDefinition \
  "$(jq -n --arg n "identity-noop-${ATTR_RUN}" '{definition:{name:$n,description:"identity exit test",version:"1.0.0",nodes:{},edges:[],entry_points:[],exit_points:[]}}')" 2>&1)" \
  || die "CreateMissionDefinition (as ${INVITEE_EMAIL}) refused: ${MDEF_OUT}"
ATTR_MDEF_ID="$(jq -r '.missionDefinitionId // empty' <<<"$MDEF_OUT")"
[ -n "$ATTR_MDEF_ID" ] || die "CreateMissionDefinition returned no missionDefinitionId: ${MDEF_OUT}"
MISSION_OUT="$(grpc_call_sdk gibson.daemon.v1.DaemonService/CreateMission \
  "$(jq -n --arg n "identity-mission-${ATTR_RUN}" --arg t "$ATTR_TARGET_ID" --arg d "$ATTR_MDEF_ID" '{name:$n,target_id:$t,mission_definition_id:$d}')" 2>&1)" \
  || die "CreateMission (as ${INVITEE_EMAIL}) refused: ${MISSION_OUT}"
ATTR_MISSION_ID="$(jq -r '.mission.id // empty' <<<"$MISSION_OUT")"
[ -n "$ATTR_MISSION_ID" ] || die "CreateMission returned no mission id: ${MISSION_OUT}"
[ "$(jq -r '.mission.createdBy.id // empty' <<<"$MISSION_OUT")" = "$INVITEE_USER_ID" ] \
  || die "EXIT TEST FAILED (hosted#205): mission ${ATTR_MISSION_ID} is not attributed to its creator ${INVITEE_USER_ID}: ${MISSION_OUT}"
pass "step 6: mission ${ATTR_MISSION_ID} is attributed to its creator ${INVITEE_USER_ID}"

zitadel_login "$FIRST_TENANT_OWNER_EMAIL" "$OWNER_PASSWORD"
log "step 6: the Owner removes ${INVITEE_EMAIL}"
REMOVE_OUT="$(grpc_call gibson.tenant.v1.MembershipService/RemoveMember "$(jq -n --arg u "$INVITEE_USER_ID" '{user_id:$u}')" 2>&1)" \
  || die "RemoveMember refused: ${REMOVE_OUT}"
echo "$REMOVE_OUT"

assert_refused "the invitee's open session after removal" "$INVITEE_TOKEN_AFTER"

log "step 6: the Zitadel account is gone"
GET_USER_CODE="$(zitadel_admin GET "/v2/users/${INVITEE_USER_ID}" -o "${WORK}/get-user.out" -w '%{http_code}' || true)"
if [ "$GET_USER_CODE" != "404" ]; then
  cat "${WORK}/get-user.out" >&2
  die "EXIT TEST FAILED: GET /v2/users/${INVITEE_USER_ID} returned HTTP ${GET_USER_CODE}, want 404 (the account still exists)"
fi

log "step 6: the removed user's mission stays in the tenant, and the creator reads as removed (hosted#205)"
LIST_OUT="$(grpc_call_sdk gibson.daemon.v1.DaemonService/ListMissions '{"page_size":200}' 2>&1)" \
  || die "ListMissions (as the Owner) refused: ${LIST_OUT}"
KEPT_BY="$(jq -r --arg m "$ATTR_MISSION_ID" '.missions[]? | select(.id == $m) | .createdBy.id // empty' <<<"$LIST_OUT")"
[ "$KEPT_BY" = "$INVITEE_USER_ID" ] \
  || die "EXIT TEST FAILED (hosted#205): after the removal, mission ${ATTR_MISSION_ID} is missing or not attributed to ${INVITEE_USER_ID} (got '${KEPT_BY}')"
RESOLVE_OUT="$(grpc_call gibson.tenant.v1.UserService/ResolveUsers "$(jq -n --arg u "$INVITEE_USER_ID" '{user_ids:[$u]}')" 2>&1)" \
  || die "ResolveUsers (as the Owner) refused: ${RESOLVE_OUT}"
jq -e '.users | length == 1 and .[0].state == "USER_REF_STATE_REMOVED" and (.[0].displayName // "") == "" and (.[0].email // "") == ""' <<<"$RESOLVE_OUT" >/dev/null \
  || die "EXIT TEST FAILED (hosted#205): ResolveUsers does not report ${INVITEE_USER_ID} as removed with no name: ${RESOLVE_OUT}"
pass "step 6 PASSED: the removed user's open session is refused, the Zitadel account is gone, and their mission stays, attributed to a removed user"

# ---------------------------------------------------------------------------
# Step 7 (hosted#205): the removed address is welcome again elsewhere. The
# Platform owner provisions a second tenant with it as owner; the address
# receives an invitation, accepts it, and lands as Owner of the new tenant
# under a new Zitadel account.
# ---------------------------------------------------------------------------
SECOND_TENANT="${SECOND_TENANT:-second}"
log "step 7: the Platform owner provisions tenant ${SECOND_TENANT} with the removed ${INVITEE_EMAIL} as owner"
zitadel_login "$PLATFORM_OWNER_EMAIL" "$PLATFORM_PASSWORD" --no-tenant
PROV_OUT="$(grpc_call gibson.tenant.v1.AdminTenantService/AdminProvisionTenant \
  "$(jq -n --arg t "$SECOND_TENANT" --arg e "$INVITEE_EMAIL" '{tenant_id:$t,display_name:"Second tenant",owner_email:$e}')" 2>&1)" \
  || die "EXIT TEST FAILED (hosted#205): AdminProvisionTenant refused: ${PROV_OUT}"
echo "$PROV_OUT"

REINVITE_LINK="$(poll_new_invite_link "$INVITEE_EMAIL" "$INVITE_LINK" 600)" \
  || die "EXIT TEST FAILED (hosted#205): no new invitation reached ${INVITEE_EMAIL} within 10 minutes"
pass "step 7: a new invitation reached ${INVITEE_EMAIL}: ${REINVITE_LINK}"

# Accept retries while the new tenant's org is still provisioning.
REACCEPT_OUT=""
for _ in $(seq 1 60); do
  if REACCEPT_OUT="$(grpc_call_as "$(dashboard_sa_token)" gibson.tenant.v1.MembershipService/AcceptInvitation \
      "$(jq -n --arg t "${REINVITE_LINK##*/invite/}" '{token:$t}')" 2>&1)"; then
    break
  fi
  grep -qi 'provisioning' <<<"$REACCEPT_OUT" || die "EXIT TEST FAILED (hosted#205): AcceptInvitation refused: ${REACCEPT_OUT}"
  REACCEPT_OUT=""
  sleep 15
done
[ -n "$REACCEPT_OUT" ] || die "EXIT TEST FAILED (hosted#205): tenant ${SECOND_TENANT} was still provisioning after 15 minutes"
REINVITEE_ID="$(jq -r '.userId // empty' <<<"$REACCEPT_OUT")"
RESETUP_URL="$(jq -r '.setupUrl // empty' <<<"$REACCEPT_OUT")"
if [ -z "$REINVITEE_ID" ] || [ -z "$RESETUP_URL" ]; then
  die "AcceptInvitation (re-invite) returned no user or setup link: ${REACCEPT_OUT}"
fi
[ "$REINVITEE_ID" != "$INVITEE_USER_ID" ] \
  || die "EXIT TEST FAILED (hosted#205): the re-invite reused the deleted account ${INVITEE_USER_ID}"

PLATFORM_OWNER_PASSWORD="Xt1!$(openssl rand -hex 12)" SETUP_LINK="$RESETUP_URL" \
  LANDING_ORIGIN="${ISSUER_ORIGIN}" \
  EDGE_IP="$EDGE_IP" EDGE_HOSTS="${APP_HOST} ${DOMAIN}" \
  TOTP_SECRET_OUT="${WORK}/reinvitee-totp" DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/../platform-owner/driver.mjs" --drill

[ "$(fga_check "user:${REINVITEE_ID}" owner "tenant:${SECOND_TENANT}")" = "True" ] \
  || die "EXIT TEST FAILED (hosted#205): user:${REINVITEE_ID} does not hold owner on tenant:${SECOND_TENANT}"
[ "$(fga_check "user:${REINVITEE_ID}" member "tenant:${TENANT}")" = "False" ] \
  || die "EXIT TEST FAILED (hosted#205): the re-invited account unexpectedly belongs to tenant ${TENANT}"
pass "step 7 PASSED: the removed address came back as a new account (${REINVITEE_ID}), Owner of ${SECOND_TENANT}, not a member of ${TENANT}"

log "EXIT TEST PASSED (online leg): the identity model works end to end — setup links, TOTP enrollment, invitation, role change, MFA reset, and removal"
