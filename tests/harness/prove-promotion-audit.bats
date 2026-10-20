#!/usr/bin/env bats
#
# prove-promotion-audit.bats: the promotion proof runs the prune allowlist
# audit, so a stale entry fails a promotion (hosted#748, review of hosted#750).
#
# The self-test of gitops/scripts/prune-orphans.sh proves the audit verdict.
# This file proves the wiring: scripts/prove-promotion.sh calls the audit on
# the app document that check-promotion-landed.sh reads.
#
# Run:
#   bats tests/harness/prove-promotion-audit.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# audit_wired FILE: true when FILE runs the audit on the env and app document.
# A call that ends in `|| true` or `|| :` cannot fail the proof, so it does
# not count.
audit_wired() {
  local line
  line="$(grep -v '^\s*#' "$1" \
    | grep -E 'gitops/scripts/prune-orphans\.sh" audit "\$ENV_NAME" "/tmp/\$\{APP\}-app\.json"')" || return 1
  ! grep -qE '\|\| *(true|:)' <<<"$line" || { echo "a line that must not be there matched"; false; }
}

@test "prove-promotion.sh runs the prune allowlist audit" {
  audit_wired "$REPO_ROOT/scripts/prove-promotion.sh"
}

@test "FAILING FIXTURE: a proof without the audit call is refused, and a comment does not count" {
  tmp="$(mktemp)"
  grep -v 'prune-orphans.sh" audit' "$REPO_ROOT/scripts/prove-promotion.sh" > "$tmp"
  printf '# bash "$REPO/gitops/scripts/prune-orphans.sh" audit "$ENV_NAME" "/tmp/${APP}-app.json"\n' >> "$tmp"
  run audit_wired "$tmp"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: an audit call that cannot fail is refused" {
  tmp="$(mktemp)"
  sed 's|prune-orphans.sh" audit "$ENV_NAME" "/tmp/${APP}-app.json"|& \|\| true|' "$REPO_ROOT/scripts/prove-promotion.sh" > "$tmp"
  grep -q 'app.json" || true' "$tmp"
  run audit_wired "$tmp"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
}
