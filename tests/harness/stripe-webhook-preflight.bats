#!/usr/bin/env bats
#
# stripe-webhook-preflight.bats: the webhook endpoint subscribes to every
# event the billing receiver consumes, and the preflight updates an endpoint
# whose event set differs (staging run 38462291747: the endpoint had no
# Checkout events, so the signup card step never completed).
#
# Offline. curl is a stub. It records each call as "<method> <path> <events>"
# and answers from fixtures. STUB_ACCOUNT is the account of the key (by
# default the one gitops/envs/staging/stripe-account.yaml names). STUB_EVENTS is the event set of the existing
# endpoint, and STUB_UPDATE=fail makes the update return a Stripe error.
#
# Run:
#   bats tests/harness/stripe-webhook-preflight.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
load assert

# The set the billing receiver consumes (billing internal/webhook/step.go and
# sync.go), sorted.
CONSUMED="checkout.session.async_payment_failed,checkout.session.completed,checkout.session.expired,customer.subscription.created,customer.subscription.deleted,customer.subscription.paused,customer.subscription.resumed,customer.subscription.updated"

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  printf 'sk_test_fixture\n' > "$BATS_TEST_TMPDIR/key"
  printf 'whsec_fixture' > "$BATS_TEST_TMPDIR/whsec"
  printf 'plans:\n  - name: team\n    lookupKey: fixture_team\n' > "$BATS_TEST_TMPDIR/plans.yaml"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
method=GET url="" events=()
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) shift 2 ;;
    -d) case "$2" in enabled_events\[\]=*) events+=("${2#enabled_events[]=}") ;; esac; shift 2 ;;
    -sS) shift ;;
    https://api.stripe.com/v1*) url="${1#https://api.stripe.com/v1}"; shift ;;
    *) echo "curl stub: undeclared argument: $1" >&2; exit 2 ;;
  esac
done
joined="$(printf '%s\n' "${events[@]}" | sed '/^$/d' | sort | paste -sd, -)"
echo "$method ${url%%\?*} $joined" >> "$CALLS"
json_list() { printf '%s' "$1" | jq -R 'split(",")'; }
case "$method ${url%%\?*}" in
  "GET /account") echo "{\"id\":\"${STUB_ACCOUNT}\"}" ;;
  "GET /prices") echo '{"data":[{"lookup_key":"fixture_team"}]}' ;;
  "GET /webhook_endpoints")
    jq -n --argjson ev "$(json_list "$STUB_EVENTS")" \
      '{data:[{id:"we_fixture",url:"https://app.staging.zeroroot.ai/api/billing/webhook",status:"enabled",enabled_events:$ev}]}' ;;
  "POST /webhook_endpoints/we_fixture")
    if [ "${STUB_UPDATE:-}" = fail ]; then
      echo '{"error":{"message":"fixture refusal"}}'
    else
      jq -n --argjson ev "$(json_list "$joined")" '{id:"we_fixture",enabled_events:$ev}'
    fi ;;
  *) echo "curl stub: undeclared call: $method $url" >&2; exit 2 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  STUB_ACCOUNT="$(sed -n 's/^expectedAccount: //p' "$REPO_ROOT/gitops/envs/staging/stripe-account.yaml")"
  export STUB_ACCOUNT
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export ENV=staging STRIPE_KEY_FILE="$BATS_TEST_TMPDIR/key" STRIPE_WEBHOOK_FILE="$BATS_TEST_TMPDIR/whsec" \
    PLANS_FILE="$BATS_TEST_TMPDIR/plans.yaml"
}

@test "an endpoint without the Checkout events is updated to the consumed set" {
  export STUB_EVENTS="customer.subscription.created,customer.subscription.deleted,customer.subscription.paused,customer.subscription.resumed,customer.subscription.updated"
  run "$REPO_ROOT/scripts/stripe-webhook-preflight.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c "^POST /webhook_endpoints/we_fixture $CONSUMED\$" "$CALLS")" = 1 ] || { cat "$CALLS"; false; }
  assert_output_has "updated the events of endpoint we_fixture"
}

@test "an endpoint with the consumed set is left alone" {
  export STUB_EVENTS="$CONSUMED"
  run "$REPO_ROOT/scripts/stripe-webhook-preflight.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '^POST' "$CALLS")" = 0 ] || { cat "$CALLS"; false; }
  assert_output_has "subscribes to the consumed set"
}

@test "a refused update fails the preflight" {
  export STUB_EVENTS="customer.subscription.created" STUB_UPDATE=fail
  run "$REPO_ROOT/scripts/stripe-webhook-preflight.sh"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  assert_output_has "fixture refusal"
}

@test "a key of another Stripe account fails the preflight before any endpoint call" {
  export STUB_EVENTS="$CONSUMED" STUB_ACCOUNT="acct_fixtureOtherAccount"
  run "$REPO_ROOT/scripts/stripe-webhook-preflight.sh"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  assert_output_has "key belongs to acct_fixtureOtherAccount"
  [ "$(grep -c 'webhook_endpoints' "$CALLS")" = 0 ] || { cat "$CALLS"; false; }
}

@test "each env names its own Stripe account, and staging and drill share the sandbox" {
  for e in staging drill prod; do
    grep -qE '^expectedAccount: acct_[A-Za-z0-9]+$' "$REPO_ROOT/gitops/envs/$e/stripe-account.yaml" \
      || { echo "gitops/envs/$e/stripe-account.yaml names no account"; false; }
  done
  s="$(sed -n 's/^expectedAccount: //p' "$REPO_ROOT/gitops/envs/staging/stripe-account.yaml")"
  d="$(sed -n 's/^expectedAccount: //p' "$REPO_ROOT/gitops/envs/drill/stripe-account.yaml")"
  p="$(sed -n 's/^expectedAccount: //p' "$REPO_ROOT/gitops/envs/prod/stripe-account.yaml")"
  [ "$s" = "$d" ] || { echo "staging $s and drill $d differ"; false; }
  [ "$s" != "$p" ] || { echo "staging and prod name one account; the sandbox is its own account"; false; }
}

@test "an exported EXPECTED_STRIPE_ACCOUNT does not override the env file" {
  export STUB_EVENTS="$CONSUMED" STUB_ACCOUNT="acct_fixtureOtherAccount" EXPECTED_STRIPE_ACCOUNT="acct_fixtureOtherAccount"
  run "$REPO_ROOT/scripts/stripe-webhook-preflight.sh"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  assert_output_has "key belongs to acct_fixtureOtherAccount"
}
