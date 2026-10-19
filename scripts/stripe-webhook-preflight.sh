#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# stripe-webhook-preflight.sh — verify a Stripe account is ready for bringup,
# and own the webhook endpoint <-> signing-secret pair (gitops#383 /
# deploy#1158 / deploy#896). Run before `make eks-bringup ENV=<env>`.
#
# ENV-DRIVEN, BOTH MODES (deploy#896). This was `stripe-live-preflight.sh` and
# refused to run against a test key, so PROD had a mechanism that created the
# endpoint and captured its secret in one step while STAGING had none. The
# only staging procedure was a human copying a `whsec_` out of the Stripe
# dashboard into AWS Secrets Manager — two hand-maintained artefacts with
# nothing keeping them equal. They drifted, and every staging webhook failed
# signature verification for two months (deploy#896). A tool that covers the
# environment nobody is watching is the point; prod was never the risky half.
#
# Asserts, against the key in $STRIPE_KEY_FILE:
#   1. the key's mode matches ENV (staging -> sk_test_, prod -> sk_live_);
#   2. it belongs to the account that gitops/envs/<env>/stripe-account.yaml
#      names: the sandbox account for staging and drill, the main account
#      for prod;
#   3. every plan lookupKey in the chart's gibson-workloads/files/plans.yaml has an
#      ACTIVE price in that mode (the dashboard resolves prices at runtime by
#      lookup_key — a missing one silently degrades pricing);
#   4. a webhook endpoint exists for $WEBHOOK_URL. If absent, it is CREATED
#      with the event set the receiver consumes, and the returned signing
#      secret is written to $STRIPE_WEBHOOK_FILE — creation is the ONLY
#      moment Stripe reveals it. If present, the secret cannot be read back
#      via the API, so the script verifies the local whsec file exists and
#      warns that only a real delivery proves the pair matches. An existing
#      endpoint whose event set differs is updated in place. ROLL=1
#      deletes + recreates the endpoint and writes the fresh secret.
#
# The captured secret is then seeded by eks/gibson/scripts/seed-secrets.sh
# into gibson/<env>/gibson-stripe-credentials -> webhook_secret, which is the
# property the chart's stripe-credentials ExternalSecret reads. See
# eks/gibson/runbooks/RUNBOOK-secret-seed.md.
#
# Never prints a secret. Requires: curl, jq, python3.
#
# Usage:
#   ENV=staging scripts/stripe-webhook-preflight.sh          # verify (creates endpoint if absent)
#   ENV=prod ROLL=1 scripts/stripe-webhook-preflight.sh      # force-recreate the endpoint
# ----------------------------------------------------------------------------
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# plans.yaml is chart source, and this repo holds none (ADR-0086). CHARTS_ROOT
# is a checkout of zeroroot-ai/charts, a sibling by default, the same value the
# Makefile exports. The old default pointed inside this repo, so the documented
# invocation read a path that cannot exist and the lookupKey check had nothing
# to compare against (hosted#363).
readonly CHARTS_ROOT="${CHARTS_ROOT:-${SCRIPT_DIR}/../../charts}"
readonly PLANS_FILE="${PLANS_FILE:-${CHARTS_ROOT}/helm/gibson-workloads/files/plans.yaml}"
readonly STRIPE_KEY_FILE="${STRIPE_KEY_FILE:-$HOME/.stripe.tok}"
readonly STRIPE_WEBHOOK_FILE="${STRIPE_WEBHOOK_FILE:-$HOME/.stripe-webhook.tok}"
# The event set the billing receiver consumes. Ground truth is two switches
# in zeroroot-ai/billing:
#   - internal/webhook/sync.go subscriptionEvent(): the five subscription
#     events, which keep the tenant's entitlements in step with Stripe;
#   - internal/webhook/step.go stepEvent(): the three Checkout events, which
#     complete or fail the signup card step. Without them the signup page
#     waits on "We are confirming your payment details" until it times out
#     (staging run 38462291747).
# `invoice.paid` was listed here until deploy#896 and is NOT handled: the
# receiver returns 200 and drops it, so subscribing to it only adds
# deliveries that do nothing.
readonly WEBHOOK_EVENTS=(
  checkout.session.async_payment_failed
  checkout.session.completed
  checkout.session.expired
  customer.subscription.created
  customer.subscription.deleted
  customer.subscription.paused
  customer.subscription.resumed
  customer.subscription.updated
)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '  ok: %s\n' "$*"; }

# --- 0. environment ---------------------------------------------------------
# The endpoint URL is derived from ENV rather than defaulted, so a missing ENV
# cannot quietly point a staging run at the prod endpoint. Envoy serves this
# exact path and rewrites it onto the receiver's POST /webhook (see
# helm/gibson-workloads/files/envoy/envoy.yaml).
ENV_NAME="${ENV:-}"
case "${ENV_NAME}" in
  staging) WANT_MODE="test"; DEFAULT_URL="https://app.staging.zeroroot.ai/api/billing/webhook" ;;
  drill)   WANT_MODE="test"; DEFAULT_URL="https://app.drill.zeroroot.ai/api/billing/webhook" ;;
  prod)    WANT_MODE="live"; DEFAULT_URL="https://app.zeroroot.ai/api/billing/webhook" ;;
  "")      fail "ENV is unset — export ENV=staging or ENV=prod (no default: a wrong guess writes the wrong endpoint)" ;;
  *)       fail "ENV must be 'staging', 'drill' or 'prod' (got '${ENV_NAME}')" ;;
esac
readonly WEBHOOK_URL="${WEBHOOK_URL:-${DEFAULT_URL}}"

# The Stripe account of the env comes from its overlay, with no override. The
# staging and drill keys belong to a Stripe sandbox, which is an account of its
# own, so one account id for every env refused the staging key.
readonly ACCOUNT_FILE="${SCRIPT_DIR}/../gitops/envs/${ENV_NAME}/stripe-account.yaml"
[[ -r "${ACCOUNT_FILE}" ]] || fail "cannot read ${ACCOUNT_FILE}: each env names its Stripe account there"
EXPECTED_STRIPE_ACCOUNT="$(python3 -c 'import sys, yaml; print((yaml.safe_load(open(sys.argv[1])) or {}).get("expectedAccount", ""))' "${ACCOUNT_FILE}")"
[[ "${EXPECTED_STRIPE_ACCOUNT}" =~ ^acct_[A-Za-z0-9]+$ ]] || fail "${ACCOUNT_FILE} names no expectedAccount of the form acct_..."
readonly EXPECTED_STRIPE_ACCOUNT
ok "env=${ENV_NAME} mode=${WANT_MODE} url=${WEBHOOK_URL}"

for c in curl jq python3; do command -v "$c" >/dev/null || fail "$c not in PATH"; done
[[ -f "${STRIPE_KEY_FILE}" ]] || fail "${STRIPE_KEY_FILE} not found — put the ${WANT_MODE} secret key there (Stripe dashboard > Developers > API keys)"
SK="$(tr -d '\n\r' < "${STRIPE_KEY_FILE}")"
case "${SK}" in
  sk_live_*) SK_MODE="live" ;;
  sk_test_*) SK_MODE="test" ;;
  *)         fail "${STRIPE_KEY_FILE} does not hold a Stripe secret key (sk_*)" ;;
esac
[[ "${SK_MODE}" == "${WANT_MODE}" ]] \
  || fail "ENV=${ENV_NAME} needs a ${WANT_MODE}-mode key but ${STRIPE_KEY_FILE} holds an sk_${SK_MODE}_ key — refusing (this is the same mode guard seed-secrets.sh and the chart boot guards apply)"
ok "key file holds a ${SK_MODE} secret key, matching ENV=${ENV_NAME}"

api() { # method path [curl args...]
  local method="$1" path="$2"; shift 2
  # The key goes in a header through a pipe, never on the curl command line
  # (drill sweep row 28). Stripe accepts the key as a bearer token.
  curl -sS -X "${method}" "https://api.stripe.com/v1${path}" \
    -H @<(printf 'authorization: Bearer %s\n' "${SK}") "$@"
}

# --- 1. account -------------------------------------------------------------
acct_json="$(api GET /account)"
acct_id="$(jq -r '.id // empty' <<<"${acct_json}")"
[[ -n "${acct_id}" ]] || fail "could not read /v1/account: $(jq -r '.error.message // "unknown error"' <<<"${acct_json}")"
[[ "${acct_id}" == "${EXPECTED_STRIPE_ACCOUNT}" ]] \
  || fail "key belongs to ${acct_id}, but ${ACCOUNT_FILE} names ${EXPECTED_STRIPE_ACCOUNT} (the key of another account?)"
ok "account ${acct_id} matches expected"

# --- 2. plan lookup_keys ----------------------------------------------------
# A missing plans.yaml must name what to set. Without this the mapfile below
# yields nothing and the failure reads as "no lookupKey entries", which sends
# the reader to the plan list rather than to the chart checkout (hosted#363).
[[ -r "${PLANS_FILE}" ]] || fail "cannot read ${PLANS_FILE}. plans.yaml is chart source and this repo holds none (ADR-0086): clone zeroroot-ai/charts beside this repo, or set CHARTS_ROOT=<checkout>, or PLANS_FILE=<file>."

mapfile -t LOOKUP_KEYS < <(python3 - "${PLANS_FILE}" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
plans = doc.get("plans") if isinstance(doc, dict) else doc
for p in plans or []:
    lk = p.get("lookupKey")
    if lk:
        print(lk)
PY
)
[[ ${#LOOKUP_KEYS[@]} -gt 0 ]] || fail "no lookupKey entries parsed from ${PLANS_FILE}"

query=""
for k in "${LOOKUP_KEYS[@]}"; do query="${query}&lookup_keys[]=${k}"; done
prices_json="$(api GET "/prices?active=true&limit=100${query}")"
jq -e '.data' >/dev/null <<<"${prices_json}" \
  || fail "could not list prices: $(jq -r '.error.message // "unknown error"' <<<"${prices_json}")"
missing=0
for k in "${LOOKUP_KEYS[@]}"; do
  if jq -e --arg k "$k" '.data[] | select(.lookup_key == $k)' >/dev/null <<<"${prices_json}"; then
    ok "active ${WANT_MODE} price for lookup_key ${k}"
  else
    printf 'FAIL: no ACTIVE %s price with lookup_key %s\n' "${WANT_MODE}" "$k" >&2
    missing=1
  fi
done
[[ ${missing} -eq 0 ]] || fail "create the missing ${WANT_MODE} prices (same lookup_keys across modes, gitops#282) and re-run"

# --- 3. webhook endpoint ----------------------------------------------------
eps_json="$(api GET "/webhook_endpoints?limit=100")"
ep_id="$(jq -r --arg u "${WEBHOOK_URL}" '.data[] | select(.url == $u and .status == "enabled") | .id' <<<"${eps_json}" | head -1)"

create_endpoint() {
  local args=(-d "url=${WEBHOOK_URL}" -d "description=gibson ${ENV_NAME} billing webhook (stripe-webhook-preflight)")
  local ev
  for ev in "${WEBHOOK_EVENTS[@]}"; do args+=(-d "enabled_events[]=${ev}"); done
  local created secret new_id
  created="$(api POST /webhook_endpoints "${args[@]}")"
  new_id="$(jq -r '.id // empty' <<<"${created}")"
  [[ -n "${new_id}" ]] || fail "endpoint create failed: $(jq -r '.error.message // "unknown error"' <<<"${created}")"
  secret="$(jq -r '.secret' <<<"${created}")"
  umask 077
  if [[ -f "${STRIPE_WEBHOOK_FILE}" ]]; then
    cp "${STRIPE_WEBHOOK_FILE}" "${STRIPE_WEBHOOK_FILE}.bak-$(date +%Y%m%d%H%M%S)"
  fi
  printf '%s' "${secret}" > "${STRIPE_WEBHOOK_FILE}"
  ok "created ${WANT_MODE} endpoint ${new_id} for ${WEBHOOK_URL}; signing secret written to ${STRIPE_WEBHOOK_FILE}"
}

if [[ -z "${ep_id}" ]]; then
  create_endpoint
elif [[ "${ROLL:-0}" == "1" ]]; then
  api DELETE "/webhook_endpoints/${ep_id}" >/dev/null
  ok "deleted existing endpoint ${ep_id} (ROLL=1)"
  create_endpoint
else
  ok "${WANT_MODE} endpoint ${ep_id} already exists for ${WEBHOOK_URL}"
  ep_events="$(jq -r --arg id "${ep_id}" '.data[] | select(.id == $id) | .enabled_events | sort | join(",")' <<<"${eps_json}")"
  want="$(printf '%s\n' "${WEBHOOK_EVENTS[@]}" | sort | paste -sd, -)"
  if [[ "${ep_events}" != "${want}" && "${ep_events}" != "*" ]]; then
    # An event the endpoint does not subscribe to never reaches the receiver,
    # so a drift is a defect, not a note. Stripe updates the event set in
    # place and keeps the signing secret, so the keyring stays valid.
    upd_args=()
    for ev in "${WEBHOOK_EVENTS[@]}"; do upd_args+=(-d "enabled_events[]=${ev}"); done
    updated="$(api POST "/webhook_endpoints/${ep_id}" "${upd_args[@]}")"
    got="$(jq -r '.enabled_events // [] | sort | join(",")' <<<"${updated}")"
    [[ "${got}" == "${want}" ]] \
      || fail "could not update the events of endpoint ${ep_id}: $(jq -r '.error.message // "the event set did not change"' <<<"${updated}")"
    ok "updated the events of endpoint ${ep_id} from (${ep_events}) to (${want})"
  else
    ok "endpoint ${ep_id} subscribes to the consumed set"
  fi
  if [[ -f "${STRIPE_WEBHOOK_FILE}" ]] && head -c 6 "${STRIPE_WEBHOOK_FILE}" | grep -q '^whsec_'; then
    printf '  warn: %s exists but the API cannot reveal an existing endpoint secret —\n' "${STRIPE_WEBHOOK_FILE}"
    printf '        only a real delivery (or `stripe trigger`) proves the pair matches (deploy#896).\n'
    printf '        ROLL=1 recreates the endpoint and writes a fresh, known-matching secret.\n'
  else
    fail "${STRIPE_WEBHOOK_FILE} missing or not a whsec_ — the endpoint exists so its secret is unrecoverable; run with ROLL=1 to recreate the endpoint and capture a fresh secret"
  fi
fi

echo ""
echo "stripe-webhook-preflight: PASS — account, prices and webhook endpoint are ready for ENV=${ENV_NAME}."
echo "Next: put the captured secret in the keyring (hosted#450), then bring up:"
echo "  scripts/keyring.sh set <keyring-file> STRIPE_WEBHOOK_SECRET \$(cat ${STRIPE_WEBHOOK_FILE})"
echo "  make substrate ENV=${ENV_NAME}"
echo "  make recreate ENV=${ENV_NAME}"
echo ""
echo "The mode is declared in the env values as dashboard.billing.stripeExpectedMode=${WANT_MODE},"
echo "and the dashboard refuses to boot if the key prefix disagrees with it. No"
echo "environment variable carries the mode into a bringup."
