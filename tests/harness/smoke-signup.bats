#!/usr/bin/env bats
#
# smoke-signup.bats — the bringup smoke signs up with the one signup driver,
# with the target inputs of the env, and never pays on a live Stripe key
# (hosted#647).
#
# Offline: kubectl and node are stubs. node records how the smoke called the
# driver; the run then stops on the next step, which this suite does not test.
#
# Run:
#   bats tests/harness/smoke-signup.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SMOKE="$REPO_ROOT/scripts/smoke-signup.sh"

setup() {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  DRIVER="$BATS_TEST_TMPDIR/driver"; mkdir -p "$DRIVER/node_modules/playwright"
  export STRIPE_KEY="${STRIPE_KEY-sk_test_abcdefgh}" CALLS="$BATS_TEST_TMPDIR/node.calls"
  cat > "$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  # The real Secret of the billing component (gibson-billing-stripe). Any
  # other Secret name answers nothing, the way a cluster does.
  *"get secret gibson-billing-stripe -o jsonpath={.data.STRIPE_SECRET_KEY}"*) printf '%s' "$(printf '%s' "$STRIPE_KEY" | base64)"; exit 0 ;;
  *"get secret "*) echo "Error from server (NotFound)" >&2; exit 1 ;;
  *"get pods --no-headers"*) echo "x 1/1 Running"; exit 0 ;;
  *"jsonpath={.items[0].status.phase}"*) printf Running; exit 0 ;;
  # The suite stops after the driver; every later read is undeclared, and an
  # undeclared read fails, as on a cluster that has no such object (hosted#654).
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  cat > "$BIN/node" <<'SH'
#!/usr/bin/env bash
echo "node $* MAIL_SOURCE=$MAIL_SOURCE INBOX_BUCKET=$INBOX_BUCKET SIGNUP_PROFILE=$SIGNUP_PROFILE SIGNUP_PLAN=$SIGNUP_PLAN SIGNUP_EMAIL=$SIGNUP_EMAIL" >> "$CALLS"
exit 0
SH
  chmod +x "$BIN/kubectl" "$BIN/node"
  export PATH="$BIN:$PATH"
}

smoke() {
  env CLUSTER_URL=https://app.drill.example.test API_URL=https://api.drill.example.test \
    CURL_RESOLVE=app.drill.example.test:443:127.0.0.1 KEEP_TENANT=1 TIMEOUT_TENANT=1 \
    SIGNUP_DRIVER_DIR="$DRIVER" "$@" timeout 60 bash "$SMOKE"
}

@test "the SaaS smoke signs up with the one driver, the s3 mail source and an address of the env inbox" {
  run smoke SIGNUP_PROFILE=saas MAIL_SOURCE=s3 INBOX_BUCKET=bkt INBOX_DOMAIN=inbox.drill.example.test
  grep -q -- '--drill MAIL_SOURCE=s3 INBOX_BUCKET=bkt SIGNUP_PROFILE=saas SIGNUP_PLAN=team SIGNUP_EMAIL=smoke-[^@]*-[0-9a-f]\{24\}@inbox.drill.example.test' "$CALLS" \
    || { echo "$output"; cat "$CALLS"; false; }
  [[ "$output" == *"the Stripe key of the env is a test key"* ]]
}

@test "FAILING FIXTURE: a live Stripe key stops the smoke before the driver runs" {
  STRIPE_KEY=sk_live_abcdefgh run smoke SIGNUP_PROFILE=saas MAIL_SOURCE=s3 INBOX_BUCKET=bkt INBOX_DOMAIN=inbox.drill.example.test
  [ "$status" -ne 0 ]
  [[ "$output" == *"is a LIVE key"* ]]
  [ ! -s "$CALLS" ]
}

@test "FAILING FIXTURE: a restricted live key stops the smoke too" {
  STRIPE_KEY=rk_live_abcdefgh run smoke SIGNUP_PROFILE=saas MAIL_SOURCE=s3 INBOX_BUCKET=bkt INBOX_DOMAIN=inbox.drill.example.test
  [ "$status" -ne 0 ]
  [ ! -s "$CALLS" ]
}

@test "FAILING FIXTURE: no profile, an unknown mail source, or s3 with no bucket stops the smoke" {
  run smoke MAIL_SOURCE=s3 INBOX_BUCKET=bkt INBOX_DOMAIN=d
  [ "$status" -ne 0 ]; [[ "$output" == *"SIGNUP_PROFILE must be baseline or saas"* ]]
  run smoke SIGNUP_PROFILE=saas MAIL_SOURCE=imap
  [ "$status" -ne 0 ]; [[ "$output" == *"MAIL_SOURCE must be mailpit or s3"* ]]
  run smoke SIGNUP_PROFILE=saas MAIL_SOURCE=s3 INBOX_DOMAIN=d
  [ "$status" -ne 0 ]; [[ "$output" == *"needs INBOX_BUCKET and INBOX_DOMAIN"* ]]
  [ ! -s "$CALLS" ]
}

@test "FAILING FIXTURE: no hosted file reads the signup-bot token the platform no longer has" {
  run git -C "$REPO_ROOT" grep -n -w -e 'gibson-zitadel-signup-bot-pat' -e 'SIGNUP_BOT_PAT' -- . ':!vendor/charts/*' ':!tests/harness/smoke-signup.bats'
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: the chart placeholder in the billing Secret names the keyring member to set" {
  STRIPE_KEY=sk_test_placeholder run smoke SIGNUP_PROFILE=saas MAIL_SOURCE=s3 INBOX_BUCKET=bkt INBOX_DOMAIN=inbox.drill.example.test
  [ "$status" -ne 0 ]
  [[ "$output" == *"holds the chart's placeholder: the keyring member STRIPE_SECRET_KEY is not set"* ]]
  [ ! -s "$CALLS" ]
}

@test "FAILING FIXTURE: an empty billing Secret key names the keyring member to set" {
  STRIPE_KEY= run smoke SIGNUP_PROFILE=saas MAIL_SOURCE=s3 INBOX_BUCKET=bkt INBOX_DOMAIN=inbox.drill.example.test
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no STRIPE_SECRET_KEY. Set the keyring member STRIPE_SECRET_KEY"* ]]
  [ ! -s "$CALLS" ]
}
