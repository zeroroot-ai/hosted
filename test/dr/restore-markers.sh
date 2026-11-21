#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restore-markers.sh — write a known record into each store that a backup
# covers, and read each one back after a restore (hosted#443).
#
#   test/dr/restore-markers.sh seed  <state-file>
#   test/dr/restore-markers.sh check <state-file>
#
# The drill workflow runs it through `make with-cluster ENV=drill CMD=...`, so
# it speaks kubectl to the current cluster and nothing else. `seed` writes the
# ciphertext of the secret store record into <state-file> (mode 0600). `check`
# reads it from there. The records and their checks are
# test/dr/lib/restore-markers.sh, the same code the blocker 3 loop runs.
#
# Exit 0: each record is present and the same. Exit 1: a record is absent or
# different. Exit 2: a usage error.
# ---------------------------------------------------------------------------
set -euo pipefail

MODE="${1:-}"
STATE="${2:-}"
case "$MODE" in seed|check) ;; *) echo "usage: restore-markers.sh seed|check <state-file>" >&2; exit 2 ;; esac
[ -n "$STATE" ] || { echo "usage: restore-markers.sh seed|check <state-file>" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-gibson}"
TENANT="${TENANT:-restoredrill}"
# shellcheck disable=SC2034  # read by lib/restore-markers.sh
TIER="team"
# shellcheck disable=SC2034
TENANT_NS="tenant-${TENANT}"
# shellcheck disable=SC2034
PLAINTEXT="the tenant key must survive the teardown"
# shellcheck disable=SC2034
GRAPH_MARKER="restore drill record, written before the preserve teardown"
READY_TIMEOUT="${READY_TIMEOUT:-1800}"

note() { printf '     %s\n' "$*"; }
die()  { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck source=lib/restore-markers.sh
. "$HERE/lib/restore-markers.sh"

case "$MODE" in
  seed)
    markers_seed
    ( umask 077; printf 'KEK_MAC=%s\n' "$KEK_MAC" > "$STATE" )
    note "each record is written, and the state is in ${STATE}"
    ;;
  check)
    [ -s "$STATE" ] || die "no state file at ${STATE}. The seed step did not run, so there is nothing to check"
    KEK_MAC="$(sed -n 's/^KEK_MAC=//p' "$STATE")"
    [ -n "$KEK_MAC" ] || die "${STATE} holds no KEK_MAC"
    markers_check
    note "each record that the seed wrote before the backup is back"
    ;;
esac
