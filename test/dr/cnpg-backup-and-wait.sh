#!/usr/bin/env bash
# Create one CNPG Backup and wait for `completed` (deploy#1735, deploy#1738).
#
# This is the Postgres half of the pre-backup coordination CONTEXT.md
# § Velero backup names: before a preserve teardown takes its Velero backup,
# the platform takes a fresh CNPG base backup and WAITS for it, and a timeout
# fails the whole run. It is a script step and not a Velero hook on purpose:
# Velero's only hook mechanism is an exec inside a target pod, and "create a
# Backup CR and watch its status" is an API interaction, not a pod command.
# The hourly Velero Schedule does not call this either: CNPG ships every WAL
# segment within 300 s on its own, a five minute recovery point the hourly
# schedule cannot improve.
#
# Callers:
#   * `teardown MODE=preserve` (deploy#1738) runs this, then
#     `velero backup create`, then backup-verify.
#   * The CNPG barman drill that ran it with a deliberately impossible
#     timeout first (to prove the timeout path can fail) was removed on
#     2026-09-07 with the other chart-internal drills; it returns as a chart
#     suite in zeroroot-ai/charts.
#
# The wait is phase-driven and loud: `completed` exits 0, `failed` exits 1
# with the CR's own error, and the deadline exits 1 with the last phase. The
# Backup CR is applied idempotently, so a caller that timed out may call
# again with the same name and pick up the same backup.
#
# Usage:
#   test/dr/cnpg-backup-and-wait.sh --namespace gibson \
#     --cluster platform-postgres --name pre-teardown-1725000000 \
#     --timeout 600

set -euo pipefail

NS=gibson
CLUSTER=platform-postgres
NAME=""
TIMEOUT=600

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --name)      NAME="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$NAME" ] || { echo "--name is required (the Backup CR name, so the caller can find it again)" >&2; exit 2; }

die() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

kubectl -n "$NS" apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $NAME
  namespace: $NS
spec:
  method: barmanObjectStore
  cluster:
    name: $CLUSTER
YAML

DEADLINE=$(( $(date +%s) + TIMEOUT ))
PHASE=""
while :; do
  PHASE="$(kubectl -n "$NS" get "backup.postgresql.cnpg.io/$NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  printf '  backup %s phase=%s\n' "$NAME" "${PHASE:-<none>}"
  case "$PHASE" in
    completed) break ;;
    failed) die "backup $NAME FAILED: $(kubectl -n "$NS" get "backup.postgresql.cnpg.io/$NAME" -o jsonpath='{.status.error}')" ;;
  esac
  [ "$(date +%s)" -lt "$DEADLINE" ] || die "backup $NAME did not complete within ${TIMEOUT}s (last phase: ${PHASE:-<none>}) — a preserve teardown MUST NOT proceed past this"
  sleep 5
done

BACKUP_ID="$(kubectl -n "$NS" get "backup.postgresql.cnpg.io/$NAME" -o jsonpath='{.status.backupId}')"
echo "completed: backup $NAME, backupId $BACKUP_ID"
