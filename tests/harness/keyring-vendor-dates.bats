#!/usr/bin/env bats
# keyring-vendor-dates.bats — keyring.sh records when each vendor value was
# set (ADR-0171, row vendor-issued-inputs), and the record is not a member.

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  K="$BATS_TEST_TMPDIR/keyring.env"
  "$ROOT/scripts/keyring.sh" generate "$K" >/dev/null
}

@test "set records the time of a vendor value" {
  before="$(date +%s)"
  "$ROOT/scripts/keyring.sh" set "$K" STRIPE_WEBHOOK_SECRET whsec_example >/dev/null
  at="$(grep -E '^KEYRING_SET_AT_STRIPE_WEBHOOK_SECRET=' "$K" | cut -d= -f2)"
  [ -n "$at" ] && [ "$at" -ge "$before" ]
}

@test "a second set replaces the time, and clearing the value clears it" {
  "$ROOT/scripts/keyring.sh" set "$K" GHCR_PULL_TOKEN ghp_one >/dev/null
  "$ROOT/scripts/keyring.sh" set "$K" GHCR_PULL_TOKEN ghp_two >/dev/null
  [ "$(grep -c '^KEYRING_SET_AT_GHCR_PULL_TOKEN=' "$K")" -eq 1 ]
  [ "$(grep -c '^KEYRING_SET_FP_GHCR_PULL_TOKEN=' "$K")" -eq 1 ]
  "$ROOT/scripts/keyring.sh" set "$K" GHCR_PULL_TOKEN "" >/dev/null
  [ "$(grep -c '^KEYRING_SET_AT_GHCR_PULL_TOKEN=' "$K" || true)" -eq 0 ]
  [ "$(grep -c '^KEYRING_SET_FP_GHCR_PULL_TOKEN=' "$K" || true)" -eq 0 ]
}

@test "a set time changes no fingerprint" {
  before="$("$ROOT/scripts/keyring.sh" fingerprints "$K")"
  printf 'KEYRING_SET_AT_STRIPE_SECRET_KEY=1\nKEYRING_SET_FP_STRIPE_SECRET_KEY=0123456789abcdef\n' >> "$K"
  [ "$("$ROOT/scripts/keyring.sh" fingerprints "$K")" = "$before" ]
}

@test "a member that no vendor issues gets no set time" {
  "$ROOT/scripts/keyring.sh" set "$K" DNS_ACCESS_KEY AKIAEXAMPLE >/dev/null
  run grep -q '^KEYRING_SET_AT_DNS_ACCESS_KEY=' "$K"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: a set of the value already set is refused, and its set time stays" {
  "$ROOT/scripts/keyring.sh" set "$K" STRIPE_SECRET_KEY sk_live_example >/dev/null
  sed -i 's/^KEYRING_SET_AT_STRIPE_SECRET_KEY=.*/KEYRING_SET_AT_STRIPE_SECRET_KEY=1000/' "$K"
  run "$ROOT/scripts/keyring.sh" set "$K" STRIPE_SECRET_KEY sk_live_example
  [ "$status" -eq 2 ]
  [[ "$output" == *"already holds this value"* ]]
  grep -q '^KEYRING_SET_AT_STRIPE_SECRET_KEY=1000$' "$K"
  "$ROOT/scripts/keyring.sh" set "$K" STRIPE_SECRET_KEY sk_live_other >/dev/null
  run grep -q '^KEYRING_SET_AT_STRIPE_SECRET_KEY=1000$' "$K"
  [ "$status" -ne 0 ]
}
