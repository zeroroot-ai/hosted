#!/usr/bin/env bash
# wait-archiving.sh — "the platform Postgres actually archives its WAL", for
# EVERY substrate (ADR-0083, blocker 3).
#
# WHY THIS EXISTS
# ---------------
# CNPG reports the Cluster Ready and Argo reports the Application Healthy
# whether or not a single WAL segment ever reaches the bucket. Archiving is a
# separate condition, and nothing in either bringup verb read it. Every
# failure in this class has therefore been SILENT, and each one was found
# weeks later by a human looking at the bucket:
#
#   the kind MinIO endpoint on an AWS cluster    Every AWS bringup since the
#     seam existed pointed platform Postgres at http://172.18.255.250:9000,
#     an address that is not on the network. "Connect timeout on endpoint URL"
#     every five minutes, no WAL archived, no base backup taken. Measured on
#     the 2026-09-14 from-zero staging bringup.
#   an archive directory that already held WAL   The durable bucket outlives
#     the cluster, and barman-cloud-check-wal-archive refuses a fresh cluster
#     whose directory is not empty. ContinuousArchiving goes False on the
#     first archive_command and every base backup sits in walArchivingFailing.
#     Measured 2026-09-07.
#
# scripts/recreate-aws.sh refuses to START a bringup whose archive directory
# is not empty. This is the other half: a bringup that cannot say the archive
# WORKS has not finished. A gate on the inputs is not proof of the outcome.
#
# Source this file, then call `wait_archiving`. The caller supplies:
#
#   NS                    the release namespace
#   ARCHIVING_TIMEOUT     the hard cap (default below)
#   die()                 MUST exit non-zero
#
# Both proofs are required, and they prove different things:
#   ContinuousArchiving=True   a WAL segment reached the bucket, so the
#                              credential, the endpoint and the directory are
#                              all right.
#   one completed Backup       the base backup the scheduled backup takes
#                              immediately on creation. Without it the archive
#                              holds WAL with nothing to replay it onto, and a
#                              restore has no starting point (ADR-0083).

ARCHIVING_TIMEOUT="${ARCHIVING_TIMEOUT:-900}"
# How long to wait between looks. A test suite sets 0, so a suite that gets
# the stub wrong reports a failure in seconds instead of sleeping its way to
# the job's own timeout.
ARCHIVING_POLL="${ARCHIVING_POLL:-10}"

# cnpg_condition <type> — the status of one condition on the Cluster, or the
# empty string while the operator has not written it yet.
cnpg_condition() {
  kubectl -n "$NS" get cluster.postgresql.cnpg.io platform-postgres \
    -o "jsonpath={range .status.conditions[?(@.type=='$1')]}{.status}{end}" 2>/dev/null
}

# completed_backups — how many CNPG Backup objects have finished.
completed_backups() {
  kubectl -n "$NS" get backups.postgresql.cnpg.io \
    -o 'jsonpath={range .items[?(@.status.phase=="completed")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | grep -c . || true
}

wait_archiving() {
  local deadline=$(( $(date +%s) + ARCHIVING_TIMEOUT ))
  local archiving backups reason
  while :; do
    archiving="$(cnpg_condition ContinuousArchiving)"
    backups="$(completed_backups)"
    if [ "$archiving" = True ] && [ "${backups:-0}" -ge 1 ]; then
      printf '  ✓ platform Postgres archives its WAL, and %s base backup(s) completed\n' "$backups"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # Name what is actually wrong. "archiving failed" with no reason sends
      # the reader to the operator logs for something the CR already says.
      reason="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io platform-postgres \
        -o "jsonpath={range .status.conditions[?(@.type=='ContinuousArchiving')]}{.reason}: {.message}{end}" 2>/dev/null)"
      die "platform Postgres is not archiving after ${ARCHIVING_TIMEOUT}s: ContinuousArchiving=${archiving:-<unset>}, completed base backups=${backups:-0}.
    ${reason:-the operator has written no ContinuousArchiving condition at all}
    The cluster is UP and Argo reads Healthy, which is exactly why this is checked: an environment with no backups looks identical to one with backups until somebody needs a restore (ADR-0083, blocker 3).
    Read: kubectl -n ${NS} get cluster platform-postgres -o yaml, and the archive directory the Cluster names under spec.backup.barmanObjectStore"
    fi
    printf '  platform Postgres: archiving=%s base-backups=%s          \r' \
      "${archiving:-<unset>}" "${backups:-0}"
    [ "${ARCHIVING_POLL:-10}" = 0 ] || sleep "$ARCHIVING_POLL"
  done
}
