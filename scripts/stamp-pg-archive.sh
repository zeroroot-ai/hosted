#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stamp-pg-archive.sh — pick the next free Postgres archive directory and write
# it into the env overlay (hosted#182).
#
# WHY THIS EXISTS
#
# platformPostgres.backup.serverName is the archive directory a cluster writes:
# <destinationPath>/<serverName>/. It is stamped per BRINGUP, not per
# environment, because the durable bucket outlives the cluster (ADR-0083) and
# barman-cloud-check-wal-archive refuses a fresh cluster whose directory already
# holds WAL. A second bringup under a used name comes up Ready and Healthy with
# NO backups and says nothing about it, which is why the recreate refuses it.
#
# ENV=kind stamps the name per bootstrap, because it builds its Argo Application
# inline. The AWS path cannot: gitops/envs/<env>/ is a plain manifest directory
# the app-of-apps syncs from git, so the name of a FRESH bringup can only be a
# reviewed commit. The one per-run seam of the AWS path (D91) is for a restore
# only, and carries only values derived from the named backup.
#
# So the reviewed commit stays. What this removes is the part that was never a
# decision: working out a free name and hand-editing YAML in the middle of a
# bringup. It reads the same bucket the gate reads, finds the first unused
# directory, and writes it. The operator commits and opens the PR.
#
# It NEVER deletes an archive. The old directory is the restore source for the
# environment that wrote it (ADR-0083).
#
# Usage:
#   scripts/stamp-pg-archive.sh <substrate.env> <env>
#   make stamp-pg-archive ENV=staging
#
# Reads: the overlay, and the durable bucket with the keyring's own credential.
# Writes: one line of gitops/envs/<env>/values.yaml. Nothing else, ever.
# ---------------------------------------------------------------------------
set -euo pipefail

SUBSTRATE_ENV="${1:-}"
ENV_NAME="${2:-}"
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
log() { printf "${GREEN}▶${NC} [stamp-pg-archive] %s\n" "$*" >&2; }
die() { printf "${RED}✗${NC} [stamp-pg-archive] %s\n" "$*" >&2; exit 1; }

[ -n "$SUBSTRATE_ENV" ] && [ -n "$ENV_NAME" ] \
  || die "usage: stamp-pg-archive.sh <substrate.env> <env>"
[ -s "$SUBSTRATE_ENV" ] || die "no substrate.env at ${SUBSTRATE_ENV}: run \`make substrate ENV=${ENV_NAME}\` first"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GITOPS_PATH="${GITOPS_PATH:-gitops/envs/${ENV_NAME}}"
RESTORE_FROM=""   # the lib reads it; this verb never restores

# The SAME readers the gate uses, so the bucket, the credential and the endpoint
# can never disagree with what the recreate will check (ADR-0027). NOT
# bringup-before-cluster.sh: that one ends by running the archive gate, whose
# refusal is what sends an operator here.
# shellcheck source=lib/durable-bucket.sh
. "$HERE/lib/durable-bucket.sh"

OVERLAY="$REPO/${GITOPS_PATH}/values.yaml"
[ -s "$OVERLAY" ] || die "no gitops overlay at ${OVERLAY}"

read -r DEST CURRENT <<<"$(python3 - "$OVERLAY" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
b = ((v.get("platformPostgres") or {}).get("backup") or {})
print((b.get("destinationPath") or "-"), (b.get("serverName") or "-"))
PY
)"
[ "$DEST" != "-" ] || die "${OVERLAY} sets no platformPostgres.backup.destinationPath"

BUCKET_FROM_OVERLAY="${DEST#s3://}"; BUCKET_FROM_OVERLAY="${BUCKET_FROM_OVERLAY%%/*}"
PREFIX="${DEST#s3://*/}"
[ "$BUCKET_FROM_OVERLAY" = "$BUCKET_NAME" ] \
  || die "${OVERLAY} archives into s3://${BUCKET_FROM_OVERLAY}/ but this substrate's bucket is ${BUCKET_NAME}. Stamping a name in the wrong bucket proves nothing"

# used <name> — does that directory already hold anything?
#
# `length(Contents)` raises on an empty prefix, because S3 omits the key
# entirely; `|| []` supplies the empty list. --max-keys is the SERVER-side
# bound, unlike --max-items which is the CLI's own paginator.
used() {
  local n
  n="$(s3 s3api list-objects-v2 --bucket "$BUCKET_NAME" \
        --prefix "${PREFIX}${1}/" --max-keys 1 \
        --query 'length(Contents || `[]`)' --output text 2>/dev/null)" \
    || die "could not list s3://${BUCKET_NAME}/${PREFIX}${1}/ with the keyring bucket credential. A name cannot be proved free, and stamping one that is not free is the failure this exists to prevent"
  case "$n" in ''|None|0) return 1 ;; *) return 0 ;; esac
}

if [ "$CURRENT" != "-" ] && ! used "$CURRENT"; then
  log "s3://${BUCKET_NAME}/${PREFIX}${CURRENT}/ is empty, so ${CURRENT} is still free"
  printf "${GREEN}✓${NC} nothing to stamp: %s can archive as it stands\n" "$ENV_NAME"
  exit 0
fi

# The first free name. Date first, because an operator reading the bucket wants
# to know WHEN, then a letter for a second bringup on the same day. Bounded, so
# a bucket-wide credential failure cannot spin.
BASE="platform-postgres-$(date -u +%Y%m%d)"
NEXT=""
for suffix in "" b c d e f g h i j k l m n o p q r s t u v w x y z; do
  if ! used "${BASE}${suffix}"; then NEXT="${BASE}${suffix}"; break; fi
done
[ -n "$NEXT" ] || die "every name from ${BASE} to ${BASE}z already holds WAL. That is 27 bringups in one day; pick a name by hand"

[ "$NEXT" != "$CURRENT" ] || die "internal: ${NEXT} was measured both used and free"

# One line of the overlay, by the shared writer (also the restore catch-up PR).
python3 "$HERE/lib/overlay-server-name.py" "$OVERLAY" "$NEXT" > "$OVERLAY.new" \
  || { rm -f "$OVERLAY.new"; die "could not rewrite platformPostgres.backup.serverName in ${OVERLAY} (see the line above)"; }
mv "$OVERLAY.new" "$OVERLAY"

log "s3://${BUCKET_NAME}/${PREFIX}${CURRENT}/ holds WAL from an earlier cluster, so ${CURRENT} cannot be reused"
printf "${GREEN}✓${NC} %s: platformPostgres.backup.serverName %s -> %s\n" "$ENV_NAME" "$CURRENT" "$NEXT"
printf "${YELLOW}!${NC} this is a reviewed commit, and the bringup reads it from git. Commit it and merge before the recreate:\n"
printf "    git -C %s add %s\n" "$REPO" "${GITOPS_PATH}/values.yaml"
printf "    git -C %s commit -m 'chore(%s): stamp a fresh Postgres archive directory'\n" "$REPO" "$ENV_NAME"
printf "  The old archive stays: it is the restore source for the cluster that wrote it (ADR-0083).\n"
