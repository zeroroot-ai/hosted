#!/usr/bin/env bash
# smoke-signup.sh — Gate 3 shippability smoke for the dev cluster.
#
# Proves the cluster is not just "all pods Ready" but actually serves a
# working signup-to-tenant-provisioning flow.
#
# Flow (one browser drill for the signup, then cluster and edge assertions):
#   1. Pre-flight: cluster reachable, key pods Running.
#   2. Signup through the edge with the one signup driver
#      (test/signup/driver.mjs, hosted#647): form, delivered mail, link,
#      password and, on the SaaS profile, the Stripe TEST card. The platform
#      makes the user and the Tenant from the signup.
#   4. Wait for Tenant CR to reach phase=Ready (all saga conditions True).
#   5. Assert Tenant CR phase=Ready, FGA membership tuple present.
#   6. Assert /api/signup/status?tenant=<slug> returns {"status":"active"}.
#   7. Assert unauthenticated probe of /api/missions → 401/302 (not 500).
#   8. Assert per-tenant OpenBao secret/infra/{postgres,redis,vector,neo4j} all
#      populated (catches the regression class behind tenant-operator#189).
#   9. Assert daemon does NOT emit `broker config not found` / `secrets
#      circuit opened` / `tenant data-plane not provisioned` for this
#      tenant in the 15s after a triggering RPC (catches gibson#262).
#  10. FIRST MISSION (deploy#1398) — asserts the credential chain a mission
#      call rides on, against the env under test: the api edge REJECTS an
#      unauthenticated DaemonService call, and ACCEPTS a token minted from
#      this cluster's own service credential. Both are hard failures. The
#      mission RPCs themselves are still uncallable (no edge reflection / no
#      published daemon descriptor; service tokens misclassified as
#      oidc-user), so this step never prints a green "first mission passed";
#      it warns, or fails under REQUIRE_MISSION=1.
#  11. Cleanup: delete the test Tenant CR on EXIT (finalizers clean Zitadel
#      + FGA tuples).
#
# Usage:
#   bash scripts/smoke-signup.sh
#   make smoke-signup     (invokes this script)
#
#   NAMESPACE=gibson CLUSTER_URL=https://app.zeroroot.ai:30443 \
#     bash scripts/smoke-signup.sh
#
# Env:
#   NAMESPACE    gibson namespace          (default: gibson)
#   CLUSTER_URL  dashboard external URL   (default: gibson-domains/externalOrigin)
#   CURL_RESOLVE host:port:addr for curl  (default: the app host pinned to the
#                                          Envoy Service address, so a
#                                          workstation with no DNS for the
#                                          install's domain still probes it)
#   API_URL      daemon edge URL          (default: the cluster's own
#                                          gibson-domains/apiOrigin; falls
#                                          back to rewriting CLUSTER_URL's
#                                          app. label to api.)
#   SMOKE_SA_SECRET  Secret holding the MACHINE_USER client credential used
#                for the step-10 edge-auth assertion
#                (default: gibson-zitadel-tenant-operator)
#   REQUIRE_MISSION  set "1" to FAIL (not warn) while the mission RPCs remain
#                uncallable (deploy#1398)
#   SIGNUP_PROFILE  baseline | saas (required, hosted#647)
#   MAIL_SOURCE  mailpit (with MAILPIT_URL) | s3 (with INBOX_BUCKET and
#                INBOX_DOMAIN) (required, hosted#647)
#   SMOKE_SLUG   tenant slug (DNS-safe)   (default: auto-generated timestamp-based)
#   KEEP_TENANT  set "1" to skip cleanup  (default: 0)
#   TEARDOWN_TIMEOUT  seconds cleanup waits for the deleted Tenant to be gone;
#                a Tenant still there after that FAILS the smoke (default: 300)
#   TEARDOWN_POLL  seconds between those reads (default: 5)
#   TIMEOUT_TENANT  seconds to wait for   (default: 120)
#     Tenant phase=Ready
#
# Exit codes:
#   0 — all assertions passed
#   1 — at least one assertion failed; diagnostic printed to stderr
#   2 — pre-flight failed (cluster unreachable / missing secrets)

set -euo pipefail

NAMESPACE="${NAMESPACE:-gibson}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# smoke-probe.sh sources lib/cluster-probe.sh (capture, resolve_edge).
# shellcheck source=lib/smoke-probe.sh
source "${SCRIPT_DIR}/lib/smoke-probe.sh"
# The install states its own origin in the gibson-domains ConfigMap (deploy#630
# SSOT). The old default app.zeroroot.ai:30443 named a host no baseline install
# serves.
if [ -z "${CLUSTER_URL:-}" ]; then
  if ! capture CLUSTER_URL kubectl -n "${NAMESPACE}" get configmap gibson-domains -o 'jsonpath={.data.externalOrigin}'; then
    echo "smoke-signup: no CLUSTER_URL, and the gibson-domains ConfigMap cannot be read: ${PROBE_ERR}" >&2
    exit 2
  fi
fi
[ -n "${CLUSTER_URL:-}" ] || { echo "smoke-signup: no CLUSTER_URL, and the gibson-domains ConfigMap has no externalOrigin" >&2; exit 2; }
# Host-side curl probes pin the app host to the edge address (the baseline
# domain resolves nowhere from a workstation). CURL_RESOLVE overrides.
# A host that public DNS resolves (an AWS env) is probed through that DNS: the
# public edge a customer reaches. Pinning it to the node address took the
# InternalIP (a private 10.x address of a NodePort), which the CI runner
# cannot reach, so steps 4 and 5 could only time out (drill path audit, row
# 7). Only a host that resolves nowhere (kind) is pinned to the edge.
_app_host="$(printf '%s' "${CLUSTER_URL}" | sed -E 's#^https?://([^/:]+).*#\1#')"
if [ -z "${CURL_RESOLVE:-}" ] && ! getent hosts "${_app_host}" >/dev/null; then
  _edge=""
  if ! capture _edge resolve_edge "${NAMESPACE}"; then
    echo "smoke-signup: ${_app_host} resolves nowhere, and the edge of ${NAMESPACE} cannot be found: ${PROBE_ERR}" >&2
    exit 2
  fi
  CURL_RESOLVE="$(_edge_curl_args "$_edge" "$_app_host" | sed -n 2p)"
fi
CURL_RESOLVE="${CURL_RESOLVE:-}"
CURL_EXTRA=()
[ -n "$CURL_RESOLVE" ] && CURL_EXTRA=(--resolve "$CURL_RESOLVE")
KEEP_TENANT="${KEEP_TENANT:-0}"
TIMEOUT_TENANT="${TIMEOUT_TENANT:-120}"
# How long cleanup waits for the deleted Tenant to be gone, and how often it
# looks (seconds).
TEARDOWN_TIMEOUT="${TEARDOWN_TIMEOUT:-300}"
TEARDOWN_POLL="${TEARDOWN_POLL:-5}"

urlenc() {  # <value> -> the value, percent-encoded for a form body. Builtins only.
  # LC_ALL=C makes each step one byte, so a UTF-8 character becomes its bytes.
  local LC_ALL=C s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# client_credentials_token <token url> <client id> <client secret>: the
# token response of a client_credentials grant, with the edge CA pinned. The
# secret goes in the body on stdin, never on the curl command line (drill
# sweep row 28). urlenc is a shell function, so no argv holds it on the way.
client_credentials_token() {
  printf 'grant_type=client_credentials&client_id=%s&client_secret=%s&scope=%s' \
      "$(urlenc "$2")" "$(urlenc "$3")" \
      "$(urlenc 'openid urn:zitadel:iam:org:project:id:gibson-platform:aud')" \
    | curl --cacert "$EDGE_CA" -sS --max-time 20 -X POST "$1" \
        -H 'content-type: application/x-www-form-urlencoded' --data-binary @-
}

FAILED=0
EDGE_CA=""

# Generate unique slug (timestamp + random suffix) so concurrent runs don't collide.
if [[ -z "${SMOKE_SLUG:-}" ]]; then
  SMOKE_SLUG="smoke-$(date +%s | tail -c 6)-$(openssl rand -hex 2)"
fi

# await_tenant_gone <slug>: 0 once the Tenant is gone, 1 when it is still there
# after TEARDOWN_TIMEOUT seconds. A read that fails is a failure, never "gone".
await_tenant_gone() {
  local slug="$1" waited=0 left=""
  while :; do
    if ! capture left kubectl get tenant "${slug}" --ignore-not-found=true -o name; then
      warn "cannot read the Tenant ${slug}: ${PROBE_ERR}"
      return 1
    fi
    [[ -z "${left}" ]] && return 0
    (( waited >= TEARDOWN_TIMEOUT )) && return 1
    sleep "${TEARDOWN_POLL}"
    waited=$(( waited + TEARDOWN_POLL ))
  done
}

# Cleanup on exit (best-effort — finalizers handle Zitadel + FGA cleanup).
cleanup() {
  local exit_code=$?
  [[ -z "${EDGE_CA:-}" ]] || rm -f "${EDGE_CA}"
  if [[ "${KEEP_TENANT:-0}" != "1" ]]; then
    printf "\n${CYN}--- cleanup ---%s\n" "${NC}"
    printf "  deleting Tenant CR %s (best-effort)...\n" "${SMOKE_SLUG}"
    # --wait=false: the delete is requested, and the wait below is bounded. A
    # tenant whose data-plane deprovision fails keeps its finalizer (gibson#128),
    # and a waiting delete never returns. The smoke hung on one for ten minutes
    # on staging (2026-09-17).
    local _deleted=""
    if ! capture _deleted kubectl -n "${NAMESPACE}" delete tenant "${SMOKE_SLUG}" --ignore-not-found=true --wait=false; then
      fail "the Tenant ${SMOKE_SLUG} was not deleted: ${PROBE_ERR}"
    elif ! await_tenant_gone "${SMOKE_SLUG}"; then
      # A delete that was requested is not a delete that happened. Two smoke
      # tenants stayed in deletion for 13 days on staging, each holding a
      # 500m Neo4j pod, until the node had no CPU left for the next smoke
      # (hosted#23). The smoke passed every time, because it never looked.
      local _state=""
      capture _state kubectl get tenant "${SMOKE_SLUG}" -o 'jsonpath=deletionTimestamp={.metadata.deletionTimestamp} finalizers={.metadata.finalizers} phase={.status.phase}' || _state="unreadable: ${PROBE_ERR}"
      fail "the Tenant ${SMOKE_SLUG} is still there ${TEARDOWN_TIMEOUT}s after its delete (${_state}). It keeps its namespace and data-plane pods until the tenant-operator finishes the delete."
    fi
  fi
  if [[ "${FAILED}" -gt 0 ]]; then
    exit_code=1
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
heading "Pre-flight"
# ─────────────────────────────────────────────────────────────────────────────

if ! command -v kubectl >/dev/null 2>&1; then
  printf "${RED}[FAIL]${NC} kubectl not on PATH\n" >&2; exit 2
fi
_pods=""
if ! capture _pods kubectl -n "${NAMESPACE}" get pods --no-headers; then
  printf "${RED}[FAIL]${NC} kubectl cannot reach namespace %s: %s\n" "${NAMESPACE}" "${PROBE_ERR}" >&2; exit 2
fi
pass "kubectl reachable (namespace: ${NAMESPACE})"

# Key pods must be Running before we proceed.
# Use component labels as set by the gibson-workloads / gibson-operators charts.
declare -A COMPONENT_LABELS
COMPONENT_LABELS["daemon"]="app.kubernetes.io/name=gibson-workloads"
COMPONENT_LABELS["dashboard"]="app.kubernetes.io/component=dashboard"
COMPONENT_LABELS["ext-authz"]="app.kubernetes.io/component=ext-authz"
COMPONENT_LABELS["platform-operator"]="app.kubernetes.io/component=platform-operator"
COMPONENT_LABELS["tenant-operator"]="app.kubernetes.io/component=tenant-operator"

for svc in daemon dashboard ext-authz platform-operator tenant-operator; do
  LABEL="${COMPONENT_LABELS[$svc]}"
  POD_STATUS=""
  if ! capture POD_STATUS kubectl -n "${NAMESPACE}" get pods -l "${LABEL}" -o 'jsonpath={.items[0].status.phase}'; then
    warn "pod ${svc}: cannot read its phase (label: ${LABEL}): ${PROBE_ERR}"
  elif [[ "${POD_STATUS}" == "Running" ]]; then
    pass "pod ${svc}: Running"
  else
    warn "pod ${svc}: phase=${POD_STATUS:-none} (label: ${LABEL})"
  fi
done

# --- daemon edge URL -------------------------------------------------------
# A hardcoded api.zeroroot.ai here silently dialled PROD from every staging
# smoke (deploy#1398 — the deploy#630 hostname-derivation class).
#
# Single source of truth: the cluster publishes every hostname it serves in
# the gibson-domains ConfigMap, each derived from global.domain by the
# gibson-common helpers (deploy#630). Reading `apiOrigin` from the cluster
# under test asks the install what it thinks its own API host is, rather than
# re-deriving it here and hoping the two rules agree — and it carries the
# externalPort suffix, which kind needs and a scheme/host rewrite would drop.
#
# The CLUSTER_URL rewrite stays as the fallback for a cluster whose chart
# predates the ConfigMap; the cross-check below makes either source safe.
API_URL_SOURCE="API_URL env override"
if [[ -z "${API_URL:-}" ]]; then
  API_URL_SOURCE="gibson-domains ConfigMap (deploy#630 SSOT)"
  API_URL=""
  if ! capture API_URL kubectl -n "${NAMESPACE}" get cm gibson-domains -o 'jsonpath={.data.apiOrigin}'; then
    if ! not_found; then
      printf "${RED}[FAIL]${NC} cannot read apiOrigin from the gibson-domains ConfigMap: %s\n" "${PROBE_ERR}" >&2
      exit 2
    fi
    API_URL=""
  fi
fi
if [[ -z "${API_URL:-}" ]]; then
  API_URL_SOURCE="derived from CLUSTER_URL (gibson-domains ConfigMap absent)"
  API_URL=$(printf '%s' "${CLUSTER_URL}" | sed -E 's#^(https?://)app\.#\1api.#')
fi

# Same-environment cross-check. Whatever produced API_URL — ConfigMap, env
# override or rewrite — it must name the SAME domain as CLUSTER_URL. This is
# the deploy#1398 defect asserted at runtime rather than merely fixed: a
# staging run that somehow acquires a prod API host stops here instead of
# probing the wrong cluster and reporting on it.
_host_domain() {  # strip scheme, port and the leading app./api. label
  printf '%s' "$1" | sed -E 's#^https?://##; s#[:/].*$##; s#^(app|api)\.##'
}
API_DOMAIN=$(_host_domain "${API_URL}")
CLUSTER_DOMAIN=$(_host_domain "${CLUSTER_URL}")
if [[ "${API_DOMAIN}" != "${CLUSTER_DOMAIN}" ]]; then
  printf "${RED}[FAIL]${NC} API_URL (%s, %s) resolves to domain '%s' but CLUSTER_URL (%s) is '%s' — the smoke would probe a DIFFERENT environment than the one under test. Refusing to run (deploy#1398).\n" \
    "${API_URL}" "${API_URL_SOURCE}" "${API_DOMAIN}" "${CLUSTER_URL}" "${CLUSTER_DOMAIN}" >&2
  exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "Step 1: sign up through the edge, the way a customer does"
# ─────────────────────────────────────────────────────────────────────────────
# One signup driver for every target (hosted#647, ADR-0027): the browser drill
# of the signup exit test, test/signup/driver.mjs. It fills the dashboard
# signup form, reads the verification mail from the mail source of the target,
# redeems the link, sets the password and, on the SaaS profile, pays the
# signup step with the Stripe TEST card. Nothing here writes a Tenant CR or a
# user: the platform makes them from the signup, as it does for a customer.
#
# The inputs that differ per target, and nothing else:
#   MAIL_SOURCE      mailpit (kind, with MAILPIT_URL) or s3 (an AWS env, with
#                    INBOX_BUCKET and INBOX_DOMAIN, stage 0 inbox.tf)
#   SIGNUP_PROFILE   baseline (card-free) or saas (card-first)
DRIVER_DIR="${SIGNUP_DRIVER_DIR:-${SCRIPT_DIR}/../test/signup}"
SIGNUP_PROFILE="${SIGNUP_PROFILE:-}"
case "${SIGNUP_PROFILE}" in
  baseline|saas) ;;
  *) fail "SIGNUP_PROFILE must be baseline or saas, got '${SIGNUP_PROFILE}'"; exit 2 ;;
esac
case "${MAIL_SOURCE:-}" in
  mailpit) [[ -n "${MAILPIT_URL:-}" ]] || { fail "MAIL_SOURCE=mailpit needs MAILPIT_URL"; exit 2; }
           SMOKE_MAIL_DOMAIN="${SMOKE_MAIL_DOMAIN:-signup.example.test}" ;;
  s3)      [[ -n "${INBOX_BUCKET:-}" && -n "${INBOX_DOMAIN:-}" ]] \
             || { fail "MAIL_SOURCE=s3 needs INBOX_BUCKET and INBOX_DOMAIN (stage 0 substrate.env, hosted#647)"; exit 2; }
           SMOKE_MAIL_DOMAIN="${INBOX_DOMAIN}"
           # Only verified mail from the platform's own domain is read
           # (hosted#649 review): the domain of the app origin, minus app.
           MAIL_SENDER_DOMAIN="${MAIL_SENDER_DOMAIN:-$(printf '%s' "${CLUSTER_URL}" | sed -E 's#^https?://##; s#[:/].*$##; s#^app\.##')}" ;;
  *) fail "MAIL_SOURCE must be mailpit or s3, got '${MAIL_SOURCE:-}'"; exit 2 ;;
esac
# The test inbox takes mail for any address of its domain, from anyone. The
# run reads only the mail of its own address, and that address carries 96
# random bits, so a stranger cannot address mail to the run (hosted#650
# review). The driver also follows only a link on the app origin.
SMOKE_EMAIL="${SMOKE_SLUG}-$(openssl rand -hex 12)@${SMOKE_MAIL_DOMAIN}"

# The card step never runs on a live Stripe key: it would charge a real card
# (hosted#647). The driver also refuses a live Checkout session; this stops
# the run before the browser opens.
if [[ "${SIGNUP_PROFILE}" == saas ]]; then
  # The Secret the billing component reads its key from: the overlay's
  # ExternalSecret gibson-billing-stripe writes it from the OpenBao key
  # gibson-stripe-credentials. That OpenBao key is not a Kubernetes Secret.
  stripe_value=""
  if ! secret_data stripe_value gibson-billing-stripe STRIPE_SECRET_KEY; then
    fail "cannot read STRIPE_SECRET_KEY from the Secret gibson-billing-stripe: ${PROBE_ERR}"
    exit 2
  fi
  stripe_mode="${stripe_value:0:8}"
  case "${stripe_value}" in
    '') fail "the Secret gibson-billing-stripe has no STRIPE_SECRET_KEY. Set the keyring member STRIPE_SECRET_KEY (scripts/keyring.sh set), make substrate, and recreate"; exit 2 ;;
    *placeholder*) fail "the Secret gibson-billing-stripe holds the chart's placeholder: the keyring member STRIPE_SECRET_KEY is not set for this env. Set it (scripts/keyring.sh set), make substrate, and recreate"; exit 2 ;;
  esac
  stripe_value=""
  case "${stripe_mode}" in
    sk_test_|rk_test_) pass "the Stripe key of the env is a test key: the card step pays with the Stripe test card" ;;
    sk_live_|rk_live_) fail "the Stripe key of the env is a LIVE key. This smoke never pays on a live key; it does not run the card step on this env"; exit 2 ;;
    *) fail "cannot tell the mode of the Stripe key of the env (Secret gibson-billing-stripe, key STRIPE_SECRET_KEY); the card step does not run blind"; exit 2 ;;
  esac
  stripe_mode=""
fi

command -v node >/dev/null 2>&1 || { fail "node is not on PATH: the signup driver is a browser drill"; exit 2; }
[[ -d "${DRIVER_DIR}/node_modules/playwright" ]] \
  || { fail "playwright is not installed next to the driver. Run: npm --prefix ${DRIVER_DIR} ci && npx --prefix ${DRIVER_DIR} playwright install --with-deps chromium"; exit 2; }

# The SaaS signup page takes a self-serve plan (?plan=); without one it sends
# the browser to the pricing page. The baseline profile has no plans.
if [[ "${SIGNUP_PROFILE}" == saas ]]; then SIGNUP_PLAN="${SIGNUP_PLAN:-team}"; else SIGNUP_PLAN=""; fi
SMOKE_PASSWORD="Xt1!$(openssl rand -hex 12)"
SIGNUP_TOKEN_FILE="$(mktemp)"
chmod 600 "${SIGNUP_TOKEN_FILE}"
printf "  slug=%s\n  email=%s\n  cluster=%s\n  mail=%s  profile=%s\n" \
  "${SMOKE_SLUG}" "${SMOKE_EMAIL}" "${CLUSTER_URL}" "${MAIL_SOURCE}" "${SIGNUP_PROFILE}"
if APP_ORIGIN="${CLUSTER_URL}" MAIL_SOURCE="${MAIL_SOURCE}" MAILPIT_URL="${MAILPIT_URL:-}" \
    INBOX_BUCKET="${INBOX_BUCKET:-}" MAIL_SENDER_DOMAIN="${MAIL_SENDER_DOMAIN:-}" SIGNUP_PROFILE="${SIGNUP_PROFILE}" \
    SIGNUP_PLAN="${SIGNUP_PLAN}" \
    EDGE_IP="${EDGE_IP:-}" EDGE_HOSTS="${EDGE_HOSTS:-}" \
    SIGNUP_SLUG="${SMOKE_SLUG}" SIGNUP_EMAIL="${SMOKE_EMAIL}" SIGNUP_PASSWORD="${SMOKE_PASSWORD}" \
    TOKEN_OUT="${SIGNUP_TOKEN_FILE}" DIAG_DIR="${DIAG_DIR:-}" \
    node "${DRIVER_DIR}/driver.mjs" --drill; then
  pass "signup through the edge: ${SMOKE_EMAIL} received the mail and completed signup"
else
  fail "the signup drill failed (see the driver output above)"
  exit 1
fi
rm -f "${SIGNUP_TOKEN_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
heading "Step 3: Wait for Tenant phase=Ready (timeout ${TIMEOUT_TENANT}s)"
# ─────────────────────────────────────────────────────────────────────────────
DEADLINE=$(( $(date +%s) + TIMEOUT_TENANT ))
TENANT_PHASE=""
while true; do
  NOW=$(date +%s)
  if [[ "${NOW}" -ge "${DEADLINE}" ]]; then
    if ! capture TENANT_PHASE kubectl -n "${NAMESPACE}" get tenant "${SMOKE_SLUG}" -o 'jsonpath={.status.phase}'; then
      TENANT_PHASE="unreadable: ${PROBE_ERR}"
    fi
    fail "Tenant ${SMOKE_SLUG} did not reach phase=Ready within ${TIMEOUT_TENANT}s (phase=${TENANT_PHASE})"
    printf "  Conditions:\n"
    _conds=""
    if ! capture _conds kubectl -n "${NAMESPACE}" get tenant "${SMOKE_SLUG}" \
        -o go-template='{{range .status.conditions}}  {{.type}}: {{.status}} ({{.reason}}) {{.message}}{{"\n"}}{{end}}'; then
      _conds="  cannot read the conditions: ${PROBE_ERR}"
    fi
    printf '%s\n' "${_conds}"
    break
  fi
  # A NotFound is normal until the platform makes the Tenant. Any other error
  # shows in the status line, so a refusal never reads as "Pending".
  if ! capture TENANT_PHASE kubectl -n "${NAMESPACE}" get tenant "${SMOKE_SLUG}" -o 'jsonpath={.status.phase}'; then
    not_found || printf "\n  cannot read the Tenant: %s\n" "${PROBE_ERR}"
    TENANT_PHASE=""
  fi
  REMAINING=$(( DEADLINE - NOW ))
  printf "  phase=%-20s [%ds remaining]\r" "${TENANT_PHASE:-Pending}" "${REMAINING}"
  if [[ "${TENANT_PHASE}" == "Ready" || "${TENANT_PHASE}" == "Active" ]]; then
    printf "\n"
    pass "Tenant ${SMOKE_SLUG} reached phase=${TENANT_PHASE}"
    break
  fi
  sleep 5
done

# ─────────────────────────────────────────────────────────────────────────────
heading "Step 4: Assert /api/signup/status?tenant=<slug> returns status=active"
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v curl >/dev/null 2>&1; then
  warn "curl not on PATH — skipping dashboard API probe (step 4)"
else
  STATUS_RESP=""
  STATUS_FIELD=""
  STATUS_ERR=""
  if ! capture STATUS_RESP curl -ksS --max-time 10 "${CURL_EXTRA[@]}" \
      "${CLUSTER_URL}/api/signup/status?tenant=${SMOKE_SLUG}"; then
    STATUS_ERR="${PROBE_ERR}"
  else
    STATUS_FIELD=$(printf '%s' "${STATUS_RESP}" | \
      node -p "try { JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).status || ''; } catch(e) { ''; }")
  fi
  printf "  /api/signup/status?tenant=%s → status=%s\n" "${SMOKE_SLUG}" "${STATUS_FIELD}"
  if [[ -n "${STATUS_ERR}" ]]; then
    fail "/api/signup/status at ${CLUSTER_URL} did not answer: ${STATUS_ERR}"
  elif [[ "${STATUS_FIELD}" == "active" ]]; then
    pass "/api/signup/status returns status=active"
  elif [[ "${STATUS_FIELD}" == "provisioning" ]]; then
    fail "/api/signup/status still says provisioning, and the Tenant is Ready: the dashboard does not see the tenant the platform made"
  elif [[ -z "${STATUS_FIELD}" ]]; then
    fail "/api/signup/status at ${CLUSTER_URL} returned no status field. The body starts: ${STATUS_RESP:0:160}"
  else
    fail "/api/signup/status returned unexpected status=${STATUS_FIELD} (want active)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "Step 5: Unauthenticated probe — dashboard auth chain (deploy#143)"
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v curl >/dev/null 2>&1; then
  warn "curl not on PATH — skipping unauthenticated probe (step 5)"
else
  # `-w %{http_code}` already prints 000 when the request never completes;
  # the old `|| echo 000` appended a SECOND one, producing the nonsense
  # "HTTP 000000" that made a resolution failure look like a new class of bug.
  CODE=""
  CODE_ERR=""
  if ! capture CODE curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 \
      "${CURL_EXTRA[@]}" "${CLUSTER_URL}/api/missions"; then
    CODE_ERR="${PROBE_ERR}"
  fi
  CODE="${CODE:-000}"
  printf "  GET %s/api/missions → HTTP %s\n" "${CLUSTER_URL}" "${CODE}"
  if [[ "${CODE}" == "401" || "${CODE}" == "302" || "${CODE}" == "307" ]]; then
    pass "unauthenticated probe returned ${CODE} (auth chain reachable; no session cookie as expected)"
  elif [[ "${CODE}" == "500" || "${CODE}" == "503" ]]; then
    fail "unauthenticated probe returned ${CODE} — auth chain is broken (deploy#140-class regression)"
  elif [[ "${CODE}" == "000" ]]; then
    fail "the dashboard at ${CLUSTER_URL} is unreachable. The customer edge does not answer: ${CODE_ERR}"
  else
    fail "unexpected HTTP ${CODE} from the unauthenticated probe of ${CLUSTER_URL}/api/missions (want 401, 302 or 307)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "Step 6: Per-tenant Vault secret/infra/* are populated (tenant-operator#189)"
# ─────────────────────────────────────────────────────────────────────────────
# After Phase=Ready, the per-tenant OpenBao namespace must hold
# secret/infra/{postgres,redis,vector,neo4j}. A missing entry means
# one of the dataplane provisioners in cmd/main.go was not wired with
# a VaultClient — historically the regression class behind every "I
# logged in and got 412 on /api/missions" report.
#
# The check is assert_tenant_infra in lib/smoke-probe.sh, which names the
# token it lists with and why.
assert_tenant_infra "${SMOKE_SLUG}"

# ─────────────────────────────────────────────────────────────────────────────
heading "Step 7: Daemon secrets broker resolves for this tenant (gibson#262)"
# ─────────────────────────────────────────────────────────────────────────────
# The smoke for the tenant data-plane: tail daemon logs for 20s and
# assert no "broker config not found" / "secrets circuit opened" /
# "tenant data-plane not provisioned" pattern fires for this tenant.
# These are the exact log signatures we get when:
#   - the broker_config row is missing (tenant-operator-side gap), or
#   - the broker_config row is present but the daemon's vault factory
#     keys the AuthCache wrong and the refresh closure can't find it
#     (gibson#262, the daemon-side gap).
#
# If the saga is healthy AND the daemon's broker stack is healthy,
# the logs are quiet for this tenant on the secrets-circuit dimension.
# The daemon pod by its component label: name=gibson-workloads also selects
# OpenBao and Redis (drill path audit, row 15).
DAEMON_POD=""
DAEMON_POD_ERR=""
if ! capture DAEMON_POD kubectl -n "${NAMESPACE}" get pod -l "app.kubernetes.io/component=daemon" \
    -o 'jsonpath={.items[0].metadata.name}'; then
  DAEMON_POD_ERR="${PROBE_ERR}"
fi
# The dashboard pod is the in-cluster origin of the broker probe. hosted#650
# deleted the line that found it with the signup-bot step, and the probe ran
# `kubectl exec ""` (drill path audit, row 1).
DASH_POD=""
if ! capture DASH_POD kubectl -n "${NAMESPACE}" get pod -l "app.kubernetes.io/component=dashboard" \
    -o 'jsonpath={.items[0].metadata.name}' || [[ -z "${DASH_POD}" ]]; then
  fail "no dashboard pod (app.kubernetes.io/component=dashboard) in ${NAMESPACE}: the broker probe has no in-cluster origin. ${PROBE_ERR}"
  exit 1
fi
if [[ -z "${DAEMON_POD}" ]]; then
  fail "no daemon pod (app.kubernetes.io/component=daemon) in ${NAMESPACE}, so the broker log probe cannot run. ${DAEMON_POD_ERR}"
else
  # Force a broker activation by hitting any tenant-scoped dashboard
  # endpoint with a synthetic header trail. The daemon's secrets
  # broker activates lazily on the first authenticated call. Use the
  # dashboard pod as the in-cluster origin so the X-Gibson-Identity-*
  # headers get derived by Envoy + ext-authz.
  #
  # Note: we don't expect a 200 here — the smoke user has no session
  # cookie. The point is to trigger the daemon's secrets broker to
  # try to resolve this tenant's vault path, so any failure pattern
  # gets logged.
  # wget is EXPECTED to get an auth error back (no session): rc 8 = the server
  # answered with an error status, which proves the edge routed us to the
  # daemon. rc 0 would equally prove it. Anything else (rc 4 = network/DNS
  # failure, rc 1/2/3 = local errors) means the probe never reached the
  # daemon, so the log observation below would be vacuous — that was the old
  # '|| true' failure mode: dialling a hardcoded prod host from staging and
  # silently probing nothing (deploy#1398).
  # Judge by OUTPUT, not exit code. The rc 0/8 test was the whole check, and 8
  # is GNU wget's "server returned an error status" — but this image ships
  # BUSYBOX wget, which returns 1 for that AND for a local failure. So an edge
  # healthily answering 401 was indistinguishable from never dialling, and this
  # probe could not pass on this image at all. "server returned error" in the
  # output proves the edge routed us to the daemon, which is all this needs.
  #
  # --no-check-certificate matches step 5's curl -k. The baseline profile ships a
  # SELF-SIGNED edge issuer, so a strict client fails the handshake before it
  # ever reaches the daemon — this probe tests routing, not TLS trust, and
  # without the flag it can never pass on the supported self-hosted profile.
  set +e
  # NO `sh -c`. API_URL is read from the gibson-domains ConfigMap above, so
  # it is CLUSTER DATA: anyone who can write that ConfigMap could put
  # `; command` in it and have this run inside the dashboard pod. And
  # SMOKE_SLUG sat in single quotes, which a quote in the value escapes.
  # Passing both as argv elements means neither is parsed as shell.
  WGET_OUT=$(kubectl -n "${NAMESPACE}" exec "${DASH_POD}" -- \
    wget -qO- --no-check-certificate \
    --header "X-Smoke-Tenant: ${SMOKE_SLUG}" \
    -- "${API_URL}/gibson.daemon.v1.DaemonService/ListMissions" 2>&1)
  WGET_RC=$?
  set -e
  if [[ "${WGET_RC}" -eq 0 || "${WGET_RC}" -eq 8 ]] \
     || printf '%s' "${WGET_OUT}" | grep -qiE 'server returned error|HTTP/1\.[01] [0-9]{3}'; then
    pass "broker-activation probe reached ${API_URL} (wget rc=${WGET_RC})"
  else
    fail "broker-activation probe could NOT reach ${API_URL} (wget rc=${WGET_RC}) — daemon edge unreachable from dashboard pod; the log observation below cannot trigger"
    printf '%s\n' "${WGET_OUT}" | sed 's/^/    | /'
  fi

  # Give the daemon ~15s to either succeed or log a broken-path
  # message. The window is short because the failures we care about
  # fire on the first RPC.
  printf "  observing daemon logs for 15s...\n"
  sleep 15

  # Grep for any of the three regression signatures, scoped to the
  # smoke tenant ID via the slug substring (the daemon emits
  # tenant="<id>" or tenant="tenant-<id>" depending on the bug path).
  DAEMON_LOG=""
  BAD_LOG_LINES=""
  LOG_READ=0
  if ! capture DAEMON_LOG kubectl -n "${NAMESPACE}" logs "${DAEMON_POD}" --tail=500; then
    fail "cannot read the daemon log, so the broker failure signatures are unchecked: ${PROBE_ERR}"
  else
    LOG_READ=1
    # grep exits 1 when no line matches. That is the pass case, not an error.
    BAD_LOG_LINES=$(printf '%s\n' "${DAEMON_LOG}" \
      | grep -E "tenant=[\"']?(${SMOKE_SLUG}|tenant-${SMOKE_SLUG})" \
      | grep -E "broker config not found|secrets circuit opened|tenant data-plane not provisioned|circuit re-opened") || BAD_LOG_LINES=""
  fi
  if [[ "${LOG_READ:-0}" != 1 ]]; then
    :
  elif [[ -n "${BAD_LOG_LINES}" ]]; then
    fail "daemon emitted secrets-broker failure signatures for tenant=${SMOKE_SLUG}:"
    printf '    %s\n' "${BAD_LOG_LINES}" | head -5
    printf "  → see tenant-operator#189 (operator gaps) and gibson#262 (daemon gaps).\n"
  else
    pass "daemon emitted no secrets-broker failure signatures for tenant=${SMOKE_SLUG}"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "Step 8: First mission — #802 story 17 (deploy#1398)"
# ─────────────────────────────────────────────────────────────────────────────
# The story-17 criterion is signup → FIRST MISSION run to a terminal state.
# The mission RPCs themselves are not callable from here yet (see the two
# blockers named at the bottom of this step), but the credential chain they
# ride on IS testable, and until now nothing tested it. This step asserts
# that chain end-to-end against the environment under test:
#
#   8a. api.<domain> enforces authentication — an unauthenticated gRPC call
#       is rejected by Envoy's jwt_authn filter, not served.
#   8b. a platform service credential taken from THIS cluster mints a token
#       that the SAME edge accepts — proving Zitadel issues a correctly-
#       audienced JWT, the JWKS the edge validates against matches it, and
#       the request reaches ext-authz's FGA decision.
#
# Both are hard failures. Together they are the difference between "the
# mission call is blocked on a known gap" and "we have no idea whether a
# mission call could authenticate at all", which is what the previous bare
# warning left unanswered.
#
# The probes use plain curl against the public edge: a gRPC response carries
# its status in the `grpc-status` trailer/header even when the HTTP status is
# 200, so no proto descriptor is needed. grpc-status 16 = UNAUTHENTICATED
# (Envoy rejected the token), 7 = PERMISSION_DENIED (token accepted; ext-authz
# made an authz decision).
MISSION_RESULT="NOT RUN"
MISSION_RPC="${API_URL%/}/gibson.daemon.v1.DaemonService/ListMissions"

# grpc_status [bearer token]: sets GRPC_STATUS to the grpc-status value of
# the mission RPC, or "" when the answer has none, and GRPC_ERR to the curl
# error when the request failed.
grpc_status() {
  # An UNAUTHENTICATED probe may run on -k: it sends nothing worth stealing and
  # the edge is often self-signed. A call carrying a credential may not: with
  # a token, the edge CA is pinned, and the call is refused without it.
  #
  # The token never goes on the curl command line, where every local user
  # can read it (ps, /proc). printf is a shell builtin, so the header reaches
  # curl through a pipe (drill sweep row 28).
  local hdrs=""
  GRPC_STATUS=""
  GRPC_ERR=""
  if [[ -z "${1:-}" ]]; then
    capture hdrs curl -sS -k -D - -o /dev/null --max-time 20 -X POST --http2 \
      -H 'content-type: application/grpc' "${MISSION_RPC}" || GRPC_ERR="${PROBE_ERR}"
  else
    if [[ ! -s "${EDGE_CA:-}" ]]; then
      fail "refusing to send a bearer token over an unverified connection: the edge CA is not available"
      GRPC_ERR="no edge CA"
      return 0
    fi
    capture hdrs curl -sS --cacert "$EDGE_CA" -D - -o /dev/null --max-time 20 -X POST --http2 \
      -H 'content-type: application/grpc' -H @<(printf 'authorization: Bearer %s\n' "$1") \
      "${MISSION_RPC}" || GRPC_ERR="${PROBE_ERR}"
  fi
  GRPC_STATUS="$(printf '%s' "$hdrs" | tr -d '\r' | sed -n 's/^grpc-status: *//Ip' | head -1)"
}

if ! command -v curl >/dev/null 2>&1; then
  fail "curl not on PATH — the first-mission auth-chain assertions cannot run"
else
  # --- 8a: the edge rejects an unauthenticated mission call ---------------
  grpc_status
  UNAUTH_STATUS="${GRPC_STATUS}"
  printf "  unauthenticated %s → grpc-status=%s\n" "${MISSION_RPC}" "${UNAUTH_STATUS:-<none>}"
  if [[ "${UNAUTH_STATUS}" == "16" ]]; then
    pass "api edge rejects an unauthenticated mission RPC (grpc-status 16, jwt_authn enforcing)"
  elif [[ -z "${UNAUTH_STATUS}" ]]; then
    fail "no grpc-status from ${MISSION_RPC}: the api edge did not answer as a gRPC endpoint. ${GRPC_ERR:-The answer had no grpc-status header.} Everything below is unevaluated."
  else
    fail "unauthenticated mission RPC returned grpc-status=${UNAUTH_STATUS}, want 16 (UNAUTHENTICATED). The edge is NOT enforcing authentication on DaemonService."
  fi

  # --- 8b: a cluster-derived service credential is accepted by that edge --
  # Credential and issuer both come from the cluster under test — no literal
  # host, no pasted secret. gibson-zitadel-tenant-operator is a MACHINE_USER
  # OIDCClient the chart already provisions; the URN scope is what makes
  # Zitadel stamp aud=gibson-platform, which is the audience Envoy's
  # zitadel_s2s provider validates.
  SA_SECRET="${SMOKE_SA_SECRET:-gibson-zitadel-tenant-operator}"
  SA_CLIENT_ID=""
  SA_CLIENT_SECRET=""
  SA_ERR=""
  secret_data SA_CLIENT_ID "${SA_SECRET}" ZITADEL_CLIENT_ID || SA_ERR="${PROBE_ERR}"
  [[ -n "${SA_ERR}" ]] || secret_data SA_CLIENT_SECRET "${SA_SECRET}" ZITADEL_CLIENT_SECRET || SA_ERR="${PROBE_ERR}"
  SA_ISSUER=""
  if ! capture SA_ISSUER kubectl -n "${NAMESPACE}" get cm gibson-domains -o 'jsonpath={.data.oidcIssuer}'; then
    not_found || fail "cannot read oidcIssuer from the gibson-domains ConfigMap: ${PROBE_ERR}"
  fi
  SA_ISSUER="${SA_ISSUER:-${CLUSTER_URL}}"

  if [[ -n "${SA_ERR}" ]]; then
    fail "cannot read the platform service credential from the Secret ${SA_SECRET}: ${SA_ERR}"
  elif [[ -z "${SA_CLIENT_ID}" || -z "${SA_CLIENT_SECRET}" ]]; then
    fail "Secret ${SA_SECRET} has no ZITADEL_CLIENT_ID/ZITADEL_CLIENT_SECRET — the platform's own service credential is missing, so no caller can authenticate to the daemon edge"
  else
    # THE EDGE CA IS PINNED FOR THIS CALL. The other probes here read status
    # and may stay on -k; this one POSTs the platform's own client secret, and
    # -k means any party that can answer for the issuer host receives it. If
    # the CA cannot be read the call is NOT made: falling back to -k would put
    # the secret on the wire to prove a point.
    EDGE_CA="$(mktemp)"
    _ca=""
    _ca_err=""
    secret_data _ca gibson-envoy-tls 'ca\.crt' || _ca_err="${PROBE_ERR}"
    if [[ -z "${_ca}" && -z "${_ca_err}" ]]; then
      secret_data _ca gibson-envoy-tls 'tls\.crt' || _ca_err="${PROBE_ERR}"
    fi
    [[ -z "${_ca}" ]] || printf '%s\n' "${_ca}" > "$EDGE_CA"
    _ca=""
    if [[ ! -s "$EDGE_CA" ]]; then
      fail "cannot read the edge CA from Secret gibson-envoy-tls in ns/${NAMESPACE}: ${_ca_err:-it has no ca.crt and no tls.crt}. Refusing to POST the platform client secret over an unverified connection."
    fi
    SA_TOKEN=""
    SA_RESP=""
    if ! capture SA_RESP client_credentials_token "${SA_ISSUER%/}/oauth/v2/token" "${SA_CLIENT_ID}" "${SA_CLIENT_SECRET}"; then
      fail "the token request to ${SA_ISSUER} failed: ${PROBE_ERR}"
    else
      SA_TOKEN=$(printf '%s' "${SA_RESP}" \
        | node -p "try { JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')).access_token || ''; } catch(e) { ''; }")
      # Zitadel names a refusal in error and error_description. Neither holds
      # a credential, so the smoke prints them.
      SA_REFUSAL=$(printf '%s' "${SA_RESP}" \
        | node -p "try { const j = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8')); [j.error, j.error_description].filter(Boolean).join(': '); } catch(e) { 'a non-JSON answer'; }")
    fi
    SA_RESP=""
    # The CA file stays until EXIT (the trap removes it). #113 removed it
    # here, and the authenticated mission call below then refused to send
    # the bearer token: "the edge CA is not available", on every estate.
    if [[ -z "${SA_TOKEN}" ]]; then
      fail "Zitadel refused a client_credentials grant for ${SA_SECRET} at ${SA_ISSUER} (${SA_REFUSAL:-no answer}): no service caller can obtain a daemon-edge token on this cluster"
    else
      pass "Zitadel issued a client_credentials token for ${SA_SECRET}"
      grpc_status "${SA_TOKEN}"
      AUTH_STATUS="${GRPC_STATUS}"
      printf "  authenticated %s → grpc-status=%s\n" "${MISSION_RPC}" "${AUTH_STATUS:-<none>}"
      if [[ "${AUTH_STATUS}" == "16" ]]; then
        fail "the api edge REJECTED a token this cluster's own Zitadel just issued (grpc-status 16). jwt_authn's issuer/audience/JWKS disagree with the token — every service call to the daemon, mission RPCs included, is broken."
      elif [[ -z "${AUTH_STATUS}" ]]; then
        fail "no grpc-status from the authenticated mission RPC: the edge stopped answering between 8a and 8b. ${GRPC_ERR}"
      else
        pass "api edge accepted the cluster's service token (grpc-status ${AUTH_STATUS}; request reached ext-authz's authz decision)"
        MISSION_RESULT="AUTH CHAIN VERIFIED; mission NOT executed (see below)"
      fi
    fi
  fi
fi

# --- what is still NOT proven, and why ------------------------------------
# The criterion is not met until a mission actually runs. Two upstream gaps
# block the call itself; both were verified against staging on 2026-08-15:
#
#   1. No callable descriptor. gRPC server reflection is denied at the edge
#      (ext-authz has no registry entry for ServerReflectionInfo), and the
#      daemon protos are daemon-local with no published BSR module, so
#      grpcurl has no way to encode a CreateTarget/RunMission body from this
#      repo. Only descriptor-free probes — the ones above — are possible.
#   2. Service tokens are classed as OIDC users. ext-authz derives
#      credential_type from `client_id == sub`, but Zitadel sets client_id to
#      the machine user's NAME and sub to its numeric id, so a
#      client_credentials token is treated as `oidc-user`. Any tenant-scoped
#      RPC then hits the deny-on-absent active_session gate, which no
#      scripted caller can satisfy.
#
# This step therefore never prints a green "first mission passed". Set
# REQUIRE_MISSION=1 to turn the outstanding gap into a hard failure.
if [[ "${REQUIRE_MISSION:-0}" == "1" ]]; then
  fail "first mission NOT run — REQUIRE_MISSION=1 set but the mission RPCs are not callable (deploy#1398)"
  MISSION_RESULT="FAILED (REQUIRE_MISSION=1)"
else
  warn "first mission NOT executed — the mission RPCs remain uncallable (no edge reflection / no published descriptor; service tokens misclassified as oidc-user). The auth chain they need is asserted above. See deploy#1398."
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "Summary"
# ─────────────────────────────────────────────────────────────────────────────
printf "  Failed assertions: %d\n" "${FAILED}"
printf "  First mission: %s\n" "${MISSION_RESULT}"
printf "  Tenant slug: %s\n" "${SMOKE_SLUG}"
if [[ "${FAILED}" -gt 0 ]]; then
  printf "${RED}smoke-signup: %d assertion(s) failed — cluster is NOT shippable${NC}\n" "${FAILED}" >&2
  exit 1
fi
pass "smoke-signup: all assertions passed — cluster is shippable"
exit 0
