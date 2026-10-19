# shellcheck shell=bash
# ---------------------------------------------------------------------------
# bringup-before-cluster.sh — everything a recreate proves BEFORE it builds a
# cluster, for every substrate (hosted#159).
#
# It is SOURCED, so the code runs with the caller's variables in scope exactly
# where it used to run inside scripts/recreate-aws.sh. The extraction moved no
# logic: a diff against the old head shows no changed line.
#
# Reading stage 0 and refusing early is the whole job here. A bringup that
# cannot prove its archive is empty would come up Healthy with no backups,
# and one that names a backup nobody has would fail after building an estate.
#
# The caller must have set: SUBSTRATE_ENV, ENV_NAME, REPO, HERE, WORK,
# GITOPS_PATH, RESTORE_FROM, and its own log() and die(). It may set
# LIVE_CLUSTER_SINCE, the creation time of a cluster of ENV that is already
# up (hosted#624): the archive gate then accepts the archive of that cluster.
#
# It reads the keyring with scripts/keyring.sh (HERE is the scripts directory).
#
# It leaves behind, for the caller and for the shared tail:
#   substrate_get keyring_get s3   readers for stage 0
#   BUCKET_ENDPOINT BUCKET_NAME BUCKET_REGION KEYRING_FILE
#   VELERO_BUCKET_PREFIX           the Velero prefix of the overlay
#   RECOVERY_BACKUP_ID RECOVERY_ARCHIVE_NAME   when RESTORE_FROM named one
#   RESTORE_ARCHIVE_NAME           the NEW archive a restore writes (D91)
# ---------------------------------------------------------------------------

# The substrate readers and the durable-bucket client live in their own lib,
# because scripts/stamp-pg-archive.sh needs exactly these and cannot source
# this file: this one ENDS by running the archive gate, and that gate's
# refusal is what tells an operator to run that verb.
# shellcheck source=lib/durable-bucket.sh
. "$HERE/lib/durable-bucket.sh"

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT


# ---------------------------------------------------------------------------
# Stage 0a — the Postgres archive this bringup will write is EMPTY.
#
# barman-cloud-check-wal-archive refuses a fresh cluster whose archive
# directory already holds WAL, and the durable bucket outlives the cluster by
# design (ADR-0083). So the SECOND bringup into one bucket meets the first
# one's segments: ContinuousArchiving goes False on the first archive_command
# and every base backup sits in walArchivingFailing (measured 2026-09-07, and
# again on the staging bucket 2026-09-14, which held 12 objects under
# backups/postgres/platform-postgres/ after the teardown).
#
# CNPG reports that cluster Ready and Argo reports the Application Healthy,
# so nothing else in this bringup notices. The environment comes up with no
# backups at all and says nothing. That is the failure this refuses to ship.
#
# The fix is one line: stamp a new platformPostgres.backup.serverName in the
# env overlay. On ENV=kind the recreate stamps it per bootstrap, because kind
# builds its own Application inline. The AWS path reads its Applications from
# git through the app-of-apps, so on a fresh bringup the name is a reviewed
# commit and this is the gate that demands it. The one per-run seam (D91)
# carries only the values a restore derives from the named backup.
# THE GATE KNOWS THE MODE (D91). A fresh recreate archives into the overlay's
# serverName, so that directory must be empty. A restore recreate reads the
# archive that the named backup was written under, which is full by design,
# and writes a NEW one, RESTORE_ARCHIVE_NAME, derived from the named backup.
# So a restore requires the source to hold the named base backup and the
# derived directory to be empty. The chart refuses a recovery whose source
# and target directory are one directory, and CNPG refuses to archive into a
# directory that holds WAL, so accepting the source as the target would only
# move the stop to wait_archiving.
assert_empty_pg_archive() {
  # GITOPS_PATH is the overlay the app-of-apps syncs, so this reads the SAME
  # file Argo will render from and never a second copy of it.
  local overlay="$REPO/${GITOPS_PATH}/values.yaml" dest name prefix objects target
  [ -s "$overlay" ] || die "no gitops overlay at ${overlay}: stage 2 has no values to sync"
  # shellcheck disable=SC2016
  eval "$(python3 -c '
import sys, yaml, shlex
v = yaml.safe_load(open(sys.argv[1])) or {}
b = ((v.get("platformPostgres") or {}).get("backup") or {})
print("dest=%s" % shlex.quote(str(b.get("destinationPath") or "")))
print("name=%s" % shlex.quote(str(b.get("serverName") or "")))
' "$overlay")" || die "could not read platformPostgres.backup from ${overlay}"

  [ -n "$dest" ] || die "${overlay} sets no platformPostgres.backup.destinationPath. The chart requires it and the render fails without it (deploy#1730)"
  [ -n "$name" ] || die "${overlay} sets no platformPostgres.backup.serverName. Empty means CNPG's default, the Cluster's own name, which is correct only for the FIRST bootstrap into an empty archive. Stamp a unique name, for example platform-postgres-$(date -u +%Y%m%d)"

  # The bucket the OVERLAY names, which is the one the cluster will actually
  # archive into. Everything below lists $BUCKET_NAME, which comes from
  # substrate.env — a terraform output. Those are two sources for one fact, and
  # nothing compared them: a gate that proves a prefix empty in the substrate's
  # bucket while the chart writes to a different one passes, and the cluster
  # comes up Healthy with no backups. That is the failure this whole gate
  # exists to stop, reached through the gate itself.
  local overlay_bucket="${dest#s3://}"
  overlay_bucket="${overlay_bucket%%/*}"
  [ -n "$overlay_bucket" ] || die "${overlay} has platformPostgres.backup.destinationPath=${dest}, which names no bucket. It must be s3://<bucket>/<prefix>/"
  [ "$overlay_bucket" = "$BUCKET_NAME" ] || die "${overlay} archives into s3://${overlay_bucket}/ but this substrate's bucket is ${BUCKET_NAME} (${SUBSTRATE_ENV}). One of the two is wrong, and proving a prefix empty in the substrate's bucket would say nothing about the one the chart writes to: the cluster would come up Healthy with no backups. Fix destinationPath in the overlay, or bring up against the substrate that owns that bucket"

  prefix="${dest#s3://*/}"

  # The directory THIS cluster will write.
  target="$name"
  if [ -n "$RESTORE_FROM" ]; then
    target="$RESTORE_ARCHIVE_NAME"
    # The source holds the named base backup: <serverName>/base/<backupID>/.
    objects="$(pg_archive_count "${prefix}${RECOVERY_ARCHIVE_NAME}/base/${RECOVERY_BACKUP_ID}/")"
    case "$objects" in
      ''|None|0) die "backup '${RESTORE_FROM}' names base backup ${RECOVERY_BACKUP_ID} in archive ${RECOVERY_ARCHIVE_NAME}, and s3://${BUCKET_NAME}/${prefix}${RECOVERY_ARCHIVE_NAME}/base/${RECOVERY_BACKUP_ID}/ holds nothing. Postgres would have nothing to recover from. Was the archive deleted, or does the overlay name another destinationPath than the cluster that wrote it?" ;;
    esac
    log "stage 0a: the source archive s3://${BUCKET_NAME}/${prefix}${RECOVERY_ARCHIVE_NAME}/ holds base backup ${RECOVERY_BACKUP_ID}"
  fi

  objects="$(pg_archive_count "${prefix}${target}/")"
  # A recreate that stopped in stage 2 leaves its cluster up, and that
  # cluster has archived into this directory. A second run continues the
  # SAME cluster, so its own WAL is no reason to refuse (hosted#624). The
  # caller sets LIVE_CLUSTER_SINCE to the creation time of the live cluster
  # (ISO 8601) or leaves it empty. The archive belongs to that cluster when
  # its OLDEST object is newer than the cluster: an earlier cluster wrote
  # before this one existed.
  #
  # The reach of this rule: it proves that the archive was written after the
  # live NODE (or EKS cluster) came up, not that the live Postgres cluster
  # wrote it. A second Postgres cluster on the same node (its CNPG cluster or
  # volume deleted between two runs) has a new system identifier and would
  # pass here. CNPG refuses that case itself: a new cluster on a non-empty
  # WAL archive stops with "Expected empty archive", so the result is a later
  # stop, never a silent mix of timelines. A tighter rule compares the system
  # identifier of the archive with the one of the live cluster; it needs the
  # cluster API, which this stage does not have (hosted#624 review).
  if [ -n "$objects" ] && [ "$objects" != None ] && [ "$objects" != 0 ] && [ -n "${LIVE_CLUSTER_SINCE:-}" ]; then
    local oldest
    oldest="$(s3 s3api list-objects-v2 --bucket "$BUCKET_NAME" --prefix "${prefix}${target}/" \
        --query 'min(Contents[].LastModified)' --output text 2>/dev/null)" \
      || die "could not read the oldest object of s3://${BUCKET_NAME}/${prefix}${target}/"
    if python3 -c '
import sys
from datetime import datetime
def t(s): return datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
sys.exit(0 if t(sys.argv[1]) >= t(sys.argv[2]) else 1)' "$oldest" "$LIVE_CLUSTER_SINCE" 2>/dev/null; then
      log "stage 0a: the Postgres archive s3://${BUCKET_NAME}/${prefix}${target}/ was written by the live cluster (created ${LIVE_CLUSTER_SINCE}, oldest object ${oldest}), so this run continues it"
      return 0
    fi
  fi
  case "$objects" in
    ''|None|0) ;;
    *)
      [ -z "$RESTORE_FROM" ] || die "the restore archive s3://${BUCKET_NAME}/${prefix}${target}/ already holds WAL, and no live cluster of ${ENV_NAME} wrote it. The name is derived from backup '${RESTORE_FROM}', so an earlier restore of the same backup wrote it. Restore from a newer preserve backup. Never delete the archive: it is the restore source for the cluster that wrote it (ADR-0083)"
      die "the Postgres archive s3://${BUCKET_NAME}/${prefix}${target}/ already holds WAL from an earlier cluster. barman-cloud-check-wal-archive refuses it, so this bringup would come up Healthy with NO backups. Run \`make stamp-pg-archive ENV=${ENV_NAME}\`: it finds the first free directory in this bucket and writes platformPostgres.backup.serverName into ${overlay}. Commit that one line and run the recreate again. Never delete the old archive: it is the restore source for the environment that wrote it (ADR-0083)" ;;
  esac
  log "stage 0a: the Postgres archive s3://${BUCKET_NAME}/${prefix}${target}/ is empty, so this bringup can archive"
}

# pg_archive_count <prefix> — 0 when nothing is under the prefix, else 1.
#
# `length(Contents)` is WRONG here and fails on exactly the case this gate
# exists to allow: an empty prefix has no Contents key at all, jmespath
# raises "invalid type for value: None", the CLI exits non-zero, and the
# gate refuses a bringup whose archive is empty. `|| \`[]\`` supplies the
# empty list. --max-keys is the SERVER-side bound; --max-items is the CLI's
# own paginator and prints a second line when it truncates.
pg_archive_count() {
  local n
  # shellcheck disable=SC2016
  n="$(s3 s3api list-objects-v2 --bucket "$BUCKET_NAME" \
      --prefix "$1" --max-keys 1 \
      --query 'length(Contents || `[]`)' --output text 2>/dev/null)" \
    || die "could not list s3://${BUCKET_NAME}/$1 with the keyring bucket credential. The archive cannot be proved, and a bringup that archives into a used directory comes up with no backups"
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# Stage 0c — the setec disk inputs of the overlay match stage 0 (D85).
#
# The setec chart needs two install inputs: the registry of the signed disks
# (setec.launcher.diskRepo) and the public key of the keyring seed that signs
# them (setec.launcher.diskBuilder.publicKeys). Argo renders the overlay from
# git, so both are reviewed commits, the same as backup.serverName. Two
# sources then name one fact each: substrate.env and the overlay name the
# registry, and the keyring and the overlay hold the key. Nothing else
# compares them. A wrong key is a platform that comes up Healthy and refuses
# every disk at the first Sandbox. So the bringup refuses it here.
#
# On a rebuild the overlay holds SET-AT-REBUILD until the owner commits the
# key of the new keyring. The refusal prints the key to commit.
#
# The key list must be exactly the keys of the keyring seeds: the seed, and
# the previous seed while a rotation keeps one (hosted#555, ADR-0171). A
# missing previous key refuses the disks of the previous seed. A key of a
# retired seed lets a launcher accept a disk that the retired seed signed.
assert_setec_disk_inputs() {
  local overlay="$REPO/${GITOPS_PATH}/values.yaml" repo keys want_repo want_key want_keys prev_key k
  [ -s "$overlay" ] || die "no gitops overlay at ${overlay}: stage 2 has no values to sync"
  # shellcheck disable=SC2016
  eval "$(python3 -c '
import sys, yaml, shlex
v = yaml.safe_load(open(sys.argv[1])) or {}
l = (((v.get("gibson-workloads") or {}).get("setec") or {}).get("launcher") or {})
keys = (l.get("diskBuilder") or {}).get("publicKeys") or []
print("repo=%s" % shlex.quote(str(l.get("diskRepo") or "")))
print("keys=%s" % shlex.quote(" ".join(str(k) for k in keys)))
' "$overlay")" || die "could not read gibson-workloads.setec.launcher from ${overlay}"

  want_repo="$(substrate_get SETEC_DISK_REPO || true)"
  [ -n "$want_repo" ] || die "${SUBSTRATE_ENV} has no SETEC_DISK_REPO, the registry of the signed setec disks (D85). Run make substrate ENV=${ENV_NAME} again"
  [ "$repo" = "$want_repo" ] || die "${overlay} sets gibson-workloads.setec.launcher.diskRepo to '${repo}', but stage 0 of ${ENV_NAME} made ${want_repo}. Commit that value in the overlay"

  want_keys="$("$HERE/keyring.sh" disk-public-keys "$KEYRING_FILE")" \
    || die "could not derive the setec disk public key from ${KEYRING_FILE}. A keyring from before D85 has no SETEC_DISK_SIGNING_SEED"
  want_key="$(printf '%s\n' "$want_keys" | sed -n 1p)"
  prev_key="$(printf '%s\n' "$want_keys" | sed -n 2p)"
  case " ${keys} " in
    *" ${want_key} "*) ;;
    *) die "${overlay} lists the setec disk public keys '${keys:-<none>}', and none is the key of the keyring seed SETEC_DISK_SIGNING_SEED. Each launcher would refuse every disk that this bringup signs. Commit this key in gibson-workloads.setec.launcher.diskBuilder.publicKeys, then run the recreate again: ${want_key}" ;;
  esac
  # A seed rotation (keyring.sh, ROTATION) keeps the previous seed until each
  # disk is signed again. The launchers must accept its disks until then.
  # On drill the previous seed is permanent: the rotation test switches to
  # it (hosted#444, option a), so drill is never retired.
  if [ -n "$prev_key" ]; then
    case " ${keys} " in
      *" ${prev_key} "*) ;;
      *) die "${overlay} does not list the key of SETEC_DISK_SIGNING_SEED_PREVIOUS, and the keyring keeps that seed: a rotation is in progress. Each launcher would refuse every disk that the previous seed signed. Commit this key beside ${want_key}, or run keyring.sh retire when each disk is signed again: ${prev_key}" ;;
    esac
  fi
  # A key of no seed in the keyring is a retired seed that each launcher
  # still accepts. A rotation is complete only when the overlay drops it.
  for k in $keys; do
    [ "$k" = "$want_key" ] || [ "$k" = "$prev_key" ] \
      || die "${overlay} lists the setec disk public key ${k}, which is the key of no seed in ${KEYRING_FILE}. Each launcher would accept a disk that a retired seed signed. Delete it from gibson-workloads.setec.launcher.diskBuilder.publicKeys, then run the recreate again"
  done
  log "stage 0c: the overlay names the disk registry ${repo} and exactly the public keys of the keyring disk seeds"
}

# ---------------------------------------------------------------------------
# Stage 0b — the named backup, proven to exist BEFORE anything is applied.
#
# The whole restore half is scripts/lib/velero-restore.sh: it speaks kubectl,
# the bucket and Velero and nothing else, so ENV=kind runs the SAME code
# (scripts/recreate-kind.sh). resolve_named_backup sets RECOVERY_BACKUP_ID.
# ---------------------------------------------------------------------------
# shellcheck source=lib/velero-restore.sh
. "$HERE/lib/velero-restore.sh"

# The prefix the Velero release of this env writes under. Argo renders that
# release from the overlay, so the overlay is the one source (hosted#593).
# velero-restore.sh reads it.
# shellcheck disable=SC2034
VELERO_BUCKET_PREFIX="$(velero_overlay_prefix "$REPO/${GITOPS_PATH}/gibson-velero-values.yaml")" \
  || die "could not read bucket.prefix from $REPO/${GITOPS_PATH}/gibson-velero-values.yaml"

RESTORE_ARCHIVE_NAME=""
if [ -n "$RESTORE_FROM" ]; then
  resolve_named_backup
  # shellcheck disable=SC2034  # read by lib/bringup-after-cluster.sh
  RESTORE_ARCHIVE_NAME="$(restore_archive_name "$RECOVERY_ARCHIVE_NAME" "$RECOVERY_BACKUP_ID")"
fi

# The disk gate and the archive gate run here, after the RESTORE_FROM name
# check: a refusal that needs no I/O is always the cheaper one to fire first,
# and the disk gate reads only local files.
assert_setec_disk_inputs
assert_empty_pg_archive
