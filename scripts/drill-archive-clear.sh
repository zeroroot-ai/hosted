#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# drill-archive-clear.sh — empty the Postgres archive directory of the drill
# at the end of each drill run (hosted#641).
#
# WHY THIS EXISTS
#
# The drill overlay names one fixed platformPostgres.backup.serverName, as a
# reviewed commit (there is no per-run values seam on the AWS path). The
# archive gate of the recreate refuses a directory that holds WAL. So once
# one drill run brought platform Postgres up, every later drill run stopped
# at stage 0a (drill runs 38199199581 and 38211106060, 2026-10-12).
#
# The drill is disposable, and it owns its archive. Its teardown step runs
# this verb after the restore half has read the archive, whether the drill
# passed or failed. The archive name stays fixed in git, and the gate stays
# as it is: a drill that dies before its teardown is refused at the next run,
# with the gate's message.
#
# SCOPE. drill only. Staging and prod keep every archive (ADR-0083): it is
# the restore source of the environment that wrote it. The verb refuses any
# env but drill, and any bucket that is not the drill durable bucket of
# substrate.env, before it lists or deletes anything.
#
# THE DERIVED ARCHIVE OF A RESTORE TOO (D91). A restore recreate reads the
# overlay archive and writes a NEW one, <serverName>-r<backupID>/, derived
# from the named backup (scripts/lib/velero-restore.sh, restore_archive_name).
# The drill owns that directory the same way, so this verb empties each one
# whose name has exactly that shape. A directory with any other name stays.
#
# The delete uses the ambient AWS credential of the drill run (the
# eks-bringup role in CI), not the keyring credential: the bucket policy
# denies the platform credential any delete outside backups/velero/. The
# bucket is versioned, so a delete writes a delete marker; the versions stay
# until the bucket lifecycle expires them. A list then shows the directory
# empty, which is what the gate and barman-cloud-check-wal-archive read.
#
# Usage:
#   scripts/drill-archive-clear.sh <substrate.env> drill
#   make drill-archive-clear ENV=drill
# ---------------------------------------------------------------------------
set -euo pipefail

SUBSTRATE_ENV="${1:-}"
ENV_NAME="${2:-}"
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
log() { printf "${GREEN}▶${NC} [drill-archive-clear] %s\n" "$*" >&2; }
die() { printf "${RED}✗${NC} [drill-archive-clear] %s\n" "$*" >&2; exit 1; }

[ -n "$SUBSTRATE_ENV" ] && [ -n "$ENV_NAME" ] \
  || die "usage: drill-archive-clear.sh <substrate.env> drill"
# The guard. Nothing else in this script runs for another env.
[ "$ENV_NAME" = drill ] \
  || die "ENV=${ENV_NAME}: only the drill clears its archive. Every other archive is the restore source of the environment that wrote it (ADR-0083)"
[ -s "$SUBSTRATE_ENV" ] || die "no substrate.env at ${SUBSTRATE_ENV}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OVERLAY="$REPO/${GITOPS_PATH:-gitops/envs/drill}/values.yaml"
[ -s "$OVERLAY" ] || die "no drill overlay at ${OVERLAY}"

bucket="$(grep -E '^BUCKET_NAME=' "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true)"
[ -n "$bucket" ] || die "${SUBSTRATE_ENV} names no BUCKET_NAME"
case "$bucket" in
  *-drill-durable-*) ;;
  *) die "the bucket ${bucket} of ${SUBSTRATE_ENV} is not a drill durable bucket. Refusing to delete from it" ;;
esac

# shellcheck disable=SC2016
eval "$(python3 -c '
import sys, yaml, shlex
v = yaml.safe_load(open(sys.argv[1])) or {}
b = ((v.get("platformPostgres") or {}).get("backup") or {})
print("dest=%s" % shlex.quote(str(b.get("destinationPath") or "")))
print("name=%s" % shlex.quote(str(b.get("serverName") or "")))
' "$OVERLAY")" || die "could not read platformPostgres.backup from ${OVERLAY}"
[ -n "$dest" ] && [ -n "$name" ] || die "${OVERLAY} sets no platformPostgres.backup.destinationPath or serverName"

overlay_bucket="${dest#s3://}"; overlay_bucket="${overlay_bucket%%/*}"
[ "$overlay_bucket" = "$bucket" ] \
  || die "the drill overlay archives into s3://${overlay_bucket}/, and substrate.env names ${bucket}. Refusing to delete from either"
prefix="${dest#s3://*/}"
prefix="${prefix%/}/"
case "$prefix" in
  backups/postgres/*) ;;
  *) die "the archive prefix ${prefix} is not under backups/postgres/. Refusing to delete it" ;;
esac

# clear_dir <directory-name> — empty <prefix><directory-name>/ and prove it.
clear_dir() {
  local target="s3://${bucket}/${prefix}${1}/" left
  log "deleting every object under ${target}"
  aws s3 rm --recursive --only-show-errors "$target" \
    || die "the delete under ${target} failed. The next drill run is refused at the archive gate until it is empty"
  # shellcheck disable=SC2016
  left="$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "${prefix}${1}/" --max-keys 1 \
      --query 'length(Contents || `[]`)' --output text 2>/dev/null)" \
    || die "could not list ${target} after the delete"
  case "$left" in
    0|None|'') log "${target} is empty: the next drill run can archive" ;;
    *) die "${target} still lists ${left} object(s) after the delete" ;;
  esac
}

clear_dir "$name"

# The derived archives of the restores: <name>-r<backupID>/, and no other
# name. The listing with a delimiter returns each directory under the prefix
# once, and the shape check keeps a hand-stamped neighbor such as <name>b.
derived="$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "${prefix}${name}-r" --delimiter / \
    --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null)" \
  || die "could not list the restore archives under s3://${bucket}/${prefix}${name}-r"
for d in $derived; do
  [ "$d" != None ] || continue
  d="${d#"$prefix"}"; d="${d%/}"
  case "$d" in
    "${name}"-r[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]) clear_dir "$d" ;;
    *) log "s3://${bucket}/${prefix}${d}/ is not a restore archive of ${name}; left alone" ;;
  esac
done
