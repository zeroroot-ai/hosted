#!/usr/bin/env bash
# exit-test-signup.sh — launch blocker 2's drill (hosted#122), run on the kind
# cluster that `make recreate ENV=kind` stood up with the CI rung and the
# Mailpit overlay (test/signup/values.yaml).
#
# In plain words: an address receives the verification mail, and the account
# reaches a Ready workspace, with no manual DB touch. The workflow
# (.github/workflows/exit-test-signup.yml) explains the whole shape. This
# script is the half that runs against the live cluster.
#
# What it does:
#   1. Finds the customer edge the way an operator does: the domain from the
#      gibson-domains ConfigMap, the address from the Envoy LoadBalancer
#      Service (cloud-provider-kind gives it one on the kind Docker network,
#      which the runner reaches directly). No /etc/hosts, no sudo: the browser
#      maps the hosts to that address with a resolver rule.
#   2. Port-forwards Mailpit's read API to a local port.
#   3. Runs the browser drill (driver.mjs): signup form -> delivered mail ->
#      verification link -> password -> provisioning redirect.
#   4. Asserts cluster-side truth: the Tenant CR reaches phase=Ready, the
#      tenant namespace exists, and the founding member reaches Active
#      (gibson#1510). Nothing in that section writes.
#   5. The owner signs in for the first time (platform-owner driver):
#      password, the forced TOTP enrollment, a landing under /dashboard that
#      shows the workspace (gibson#1188).
#   6. Runs the failing fixture: every path around the verification gate must
#      bounce, and the fixture must create no Tenant.
#
# Modes:
#   --selftest   offline. Proves the driver's parsing assertions can fail,
#                that this script's cluster assertion can fail (stubbed
#                kubectl), and that the overlay still names the sink. No
#                cluster, no network, no sudo.
#
# Env (live mode):
#   NS            namespace                          (default: gibson)
#   RELEASE       the umbrella release name          (default: gibson)
#   DOMAIN        the platform domain                (default: gibson-domains ConfigMap)
#   EDGE_IP       the Envoy edge address             (default: the LoadBalancer ingress)
#   DIAG_DIR      where the driver drops failure screenshots (default: unset)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS="${NS:-gibson}"
RELEASE="${RELEASE:-gibson}"
MAILPIT_SVC="${MAILPIT_SVC:-${RELEASE}-mailpit}"
ENVOY_SVC="${ENVOY_SVC:-${RELEASE}-envoy}"
MAILPIT_LOCAL_PORT="${MAILPIT_LOCAL_PORT:-18025}"

log() { printf '\n\033[1;32m▶\033[0m %s\n' "$*"; }
die() { printf '\033[0;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# member_phases <ns> — every TenantMember's status.phase in the namespace.
# Signup creates exactly one member (the founding owner); the phase that
# matters is Active (gibson#1510: Active is what seeds the FGA active_session
# tuples; anything else fail-closes every tenant RPC).
# ---------------------------------------------------------------------------
member_phases() {
  kubectl -n "$1" get tenantmembers.gibson.zeroroot.ai \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true
}

MEMBER_WAIT_TRIES="${MEMBER_WAIT_TRIES:-90}"
MEMBER_WAIT_SLEEP="${MEMBER_WAIT_SLEEP:-10}"
wait_member_active() {
  local ns="$1" phases=""
  for _ in $(seq 1 "$MEMBER_WAIT_TRIES"); do
    phases="$(member_phases "$ns")"
    if printf '%s\n' "$phases" | grep -qx 'Active'; then
      return 0
    fi
    sleep "$MEMBER_WAIT_SLEEP"
  done
  echo "no TenantMember reached Active (saw: ${phases:-<none>}). The owner can log in but the session gate denies every tenant RPC (gibson#1510)" >&2
  return 1
}

# Hidden probe so the selftest exercises the REAL function, not a copy.
if [ "${1:-}" = "--assert-member-active" ]; then
  wait_member_active "${2:?namespace required}"
  exit 0
fi

# ---------------------------------------------------------------------------
# --selftest: the guards lane. Offline, no cluster.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  command -v node >/dev/null || die "node is required for the selftest"

  log "driver selftest (mail parsing assertions can fail)"
  node "${SCRIPT_DIR}/driver.mjs" --selftest

  log "cluster-assertion selftest (member-Active check can fail)"
  STUB_DIR="$(mktemp -d)"
  trap 'rm -rf "$STUB_DIR"' EXIT
  cat > "${STUB_DIR}/kubectl" <<'STUB'
#!/usr/bin/env bash
# Selftest stub: reports a founding member stuck Invited.
echo "Invited"
STUB
  chmod +x "${STUB_DIR}/kubectl"
  if PATH="${STUB_DIR}:${PATH}" MEMBER_WAIT_TRIES=2 MEMBER_WAIT_SLEEP=0 \
      bash "${BASH_SOURCE[0]}" --assert-member-active tenant-selftest 2>/dev/null; then
    die "selftest: a member stuck Invited was accepted as Active. The assertion cannot fail"
  fi
  echo "selftest ok: a member stuck Invited is rejected"
  sed -i 's/echo "Invited"/echo "Active"/' "${STUB_DIR}/kubectl"
  PATH="${STUB_DIR}:${PATH}" MEMBER_WAIT_TRIES=2 MEMBER_WAIT_SLEEP=0 \
    bash "${BASH_SOURCE[0]}" --assert-member-active tenant-selftest \
    || die "selftest: an Active member was not accepted. The assertion is broken"
  echo "selftest ok: an Active member is accepted"

  log "overlay sanity (the values file names the Mailpit sink, not the log stub)"
  grep -q 'provider: "smtp"' "${SCRIPT_DIR}/values.yaml" \
    || die "selftest: the overlay no longer selects the smtp provider"
  grep -q 'host: "gibson-mailpit"' "${SCRIPT_DIR}/values.yaml" \
    || die "selftest: the overlay no longer points at the chart's Mailpit Service"
  grep -A1 'mailpit:' "${SCRIPT_DIR}/values.yaml" | grep -q 'enabled: true' \
    || die "selftest: the overlay no longer enables the Mailpit sink"
  echo "selftest ok: overlay still wires the daemon to Mailpit"

  log "selftest passed"
  exit 0
fi

# ---------------------------------------------------------------------------
# Live mode: preconditions
# ---------------------------------------------------------------------------
log "preconditions"
command -v kubectl >/dev/null || die "kubectl not on PATH"
command -v node >/dev/null || die "node not on PATH"
[ -d "${SCRIPT_DIR}/node_modules/playwright" ] \
  || die "playwright is not installed next to the driver. Run: npm --prefix ${SCRIPT_DIR} install && npx --prefix ${SCRIPT_DIR} playwright install --with-deps chromium"
[ -d "${SCRIPT_DIR}/../platform-owner/node_modules/otpauth" ] \
  || die "otpauth is not installed next to the platform-owner driver (the owner's first sign-in needs it). Run: npm --prefix ${SCRIPT_DIR}/../platform-owner ci"
kubectl -n "$NS" get pods --no-headers >/dev/null || die "kubectl cannot reach namespace ${NS}"
kubectl -n "$NS" get deploy "$MAILPIT_SVC" >/dev/null \
  || die "Mailpit Deployment ${MAILPIT_SVC} is absent. The exit-test overlay did not apply; without a delivering sink this test cannot measure anything"

# The daemon must be wired to the sink, not the non-delivering log stub. The
# StatefulSet is found by its component label, never by a spelled-out name.
DAEMON_STS="$(kubectl -n "$NS" get sts -l app.kubernetes.io/component=daemon -o name | head -1)"
[ -n "$DAEMON_STS" ] || die "no StatefulSet with app.kubernetes.io/component=daemon in ${NS}"
provider="$(kubectl -n "$NS" get "$DAEMON_STS" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="gibson")].env[?(@.name=="GIBSON_EMAIL_PROVIDER")].value}' 2>/dev/null || true)"
if [ "$provider" != "smtp" ]; then
  die "daemon GIBSON_EMAIL_PROVIDER is '${provider:-<absent>}', want smtp. The platform cannot deliver the verification mail"
fi
echo "daemon mail transport: smtp (delivering)"

# ---------------------------------------------------------------------------
# The customer edge, the way an operator finds it
# ---------------------------------------------------------------------------
if [ -z "${DOMAIN:-}" ]; then
  DOMAIN="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.domain}' 2>/dev/null || true)"
fi
[ -n "${DOMAIN:-}" ] || die "no DOMAIN and the gibson-domains ConfigMap names none"
APP_HOST="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.appHost}' 2>/dev/null || true)"
[ -n "$APP_HOST" ] || APP_HOST="app.${DOMAIN}"
API_HOST="api.${DOMAIN}"

if [ -z "${EDGE_IP:-}" ]; then
  EDGE_IP="$(kubectl -n "$NS" get svc "$ENVOY_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$EDGE_IP" ] || EDGE_IP="$(kubectl -n "$NS" get svc "$ENVOY_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
fi
[ -n "${EDGE_IP:-}" ] || die "the ${ENVOY_SVC} Service has no LoadBalancer address. cloud-provider-kind did not give it one"
echo "edge: ${APP_HOST} -> ${EDGE_IP}"

# ---------------------------------------------------------------------------
# Mailpit's read API
# ---------------------------------------------------------------------------
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib/port-forward-loop.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/port-forward-loop.sh"
cleanup() {
  pf_stop_all
  rm -f "${TOKEN_FILE:-}" "${TOTP_FILE:-}"
}
trap cleanup EXIT

log "port-forwarding Mailpit's read API onto 127.0.0.1:${MAILPIT_LOCAL_PORT}"
pf_loop "$NS" "svc/${MAILPIT_SVC}" "${MAILPIT_LOCAL_PORT}:8025"

APP_ORIGIN="https://${APP_HOST}"
MAILPIT_URL="http://127.0.0.1:${MAILPIT_LOCAL_PORT}"

log "waiting for the edge and the mail sink to answer"
edge=000; sink=000
for _ in $(seq 1 60); do
  edge="$(curl -kso /dev/null -w '%{http_code}' --resolve "${APP_HOST}:443:${EDGE_IP}" "${APP_ORIGIN}/login" || true)"
  sink="$(curl -so /dev/null -w '%{http_code}' "${MAILPIT_URL}/api/v1/messages" || true)"
  if [ "$sink" = "200" ] && [ "$edge" != "000" ] && [ "$edge" != "502" ] && [ "$edge" != "503" ]; then
    echo "edge answers ${edge}, Mailpit answers ${sink}"
    break
  fi
  sleep 5
done
[ "$sink" = "200" ] || die "Mailpit's read API never answered on ${MAILPIT_URL}"
[ "$edge" != "000" ] || die "the customer edge never answered on ${APP_ORIGIN} at ${EDGE_IP}"

# ---------------------------------------------------------------------------
# The drill
# ---------------------------------------------------------------------------
SIGNUP_SLUG="${SIGNUP_SLUG:-sg-$(date +%s | tail -c 6)$(openssl rand -hex 2)}"
SIGNUP_EMAIL="${SIGNUP_EMAIL:-${SIGNUP_SLUG}@signup.example.test}"
SIGNUP_PASSWORD="Xt1!$(openssl rand -hex 12)"
TOKEN_FILE="$(mktemp)"
TOTP_FILE="$(mktemp)"
chmod 600 "$TOKEN_FILE"

TENANTS_BEFORE="$(kubectl get tenants.gibson.zeroroot.ai -o name | sort)"

log "drill: signup as ${SIGNUP_EMAIL} (workspace ${SIGNUP_SLUG})"
APP_ORIGIN="$APP_ORIGIN" MAIL_SOURCE=mailpit MAILPIT_URL="$MAILPIT_URL" SIGNUP_PROFILE=baseline \
  EDGE_IP="$EDGE_IP" EDGE_HOSTS="${APP_HOST} ${API_HOST} ${DOMAIN}" \
  SIGNUP_SLUG="$SIGNUP_SLUG" SIGNUP_EMAIL="$SIGNUP_EMAIL" \
  SIGNUP_PASSWORD="$SIGNUP_PASSWORD" TOKEN_OUT="$TOKEN_FILE" \
  DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/driver.mjs" --drill

# ---------------------------------------------------------------------------
# Cluster-side truth: the workspace is Ready and the owner can act. Nothing
# here WRITES. The whole point is that the signup above needed no manual touch.
# ---------------------------------------------------------------------------
log "asserting tenant ${SIGNUP_SLUG} reaches phase=Ready"
kubectl wait --for=jsonpath='{.status.phase}'=Ready \
  "tenant/${SIGNUP_SLUG}" --timeout=15m

log "asserting the tenant namespace exists"
kubectl get namespace "tenant-${SIGNUP_SLUG}" >/dev/null

log "asserting the founding member reaches Active"
wait_member_active "tenant-${SIGNUP_SLUG}"
echo "founding member is Active"

# The owner can act: a first sign-in with the password set at signup, the
# forced TOTP enrollment, and a landing under /dashboard. An owner who lands
# on the onboarding page has a workspace they cannot reach: the account sits
# in the wrong Zitadel org or holds no role (gibson#1188). The platform-owner
# driver owns every password+TOTP browser step (one codepath).
log "drill: ${SIGNUP_EMAIL} signs in for the first time and lands in the workspace ${SIGNUP_SLUG}"
OWNER_EMAIL="$SIGNUP_EMAIL" OWNER_PASSWORD="$SIGNUP_PASSWORD" \
  LANDING_ORIGIN="$APP_ORIGIN" TOTP_SECRET_OUT="$TOTP_FILE" EXPECT_PATH=/dashboard \
  EXPECT_WORKSPACE="$SIGNUP_SLUG" \
  EDGE_IP="$EDGE_IP" EDGE_HOSTS="${APP_HOST} ${API_HOST} ${DOMAIN}" DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/../platform-owner/driver.mjs" --first-sign-in
[ -s "$TOTP_FILE" ] || die "the first sign-in enrolled no second factor: the sign-in policy must force MFA (ADR-0093)"
echo "the owner signed in with a password and a new second factor, and landed in ${SIGNUP_SLUG}"

# ---------------------------------------------------------------------------
# The failing fixture
# ---------------------------------------------------------------------------
log "fixture: every path around the verification gate must bounce"
APP_ORIGIN="$APP_ORIGIN" EDGE_IP="$EDGE_IP" EDGE_HOSTS="${APP_HOST} ${API_HOST} ${DOMAIN}" \
  TOKEN_IN="$TOKEN_FILE" DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/driver.mjs" --fixture

log "asserting the fixture created no tenant"
TENANTS_AFTER="$(kubectl get tenants.gibson.zeroroot.ai -o name | sort)"
EXPECTED="$(printf '%s\ntenant.gibson.zeroroot.ai/%s\n' "$TENANTS_BEFORE" "$SIGNUP_SLUG" | sed '/^$/d' | sort)"
if [ "$TENANTS_AFTER" != "$EXPECTED" ]; then
  echo "--- expected"; echo "$EXPECTED"
  echo "--- actual"; echo "$TENANTS_AFTER"
  die "the tenant list changed beyond the drill's own workspace. An unverified path created state"
fi

rm -f "$TOKEN_FILE"
log "EXIT TEST PASSED: ${SIGNUP_EMAIL} received the mail, workspace ${SIGNUP_SLUG} is Ready, its owner signed in and landed in it, and no path around verification exists"
