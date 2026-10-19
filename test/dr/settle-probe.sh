#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# settle-probe.sh — prove, on the drill, that the recovery parameters can
# leave a running Postgres Cluster (D91, hosted#687).
#
#   test/dr/settle-probe.sh            (make with-cluster ENV=drill CMD=...)
#
# WHY THIS EXISTS. After a restore of staging or prod, `make restore-settle`
# removes the three recovery parameters from the live gibson Application.
# The chart then renders `bootstrap.initdb` and no `externalClusters` for a
# Cluster that is already running. restore-settle was proven only against
# stubs, so the first real removal would be on a permanent env. The drill
# restore half runs this probe after the marker check instead: it removes
# the TWO recovery parameters (recovery.backupID and recovery.serverName)
# and keeps backup.serverName, which is exactly the CNPG change that
# restore-settle makes once Git names the live archive. It then proves:
#
#   1. the CNPG webhook accepted the change: the live Cluster has
#      bootstrap.initdb and no externalClusters;
#   2. the Cluster did nothing on it: the primary pod has the same UID,
#      and it still archives into the same directory;
#   3. Argo is Synced and Healthy with the new render.
#
# The drill is a throwaway env, so the Application stays in this state until
# the teardown. The drill opens no catch-up PR (restore-recovery.sh), so
# restore-settle itself cannot run there: Git never names the drill's
# derived archive, and the settle verb refuses that by design.
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../../scripts" && pwd)"
log() { printf '\n\033[1;32m▶\033[0m [settle-probe] %s\n' "$*"; }
die() { printf '\033[1;31mFAIL [settle-probe]: %s\033[0m\n' "$*" >&2; exit 1; }

# shellcheck source=../../scripts/lib/settle-wait.sh
. "$SCRIPTS/lib/settle-wait.sh"
# RECOVERY_PARAMETERS, the one list of the three names.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# shellcheck source=../../scripts/lib/restore-recovery.sh
HERE="$SCRIPTS" . "$SCRIPTS/lib/restore-recovery.sh"

names="$(gibson_app_parameter_names)"
[ "$names" = "$RECOVERY_PARAMETERS" ] \
  || die "Application gibson carries the parameters '${names}', not the three of D91 (${RECOVERY_PARAMETERS}). This probe runs only on a restored drill"

archive="$(cluster_archive)"
[ -n "$archive" ] || die "the Cluster platform-postgres names no archive"
uid_before="$(cluster_primary_uid)" || die "the Cluster platform-postgres reports no primary"
kind_before="$(kubectl -n gibson get cluster.postgresql.cnpg.io platform-postgres \
  -o jsonpath='{.spec.bootstrap.recovery.source}' 2>/dev/null)"
[ -n "$kind_before" ] \
  || die "the Cluster has no bootstrap.recovery before the probe, so there is no recovery to remove. Was this cluster restored?"
log "before: primary pod ${uid_before}, bootstrap.recovery from ${kind_before}, archive ${archive}"

# The two recovery parameters are entries 0 and 1 of the list, in the order
# of RECOVERY_PARAMETERS. Each remove is guarded by a test on the name, so
# the patch fails whole when the list is not in that order.
kubectl -n argocd patch application gibson --type json -p '[
  {"op":"test","path":"/spec/sources/0/helm/parameters/0/name","value":"platformPostgres.recovery.backupID"},
  {"op":"remove","path":"/spec/sources/0/helm/parameters/0"},
  {"op":"test","path":"/spec/sources/0/helm/parameters/0/name","value":"platformPostgres.recovery.serverName"},
  {"op":"remove","path":"/spec/sources/0/helm/parameters/0"}
]' >/dev/null || die "could not remove the two recovery parameters from Application gibson"
log "removed recovery.backupID and recovery.serverName; backup.serverName stays ${archive}"

settle_wait "$archive" "the removal of the recovery parameters"

source_after="$(kubectl -n gibson get cluster.postgresql.cnpg.io platform-postgres \
  -o jsonpath='{.spec.bootstrap.recovery.source}' 2>/dev/null)"
initdb_after="$(kubectl -n gibson get cluster.postgresql.cnpg.io platform-postgres \
  -o jsonpath='{.spec.bootstrap.initdb.database}' 2>/dev/null)"
external_after="$(kubectl -n gibson get cluster.postgresql.cnpg.io platform-postgres \
  -o jsonpath='{.spec.externalClusters[*].name}' 2>/dev/null)"
[ -z "$source_after" ] && [ -n "$initdb_after" ] && [ -z "$external_after" ] \
  || die "the live Cluster still has bootstrap.recovery '${source_after}' (initdb '${initdb_after}', externalClusters '${external_after}'): the CNPG webhook refused the change, or Argo did not apply it"
uid_after="$(cluster_primary_uid)" || die "the Cluster reports no primary after the change"
[ "$uid_after" = "$uid_before" ] \
  || die "the primary pod changed from ${uid_before} to ${uid_after}: the removal restarted Postgres"
archiving="$(kubectl -n gibson get cluster.postgresql.cnpg.io platform-postgres \
  -o "jsonpath={range .status.conditions[?(@.type=='ContinuousArchiving')]}{.status}{end}" 2>/dev/null)"
[ "$archiving" = True ] \
  || die "ContinuousArchiving is '${archiving:-<unset>}' after the change"
printf '\033[1;32m     ✓ the recovery parameters left a running Cluster: bootstrap is initdb, no externalClusters, primary %s unchanged, archiving to %s\033[0m\n' \
  "$uid_after" "$archive"
