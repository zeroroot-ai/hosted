#!/usr/bin/env bash
# velero-restore.sh — the restore half of a recreate, for EVERY substrate
# (ADR-0083, deploy#1739, deploy#1746).
#
# A recreate restores ONLY the backup named on the command line. There is no
# `latest`, no auto-detect and no default that turns the restore on. Every
# step below speaks kubectl, the durable bucket and Velero, and nothing here
# knows what the cluster runs on, so ENV=kind and ENV=staging run the SAME
# code and there is no second implementation to drift (ADR-0027).
#
# Source this file, then call, in this order:
#
#   resolve_named_backup   before anything is destroyed. Proves the named
#                          backup is in the bucket and resolves the ONE thing
#                          Postgres needs out of the same name, the CNPG base
#                          backup id. Sets RECOVERY_BACKUP_ID.
#   restore_secret_store   after stage 1 and the Velero release, before the
#                          platform Application exists.
#   wait_eso               every Secret is out of the restored store.
#   restore_data           the built-ins, then the tenant records.
#
# The caller supplies these before the first call:
#
#   RESTORE_FROM          the backup name a preserve teardown printed
#   BUCKET_NAME           the durable bucket
#   VELERO_BUCKET_PREFIX  the prefix the Velero release writes under. The EC2
#                         and EKS paths get it from velero_overlay_prefix
#   NS / VELERO_NS        release and velero namespaces
#   RESTORE_TIMEOUT       OPTIONAL. When set, it replaces every per-step
#                         bound below (a test suite sets 1)
#   WORK                  a scratch directory the caller cleans up
#   s3()                  aws, with the keyring's OWN bucket credential
#   log() / die()         die MUST exit non-zero
#
# Nothing here copies bytes itself and nothing edits a live store by hand:
# the controller that wrote the backup is the controller that reads it back.

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# THE BOUND OF EACH WAIT (hosted drill, time budget). The drill runs as jobs
# of at most 360 minutes, so one bound for every wait, 40 minutes, no longer
# fits: eleven waits at 40 minutes is more than the job. Each wait below gets
# its own bound: twice the time it took on the last restore run that reached
# it, with a floor of 10 minutes. The measurements are from the last green
# restore, hosted run 37350287949 (2026-10-05, the whole preserve-restore
# loop on a kind cluster of a GitHub runner), read from its log:
#
#   wait_app_healthy        gibson-operator-crds+gibson-crds 85 s, velero 114 s
#   wait_backup_synced      20 s
#   restore 1 (openbao)     21 s
#   wait_eso                133 s (11 ExternalSecrets)
#   wait_priority_classes   under 1 s
#   restore 2 (builtins)    415 s (9 volumes)          -> 840 s
#                           Since hosted#790 restore 2 moves no data. The
#                           pods Restore moves it and keeps the 840 s, and
#                           the statefulsets Restore after it gets 600 s.
#   wait_tenant_webhook     under 1 s
#   restore 3 (tenants)     11 s
#   wait_tenant_namespace_labels   NO MEASUREMENT: the step is new, so it
#                           keeps the old 40 minutes until a run measures it
#
# Every other wait is under five minutes measured, so it gets the floor.
# No restore has reached these steps on an EC2 env yet. When one does, read
# its log and set each bound to twice that time.
#
# restore_bound <default-seconds> — the bound, or RESTORE_TIMEOUT when set.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # read by lib/bringup-after-cluster.sh
RESTORE_APP_TIMEOUT=600
RESTORE_SYNC_TIMEOUT=600
RESTORE_STORE_TIMEOUT=600
RESTORE_ESO_TIMEOUT=600
RESTORE_CLASSES_TIMEOUT=600
RESTORE_DATA_TIMEOUT=840
RESTORE_WEBHOOK_TIMEOUT=600
RESTORE_TENANTS_TIMEOUT=600
RESTORE_LABELS_TIMEOUT=2400

restore_bound() { printf '%s' "${RESTORE_TIMEOUT:-$1}"; }

# resolve_named_backup — the named backup, proven to exist BEFORE anything is
# destroyed.
#
# This runs ahead of the destroy, on purpose. A recreate deletes the cluster
# it finds, so a RESTORE_FROM that turns out to name nothing would destroy the
# running environment and then discover it has nothing to put back. The check
# names the exact object it looked for, so a typo in the name is one line of
# output away from being obvious.
#
# It also resolves the ONE thing Postgres needs, out of the SAME name: the
# CNPG base backup id. The preserve teardown gives its CNPG `Backup` CR the
# same name as the Velero backup and takes it BEFORE the Velero backup, so
# the completed record with its `status.backupId` rides inside the archive.
# Reading it here is what keeps ADR-0083 true for Postgres too: the recovery
# target is the backup that was named, never the newest one in the catalog.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# velero_overlay_prefix <gibson-velero-values.yaml> — the bucket prefix that
# the Velero release of an env writes under (hosted#593).
#
# Argo renders the release from this overlay file, so its bucket.prefix is
# the prefix. A file with no bucket.prefix gets the chart default,
# helm/gibson-velero/values.yaml (tests/harness/restore.bats holds the two
# equal). A new VELERO_REPO_PASSWORD starts a new kopia repository at a new
# prefix (scripts/keyring.sh, ROTATION), so a constant here would send a
# restore to the old repository.
#
# The prefix must be backups/velero or a path under it: the platform
# credential may delete only there, and kopia deletes. Any other prefix
# fails here, before a cluster exists.
# ---------------------------------------------------------------------------
VELERO_CHART_PREFIX="backups/velero"

velero_overlay_prefix() {
  local file="$1" prefix
  [ -s "$file" ] || { printf 'velero_overlay_prefix: no overlay at %s\n' "$file" >&2; return 1; }
  prefix="$(python3 -c '
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
print(str(((v.get("bucket") or {}).get("prefix")) or "").strip().strip("/"))
' "$file")" || { printf 'velero_overlay_prefix: %s is not YAML\n' "$file" >&2; return 1; }
  [ -n "$prefix" ] || prefix="$VELERO_CHART_PREFIX"
  case "$prefix" in
    "$VELERO_CHART_PREFIX"|"$VELERO_CHART_PREFIX"/*) ;;
    *) printf 'velero_overlay_prefix: %s sets bucket.prefix %s. It must be %s or a path under it: the platform credential may delete only there, and kopia deletes\n' "$file" "$prefix" "$VELERO_CHART_PREFIX" >&2
       return 1 ;;
  esac
  printf '%s\n' "$prefix"
}

RECOVERY_BACKUP_ID=""
RECOVERY_ARCHIVE_NAME=""

resolve_named_backup() {
  # A Velero backup name is a DNS-1123 label and the preserve teardown builds
  # one. Refuse anything else here rather than let the API server refuse a
  # Restore twenty minutes into a bringup.
  case "$RESTORE_FROM" in
    *[!a-z0-9.-]*|-*|*-|.*|*.)
      die "RESTORE_FROM='${RESTORE_FROM}' is not a backup name. A preserve teardown prints preserve-<env>-<YYYYMMDD>-<HHMMSS>, lower case, digits, dashes and dots only" ;;
  esac
  BACKUP_KEY="${VELERO_BUCKET_PREFIX}/backups/${RESTORE_FROM}/velero-backup.json"
  log "restore: looking for backup '${RESTORE_FROM}' in the durable bucket"
  s3 s3 ls "s3://${BUCKET_NAME}/${BACKUP_KEY}" >/dev/null 2>&1 \
    || die "there is no backup named '${RESTORE_FROM}' in the durable bucket.
    looked for  s3://${BUCKET_NAME}/${BACKUP_KEY}
    A recreate restores ONLY a backup named on the command line (ADR-0083): there is no
    latest, no auto-detect and no fallback to an empty bringup. A preserve teardown
    prints the name it verified as its last line. Run without RESTORE_FROM to bootstrap
    every store empty."
  printf '  ✓ s3://%s/%s\n' "$BUCKET_NAME" "$BACKUP_KEY"

  # The CNPG record, out of the archive Velero wrote next to that manifest.
  # The tarball carries object JSON only (volume data lives in the kopia
  # repository), so it is small enough to read here.
  s3 s3 cp --no-progress "s3://${BUCKET_NAME}/${VELERO_BUCKET_PREFIX}/backups/${RESTORE_FROM}/${RESTORE_FROM}.tar.gz" \
      "$WORK/backup.tar.gz" >/dev/null \
    || die "backup '${RESTORE_FROM}' has a manifest but no archive at s3://${BUCKET_NAME}/${VELERO_BUCKET_PREFIX}/backups/${RESTORE_FROM}/${RESTORE_FROM}.tar.gz. The backup is incomplete and must not be restored"
  CNPG_MEMBER="$(tar -tzf "$WORK/backup.tar.gz" 2>/dev/null \
    | grep -E "backups\.postgresql\.cnpg\.io/.*/${RESTORE_FROM}\.json$" | head -n1 || true)"
  [ -n "$CNPG_MEMBER" ] \
    || die "backup '${RESTORE_FROM}' carries no CNPG Backup record named '${RESTORE_FROM}'.
    A preserve teardown takes the CNPG base backup FIRST and gives it the teardown's own
    name, so a Velero backup without that record was not written by a preserve teardown.
    Postgres has no recovery target, so this restore would bring the graph back over an
    empty database. Refusing."
  RECOVERY_BACKUP_ID="$(tar -xzOf "$WORK/backup.tar.gz" "$CNPG_MEMBER" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",{}).get("backupId",""))')"
  [ -n "$RECOVERY_BACKUP_ID" ] \
    || die "the CNPG Backup record inside '${RESTORE_FROM}' has no status.backupId: the base backup never completed, so there is nothing for Postgres to recover from"
  # The archive that base backup lives in: <destinationPath>/<serverName>/.
  # CNPG records it on the Backup as status.serverName. The recovered
  # cluster reads this archive and writes a NEW one (recreate-kind.sh
  # PG_ARCHIVE_NAME); a cluster archiving into the directory it recovers
  # from fails on its first WAL segment.
  RECOVERY_ARCHIVE_NAME="$(tar -xzOf "$WORK/backup.tar.gz" "$CNPG_MEMBER" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",{}).get("serverName",""))')"
  [ -n "$RECOVERY_ARCHIVE_NAME" ] \
    || die "the CNPG Backup record inside '${RESTORE_FROM}' has no status.serverName: the archive its base backup lives in is unknown, so Postgres cannot be pointed at it"
  printf '  ✓ postgres recovers from base backup %s in archive %s\n' "$RECOVERY_BACKUP_ID" "$RECOVERY_ARCHIVE_NAME"
}

# restore_archive_name <source-archive> <backup-id> — the NEW archive a
# restore of an EC2 or EKS env writes (D91). It is derived, never chosen:
# <source>-r<backup-id>. A source that is itself a restore archive loses its
# own -r<id> first, so a chain of restores does not grow the name. The name
# is unique per base backup, so a second restore of the same backup meets a
# full directory and the archive gate refuses it.
restore_archive_name() {
  local base
  base="$(printf '%s' "$1" | sed -E 's/-r[0-9]{8}T[0-9]{6}$//')"
  printf '%s-r%s' "$base" "$2"
}

# restore_diag <name> — everything the Restore itself recorded, printed
# BEFORE the verb gives up.
#
# `phase: Completed` is not proof that data came back. A Restore narrowed by a
# labelSelector can finish Completed in six seconds having restored NOTHING,
# with no PodVolumeRestore, no warning and no error: a filter that matches no
# item is not an error to Velero (measured on kind 2026-09-02, deploy#1738).
# So the counts are what a reader needs, and a failure with no counts is a
# failure nobody can diagnose.
restore_diag() {
  printf '\n--- restore %s ---\n' "$1" >&2
  kubectl -n "$VELERO_NS" get "restore.velero.io/$1" \
    -o jsonpath='  phase={.status.phase} itemsRestored={.status.progress.itemsRestored}/{.status.progress.totalItems} warnings={.status.warnings} errors={.status.errors}{"\n"}  failureReason={.status.failureReason}{"\n"}' >&2 2>/dev/null || true
  printf '  PodVolumeRestores:\n' >&2
  kubectl -n "$VELERO_NS" get podvolumerestores.velero.io -l velero.io/restore-name="$1" \
    -o custom-columns=NAME:.metadata.name,POD:.spec.pod.name,VOLUME:.spec.volume,PHASE:.status.phase >&2 2>/dev/null || true
  printf '  PodVolumeBackups of the source backup:\n' >&2
  kubectl -n "$VELERO_NS" get podvolumebackups.velero.io -l velero.io/backup-name="$RESTORE_FROM" \
    -o custom-columns=NAME:.metadata.name,POD:.spec.pod.name,VOLUME:.spec.volume,PHASE:.status.phase,BYTES:.status.progress.totalBytes >&2 2>/dev/null || true
  stalled_pods "$1"
  restore_log_summary "$1"
}

# stalled_pods <restore> — the POD behind every PodVolumeRestore that has not
# reached a terminal phase, and the reason that pod is not running.
#
# A Velero Restore stays InProgress until EVERY PodVolumeRestore it created
# reaches a terminal phase, and the node-agent starts a PodVolumeRestore only
# once the kubelet has mounted the volume of the pod it names. So a pod that
# never runs holds the whole Restore open until the deadline, and the pod is
# the only thing that explains it. MEASURED 2026-09-03 (deploy#1740), runs
# 33705234668, 33705244337, 33705253441, 33706634985 and 33720474418: five
# identical failures, `restore <name>-builtins did not finish within 2400s`,
# with seven PodVolumeRestores holding no phase at all and nothing in the run
# naming the pods they belonged to.
stalled_pods() {
  local pvr pod ns
  printf '  pods behind the PodVolumeRestores that never started:\n' >&2
  kubectl -n "$VELERO_NS" get podvolumerestores.velero.io -l velero.io/restore-name="$1" \
    -o 'jsonpath={range .items[?(@.status.phase=="")]}{.metadata.name}{" "}{.spec.pod.namespace}{" "}{.spec.pod.name}{"\n"}{end}' 2>/dev/null \
    > "$WORK/stalled.txt" || true
  kubectl -n "$VELERO_NS" get podvolumerestores.velero.io -l velero.io/restore-name="$1" \
    -o 'jsonpath={range .items[?(@.status.phase=="InProgress")]}{.metadata.name}{" "}{.spec.pod.namespace}{" "}{.spec.pod.name}{"\n"}{end}' 2>/dev/null \
    >> "$WORK/stalled.txt" || true
  if ! grep -q . "$WORK/stalled.txt" 2>/dev/null; then
    printf '    none: every PodVolumeRestore reached a terminal phase\n' >&2
    return 0
  fi
  while read -r pvr ns pod; do
    [ -n "$pod" ] || continue
    printf '    %s -> %s/%s: %s\n' "$pvr" "$ns" "$pod" \
      "$(kubectl -n "$ns" get "pod/$pod" \
          -o jsonpath='phase={.status.phase} {range .status.containerStatuses[*]}{.name}={.state.waiting.reason}{.state.waiting.message}{" "}{end}{range .status.initContainerStatuses[*]}init/{.name}={.state.waiting.reason}{.state.waiting.message}{" "}{end}' \
          2>&1 | tr -d '\n' | cut -c1-300)" >&2
  done < "$WORK/stalled.txt"
}

# restore_log_summary <restore> — WHY the restore did what it did, in the
# words Velero recorded.
#
# The counts above say a restore skipped an item and never say which item or
# why. Velero writes that to the restore's OWN log, stored beside the restore
# in the durable bucket, and never to the server pod's stdout, so
# `kubectl logs deploy/velero` does not hold it either. MEASURED 2026-09-02
# (deploy#1740): two dispatches of the blocker 3 loop stopped on a secret
# store restore that reported `itemsRestored=4/4 warnings=1` and moved no
# volume data, and neither the counts nor the server log named the one
# warning that explained it.
#
# The log comes back through a DownloadRequest: Velero signs a URL for the
# object, so this needs no bucket credential and no velero CLI, and it works
# the same on kind's MinIO and on S3. WARNINGS are printed as well as errors,
# because a restore that skips an item warns and stays Completed.
#
# This function only ever prints. Every failure inside it is swallowed: it
# runs on the way to an abort and must not replace the real message with one
# about diagnostics.
restore_log_summary() {
  local name="$1" dr="recreate-explain-${1}" url="" deadline
  kubectl apply -f - >/dev/null 2>&1 <<YAML
apiVersion: velero.io/v1
kind: DownloadRequest
metadata:
  name: ${dr}
  namespace: ${VELERO_NS}
spec:
  target:
    kind: RestoreLog
    name: ${name}
YAML
  deadline=$(( $(date +%s) + 60 ))
  while :; do
    url="$(kubectl -n "$VELERO_NS" get "downloadrequest.velero.io/${dr}" -o jsonpath='{.status.downloadURL}' 2>/dev/null)" || url=""
    [ -n "$url" ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '  (Velero signed no download URL for the log of restore %s within 60s)\n' "$name" >&2
      return 0
    fi
    sleep 2
  done
  if ! curl -fsSL "$url" -o "$WORK/restore-log.gz" 2>/dev/null; then
    printf '  (the signed URL for the log of restore %s did not answer)\n' "$name" >&2
    return 0
  fi
  if ! python3 -c 'import gzip,sys;sys.stdout.write(gzip.open(sys.stdin.buffer,"rt",errors="replace").read())' \
       < "$WORK/restore-log.gz" > "$WORK/restore.log" 2>/dev/null; then
    printf '  (the log of restore %s came back unreadable)\n' "$name" >&2
    return 0
  fi
  # Everything that makes two reports of the same fault look different goes
  # before the grouping, the same way scripts/teardown-kind.sh does it for a
  # backup: the timestamp, the log source, the restore name and the namespace.
  # The errors first, then the warnings, each group most frequent first.
  # One sorted list of both hid ten errors that came once each behind 40
  # warnings that also came once (drill run 39189378263): the errors are
  # what made the Restore PartiallyFailed.
  local level grouped
  for level in error warning; do
    grouped="$WORK/restore-${level}s.txt"
    grep -E "level=${level}" "$WORK/restore.log" \
      | sed -e 's/^time="[^"]*" //' \
            -e 's/ logSource="[^"]*"//' -e 's/ restore=[^ ]*//' \
            -e 's/ error\.function="[^"]*"//' \
            -e 's/ namespace=[^ ]*//' \
            -e 's/ in the namespace \\"[^\\]*\\"//' \
      | sort | uniq -c | sort -rn > "$grouped" || true
    printf '  %s distinct %ss in the restore log, most frequent first, at most 40 shown:\n' \
      "$(wc -l < "$grouped")" "$level" >&2
    head -40 "$grouped" >&2
  done
  kubectl -n "$VELERO_NS" delete "downloadrequest.velero.io/${dr}" --ignore-not-found >/dev/null 2>&1 || true
}

# wait_restore <name> <bound-seconds> — poll one Restore to a terminal phase and demand
# Completed. PartiallyFailed is a FAILURE here for the same reason it is one
# in a preserve teardown (deploy#1738): it means items the spec asked for are
# missing. A half-restored environment that reports success is the worst
# outcome this verb has.
#
# EVERY exit from this function that is not Completed prints restore_diag
# first, the DEADLINE included. A restore that never reaches a terminal phase
# is the one failure that cannot be read off the Restore's own phase, so it is
# the one that needs the counts and the stalled pods most.
wait_restore() {
  local name="$1" bound phase="" deadline
  bound="$(restore_bound "$2")"
  deadline=$(( $(date +%s) + bound ))
  while :; do
    phase="$(kubectl -n "$VELERO_NS" get "restore.velero.io/$name" -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    case "$phase" in
      Completed) printf '  ✓ restore %s Completed\n' "$name"; return 0 ;;
      PartiallyFailed|Failed|FailedValidation)
        restore_diag "$name"
        die "restore ${name} finished ${phase}, not Completed. This environment is HALF restored: nothing here falls back to an empty bringup. Fix the cause and run the recreate again with the same RESTORE_FROM" ;;
    esac
    printf '  restore %s: %s          \r' "$name" "${phase:-<none>}"
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '\n' >&2
      restore_diag "$name"
      die "restore ${name} did not finish within ${bound}s (last phase: ${phase:-<none>})"
    fi
    sleep 10
  done
}

# volume_restores_completed <restore-name> — how many PodVolumeRestores of
# that restore finished. Object JSON rides in the backup tarball; VOLUME data
# rides in the kopia repository and arrives only through these. A restore
# that reports Completed with zero of them moved no data at all.
volume_restores_completed() {
  kubectl -n "$VELERO_NS" get podvolumerestores.velero.io \
    -l velero.io/restore-name="$1" \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -c '^Completed$' || true
}

# wait_backup_synced — the Backup CR for the named backup exists in this
# cluster. Velero learns about a backup by SYNCING the bucket into a Backup
# object on its own clock, and a Restore that names a backup the server has
# not synced yet is refused as FailedValidation with "backup not found". The
# bucket has been proven to hold it (stage 0b), so this is a wait and not a
# check.
wait_backup_synced() {
  local bound deadline
  bound="$(restore_bound "$RESTORE_SYNC_TIMEOUT")"
  deadline=$(( $(date +%s) + bound ))
  while ! kubectl -n "$VELERO_NS" get "backup.velero.io/$RESTORE_FROM" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] \
      || die "Velero never synced backup ${RESTORE_FROM} from the durable bucket within ${bound}s. The object is there (stage 0b proved it), so the BackupStorageLocation is what to look at: $(kubectl -n "$VELERO_NS" get backupstoragelocation.velero.io/default -o jsonpath='{.status.phase}: {.status.message}' 2>/dev/null)"
    printf '  waiting for Velero to sync backup %s from the bucket          \r' "$RESTORE_FROM"
    sleep 10
  done
  printf '  ✓ Velero synced backup %s from the bucket\n' "$RESTORE_FROM"
}

# ---------------------------------------------------------------------------
# Restore 1 of 3 — THE SECRET STORE, before anything reads a Secret.
#
# OpenBao's file backend is a volume in the `gibson` namespace, so it rides in
# the same backup as everything else and comes back through the same
# mechanism. It is restored BEFORE the umbrella Application exists, which is
# what makes it deterministic: no StatefulSet is competing for the pod, and
# the claim is on disk before anything mounts it.
#
# Only four kinds, and only the objects the store's own pod needs to reach
# the point where the node-agent writes into its volume: the ServiceAccount
# (a pod naming an absent one is refused at admission), the config ConfigMap,
# the claim, and the pod itself. The StatefulSet is deliberately NOT restored
# — it would adopt the pod mid-restore, roll it for a controller-revision
# mismatch, and take the volume restore down with it. Argo brings the
# StatefulSet, and it adopts the restored claim.
#
# The seal is already in place: stage 1 wrote the bringup keyring into this
# namespace, so the restored store unseals from the keyring with no human
# step (ADR-0083). Without the keyring the archive is ciphertext, which is
# what the exit test's failing fixture measures.
# ---------------------------------------------------------------------------
#
# THE TLS SECRET IS NOT HERE YET, AND THE POD MUST STILL START. The OpenBao pod
# mounts Secret gibson-openbao-tls in two volumes, tls and openbao-ca. A
# Certificate of the gibson Application issues it (charts#540), and
# cert-manager itself is in that Application too. The backup carries no
# Secret. So at this step the Secret cannot exist, the kubelet holds the pod
# in ContainerCreating, Velero's restore-wait init container never runs, and
# the PodVolumeRestore never starts: restore 1 timed out at RESTORE_TIMEOUT.
#
# The restore therefore patches the RESTORED POD only, through a Velero
# resource modifier: those two volumes become optional, so the pod mounts
# them empty and the node-agent writes the store's bytes. The chart is not
# changed, and a normal render keeps both volumes required
# (scripts/check-env-renders-at-pin.py checks the names and the flag).
# OpenBao still fails closed: its listener is TLS only, so the openbao
# container cannot start until the gibson Application issues the
# certificate. Then the kubelet fills the volume, and the StatefulSet that
# Argo brings adopts the pod or replaces it with the chart's own spec.
OPENBAO_TLS_SECRET="gibson-openbao-tls"
OPENBAO_TLS_VOLUMES="tls openbao-ca"
OPENBAO_RESTORE_MODIFIER="restore-openbao-tls-optional"

# openbao_tls_modifier — the ConfigMap that holds the resource modifier.
openbao_tls_modifier() {
  local vols="" v
  for v in $OPENBAO_TLS_VOLUMES; do
    vols="${vols:+$vols,}{\"name\":\"${v}\",\"secret\":{\"secretName\":\"${OPENBAO_TLS_SECRET}\",\"optional\":true}}"
  done
  cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${OPENBAO_RESTORE_MODIFIER}
  namespace: ${VELERO_NS}
data:
  modifier.yaml: |
    version: v1
    resourceModifierRules:
      - conditions:
          groupResource: pods
          namespaces: ["${NS}"]
          resourceNameRegex: "^gibson-openbao-[0-9]+$"
        strategicPatches:
          - patchData: '{"spec":{"volumes":[${vols}]}}'
YAML
}

restore_secret_store() {
  local name="${RESTORE_FROM}-openbao"
  log "restore 1/3: the secret store, from backup ${RESTORE_FROM}"
  wait_backup_synced
  openbao_tls_modifier | kubectl apply -f - >/dev/null \
    || die "could not create the resource modifier ${VELERO_NS}/${OPENBAO_RESTORE_MODIFIER}. Without it the restored OpenBao pod waits on Secret ${OPENBAO_TLS_SECRET}, which no object in the cluster can issue yet"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${name}
  namespace: ${VELERO_NS}
spec:
  backupName: ${RESTORE_FROM}
  includedNamespaces: ["${NS}"]
  # The two TLS volumes of the restored pod become optional (see above).
  resourceModifier:
    kind: ConfigMap
    name: ${OPENBAO_RESTORE_MODIFIER}
  # The LEGACY filter pair, on purpose. A Velero Restore has no scoped
  # filters: includedNamespaceScopedResources and its three siblings exist on
  # a Backup only (helm/gibson-velero/charts/velero-*.tgz, crds/restores.yaml).
  # The Restore CRD prunes a field it does not declare SILENTLY, so a scoped
  # filter here would not be rejected — it would simply not filter, and this
  # restore would bring back the whole namespace. tests/harness/restore.bats
  # checks every field of every Restore this script builds against that CRD.
  #
  # The kind persistentvolumes IS in this list, and it is what makes the restore move
  # data at all. Velero refuses to create a PodVolumeRestore when the restore's
  # resource filter excludes persistentvolumeclaims OR persistentvolumes
  # (pkg/restore/restore.go, "do not create podvolumerestore when current
  # restore excludes pv/pvc"). Without the line, this restore reported
  # Completed, itemsRestored 4 of 4, with ZERO PodVolumeRestores and not one
  # warning about it — measured on kind 2026-09-02 (deploy#1740), on three
  # dispatches of the blocker 3 loop. It is a gate on the FILTER, not a request
  # to restore a PV, and the line below is what keeps the PV itself out.
  includedResources:
    - serviceaccounts
    - configmaps
    - persistentvolumeclaims
    - persistentvolumes
    - pods
  # No cluster-scoped item. The PersistentVolume behind the claim is not
  # wanted: Velero clears the claim's binding so it is provisioned fresh, and
  # the node-agent writes the store's bytes into the new volume. This filter is
  # applied per item, so it keeps every PV out of the restore while the
  # resource list above still satisfies the pod-volume gate.
  labelSelector:
    matchLabels:
      app.kubernetes.io/component: openbao
  existingResourcePolicy: none
YAML
  wait_restore "$name" "$RESTORE_STORE_TIMEOUT"
  local moved
  moved="$(volume_restores_completed "$name")"
  if [ "${moved:-0}" -lt 1 ]; then
    restore_diag "$name"
  fi
  [ "${moved:-0}" -ge 1 ] \
    || die "the secret store restore reported Completed and moved NO volume data (0 PodVolumeRestores).
    Completed is NOT proof that data came back: a Restore whose labelSelector matches no
    item finishes Completed in seconds with no warning and no error (deploy#1738). The
    store's file backend is a volume, so this restore would leave the cluster with an EMPTY
    OpenBao wearing the name of a restored one. Three causes, all visible above: the
    selector matched nothing (itemsRestored 0); the restore's includedResources left out
    persistentvolumes or persistentvolumeclaims, which makes Velero create no pod volume
    restore at all and say nothing (deploy#1740); or the volume was a hostPath
    PersistentVolume, which the Velero node-agent skips — the default StorageClass must
    carry the annotation defaultVolumeType=local, which stage 1 sets."
  printf '  ✓ the secret store volume is back (%s PodVolumeRestore completed)\n' "$moved"
}

# wait_eso — every Secret is out of the restored store before ANY other
# restore runs.
#
# This is a gate, not a courtesy. Velero's backups never contain a Secret
# (the RBAC has no verb on them, CONTEXT.md § Velero backup), so every
# restored pod takes its Secrets from External Secrets. A tenant Neo4j pod
# restored before its auth Secret exists cannot mount it, sits in
# CreateContainerConfigError, and its volume restore never completes — a
# half-restored tenant that the Restore reports as a success.
# EVERY POLL IN THIS FILE ENDS WITH AN OR THAT EMPTIES THE VARIABLE, and that
# is not decoration. The caller runs under set -e, and an assignment from a
# command substitution carries that command's exit status. An object that is
# NOT THERE YET, the normal state of a poll, then kills the whole verb,
# silently, with the reason sent to /dev/null. MEASURED 2026-09-03 (deploy#1740), run
# 33699848618: the recreate printed the line below and exited, with no error
# and no diagnosis, because the ClusterSecretStore did not exist one second
# after the Application was applied. A poll must read "not yet" as not yet;
# the deadline below is what turns a wait that never ends into a loud failure.
wait_eso() {
  log "restore: waiting for External Secrets to sync every Secret out of the restored store"
  local bound deadline total notready store
  bound="$(restore_bound "$RESTORE_ESO_TIMEOUT")"
  deadline=$(( $(date +%s) + bound ))
  while :; do
    store="$(kubectl get clustersecretstore gibson-secrets \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || store=""
    if [ "$store" = True ]; then
      kubectl get externalsecrets --all-namespaces \
        -o 'jsonpath={range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null > "$WORK/es.txt" || true
      total="$(grep -c . "$WORK/es.txt" || true)"
      notready="$(awk '$3!="True"' "$WORK/es.txt" | wc -l)"
      if [ "${total:-0}" -gt 0 ] && [ "$notready" -eq 0 ]; then
        printf '  ✓ ClusterSecretStore gibson-secrets Ready, all %s ExternalSecrets synced\n' "$total"
        return 0
      fi
      printf '  ExternalSecrets: %s of %s synced          \r' "$(( ${total:-0} - notready ))" "${total:-0}"
    else
      printf '  ClusterSecretStore gibson-secrets: Ready=%s          \r' "${store:-<none>}"
    fi
    [ "$(date +%s)" -lt "$deadline" ] || {
      printf '\n' >&2
      awk '$3!="True"{print "    NOT SYNCED: "$1"/"$2" Ready="($3==""?"<none>":$3)}' "$WORK/es.txt" >&2 2>/dev/null || true
      die "External Secrets did not sync within ${bound}s (ClusterSecretStore Ready=${store:-<none>}).
    The Velero restore below is NOT run: it would land pods whose Secrets do not exist yet,
    and they would sit in CreateContainerConfigError with their volumes never restored.
    A loud stop here beats a half-restored tenant that reports success."
    }
    sleep 10
  done
}

# ---------------------------------------------------------------------------
# Restores 2 and 3 of 3 — the built-ins, then the tenant records.
#
# The order is the one the tenant operator forces (CONTEXT.md § Velero
# backup): it ADOPTS a restored Neo4j claim rather than re-initialising it
# (gibson operators/tenant/internal/dataplane/neo4j.go, idempotent create).
# So the namespaces and the claims with the graph on them have to be on disk
# BEFORE the `Tenant` CRs arrive and the operator starts reconciling them.
#
# Restore 2 takes the DATA and the objects that carry it: the namespaces,
# the claims and volumes, the pods Velero moves volume data through, the
# StatefulSets that own those pods, and the ServiceAccounts and ConfigMaps
# a pod needs to be admitted (the shape restore 1 already uses). Restore 3
# takes the same backup and asks for the `Tenant` CRs and nothing else.
#
# It used to take the backup whole except the `Tenant` CRs, on the theory
# that anything Argo had already created would be skipped. Measured
# 2026-09-08 (blocker 3 loop #8), that theory lost on both sides of the
# race: Velero created the gibson-envoy Service first, with the OLD
# clusterIP, and Argo could never apply the chart's pinned one ("may not
# change once set"); and 161 of the restore's items were Roles,
# RoleBindings, ClusterRoles, ControllerRevisions and EndpointSlices that
# Velero's ServiceAccount may not create, so the Restore finished
# PartiallyFailed and the verb refused it. Every one of those objects is
# desired state the chart or an operator owns. The only thing a restore
# has to bring is what is NOT in the chart, so that is all it asks for.
#
# THE RELEASE NAMESPACE IS ARGO'S, NOT THE DATA RESTORE'S. Velero brings
# volume data back through a pod, so a store whose pod Argo has already
# created keeps the empty volume it was given. This file once said that the
# wave graph of the umbrella keeps Argo from those pods until the restore is
# done. On an EC2 restore that is false: wait_eso takes about nine minutes,
# and in drill run 39189378263 Argo had made gibson-gibson-workloads-0,
# gibson-redis-stack-0 and gibson-server-0 before restore 2. Velero found
# them and moved no data. When Argo is later than Velero, the identity
# admission policies of the chart refuse a pod or a StatefulSet that
# velero-server creates for the daemon or OpenBao. So the pods Restore and
# the statefulsets Restore exclude the release namespace: the result does
# not depend on the race. OpenBao is restored by name above, before the
# umbrella Application exists. The other volumes of the release namespace
# are not restored today (hosted#792).
# ---------------------------------------------------------------------------
# The PriorityClasses every restored pod names. They are chart-owned and
# cluster-scoped, and the chart applies them at sync wave -20 (charts:
# gibson-operators/templates/priority-classes.yaml and
# gibson-workloads/templates/operations/tenant-neo4j-resource-quota.yaml), so
# they exist long before wait_eso returns. A pod that names a class the
# API server does not have is refused at admission ("no PriorityClass with
# name gibson-platform-critical was found"), and the data behind it never
# moves; on 2026-09-08 that was the daemon and both Redis StatefulSet pods
# (blocker 3 loop #9). The Restore below does NOT carry the classes itself:
# Velero's scoped role cannot create them (measured on hosted run
# 34242900639, PartiallyFailed), and a class from an old backup with a
# different value would block Argo's next apply, since the value is
# immutable. So this is a wait, with a loud stop.
RESTORE_PRIORITY_CLASSES="gibson-platform gibson-platform-critical tenant-neo4j"

wait_priority_classes() {
  local bound deadline missing pc
  bound="$(restore_bound "$RESTORE_CLASSES_TIMEOUT")"
  deadline=$(( $(date +%s) + bound ))
  while :; do
    missing=""
    for pc in $RESTORE_PRIORITY_CLASSES; do
      kubectl get priorityclass "$pc" -o name >/dev/null 2>&1 || missing="${missing:+$missing }$pc"
    done
    [ -z "$missing" ] && { printf '  ✓ PriorityClasses in place: %s\n' "$RESTORE_PRIORITY_CLASSES"; return 0; }
    printf '  waiting for the chart to apply PriorityClass %s          \r' "$missing"
    [ "$(date +%s)" -lt "$deadline" ] || {
      printf '\n' >&2
      die "PriorityClass $missing did not appear within ${bound}s.
    The Velero restore below is NOT run: every pod that names one of these classes would be
    refused at admission and its volume would never move. The classes are chart-owned, at
    sync wave -20 in the umbrella. Check the gibson Application and the CRDs it waits on."
    }
    sleep 5
  done
}

# Every Tenant and TenantMember the restore below creates goes through the
# tenant-operator's admission webhooks (validate-tenant, mutate-owner-ref).
# Velero applies them once and records what the API server said; it never
# retries. On hosted run 34391927116 (2026-09-09) the operator was rolling
# at that moment (a new image, still pulling), the Service had no ready
# endpoint, every item failed "failed calling webhook: connect: connection
# refused", and the Restore ended PartiallyFailed with the tenants absent.
# So: wait for the Deployment to be fully rolled out AND for the webhook
# Service to have a ready endpoint, with the same deadline and the same
# loud stop as every other wait in this file.
TENANT_OPERATOR_DEPLOY="${TENANT_OPERATOR_DEPLOY:-gibson-tenant-operator}"
TENANT_OPERATOR_WEBHOOK_SVC="${TENANT_OPERATOR_WEBHOOK_SVC:-gibson-tenant-operator-webhook}"

wait_tenant_webhook() {
  local bound deadline rollout ready
  bound="$(restore_bound "$RESTORE_WEBHOOK_TIMEOUT")"
  deadline=$(( $(date +%s) + bound ))
  while :; do
    rollout="$(kubectl -n "$NS" get deploy "$TENANT_OPERATOR_DEPLOY" \
      -o jsonpath='{.spec.replicas}/{.status.updatedReplicas}/{.status.availableReplicas}' 2>/dev/null)" || rollout=""
    ready="$(kubectl -n "$NS" get endpoints "$TENANT_OPERATOR_WEBHOOK_SVC" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" || ready=""
    case "$rollout" in
      */*/*)
        local want="${rollout%%/*}" rest="${rollout#*/}" updated avail
        updated="${rest%%/*}"; avail="${rest#*/}"
        if [ -n "$want" ] && [ "$updated" = "$want" ] && [ "$avail" = "$want" ] && [ -n "$ready" ]; then
          printf '  ✓ tenant-operator webhook ready: %s/%s replicas rolled out, endpoints %s\n' "$avail" "$want" "$ready"
          return 0
        fi ;;
    esac
    printf '  waiting for the tenant-operator webhook: deploy=%s endpoints=%s          \r' "${rollout:-<none>}" "${ready:-<none>}"
    [ "$(date +%s)" -lt "$deadline" ] || {
      printf '\n' >&2
      die "the tenant-operator webhook did not become ready within ${bound}s (deploy ${TENANT_OPERATOR_DEPLOY} replicas/updated/available=${rollout:-<none>}, endpoints of ${TENANT_OPERATOR_WEBHOOK_SVC}=${ready:-<none>}).
    The tenant records restore is NOT run: every Tenant and TenantMember it creates is admitted by
    that webhook, Velero applies each item once, and a refused call leaves the tenants absent
    with the Restore PartiallyFailed."
    }
    sleep 5
  done
}

# THE TENANT NAMESPACE LABEL IS THE OPERATOR'S TO SET (hosted row 11). The
# chart's ValidatingAdmissionPolicy gibson-tenant-namespace-label (charts#527)
# lets only the tenant-operator set gibson.zeroroot.ai/managed-by on a
# Namespace. A backed-up tenant namespace carries that label. Velero creates
# the namespace of a restored item from the backup tarball as
# velero/velero-server, so the policy refuses it, and restore 2 ends
# PartiallyFailed (drill run 39180602162).
#
# A resource modifier cannot drop the label: Velero creates a namespace in
# EnsureNamespaceExistsAndIsReady from the tarball copy, and it applies
# resource modifiers only in restoreItem (velero v1.18.1
# pkg/restore/restore.go). The modifier this file had never ran.
#
# So the restore creates the namespace tenant-<name> of each Tenant of the
# backup first, without the managed-by label. Velero finds it and does not
# create it, so no label or annotation of the backup copy is restored on it.
# The create sets the two labels that matter before the operator runs: the
# tenant label and the restricted Pod Security standard, so the pods of
# restore 2 are admitted under it (gibson#767). The operator adopts the
# namespace on its first reconcile of the restored Tenant: ensureNamespace
# merges its labels and annotations into an existing namespace on every pass
# (gibson#265), the managed-by label included. wait_tenant_namespace_labels
# proves that it did, for each namespace this step created. The only reader
# of the label is the belief trainer ingress policy, which tolerates the gap.
#
# Only tenant-<name> of a Tenant: the backup also holds tenant-backup-canary
# (no Tenant, no operator) and tenant-<name>-plugins (the catalog plugin
# controller refuses a namespace that lacks its own labels, and that
# namespace does not carry the policed label, so Velero creates it as before).
TENANT_NS_LABEL="gibson.zeroroot.ai/managed-by"
TENANT_NS_LABEL_VALUE="tenant-operator"
TENANT_NS_RESTORED=""

# backup_list_section HEADER — the "    - <item>" lines under "  HEADER:" in
# a resource list on stdin, up to the next header.
backup_list_section() {
  awk -v h="  $1:" '
    /^  [^ ].*:$/ { in_s = ($0 == h); next }
    in_s && /^    - / { print $2 }'
}

# backup_resource_list — the "Resource List" of the backup, from the velero
# binary of a Running server pod, read from the backup in object storage.
# Refused unless it lists the namespace ${NS}: a list that velero could not
# read prints one error line under the header, and an empty list would make
# the label wait pass with nothing checked.
backup_resource_list() {
  local pod out
  pod="$(kubectl -n "$VELERO_NS" get pods -l name=velero --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}')" && [ -n "$pod" ] \
    || die "no Running Velero server pod in ${VELERO_NS}, so the Tenants of ${RESTORE_FROM} cannot be read"
  out="$(kubectl -n "$VELERO_NS" exec "pod/${pod}" -c velero -- \
          /velero backup describe "$RESTORE_FROM" --details -n "$VELERO_NS")" \
    || die "velero backup describe ${RESTORE_FROM} failed, so the Tenants of the backup are not known"
  printf '%s\n' "$out" | backup_list_section "v1/Namespace" | grep -qx "$NS" \
    || die "the resource list of ${RESTORE_FROM} does not list the namespace ${NS}, so it cannot be read: $(printf '%s\n' "$out" | grep -A2 '^Resource List:' | tr '\n' ' ' | cut -c1-300)"
  printf '%s\n' "$out"
}

# precreate_tenant_namespaces — create tenant-<name> for each Tenant of the
# backup that the backup holds a namespace for, before restore 2. A
# namespace that exists is left as it is, and it is still waited on.
precreate_tenant_namespaces() {
  local list t ns
  list="$(backup_resource_list)" || exit 1
  for t in $(printf '%s\n' "$list" | backup_list_section "gibson.zeroroot.ai/v1alpha1/Tenant"); do
    ns="tenant-${t}"
    printf '%s\n' "$list" | backup_list_section "v1/Namespace" | grep -qx "$ns" || continue
    if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
      kubectl apply -f - >/dev/null <<YAML || die "could not create the tenant namespace ${ns} ahead of restore 2"
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    gibson.zeroroot.ai/tenant: "${t}"
    pod-security.kubernetes.io/enforce: restricted
YAML
    fi
    TENANT_NS_RESTORED="${TENANT_NS_RESTORED:+${TENANT_NS_RESTORED} }${ns}"
  done
  printf '  ✓ tenant namespaces of the backup, created without the managed-by label: %s\n' "${TENANT_NS_RESTORED:-none}"
}

# wait_tenant_namespace_labels — each tenant namespace that the restore
# created carries the label, set by the operator. A namespace without it has
# no reconciled Tenant, and its belief trainer could not reach the daemon.
wait_tenant_namespace_labels() {
  local bound deadline missing ns v
  bound="$(restore_bound "$RESTORE_LABELS_TIMEOUT")"
  deadline=$(( $(date +%s) + bound ))
  while :; do
    missing=""
    for ns in $TENANT_NS_RESTORED; do
      v="$(kubectl get namespace "$ns" -o jsonpath="{.metadata.labels.${TENANT_NS_LABEL//./\\.}}" 2>/dev/null)" || v=""
      [ "$v" = "$TENANT_NS_LABEL_VALUE" ] || missing="${missing:+${missing} }${ns}"
    done
    if [ -z "$missing" ]; then
      printf '  ✓ the tenant-operator set %s on every restored tenant namespace\n' "$TENANT_NS_LABEL"
      return 0
    fi
    printf '  waiting for the tenant-operator to label: %s          \r' "$missing"
    [ "$(date +%s)" -lt "$deadline" ] || {
      printf '\n' >&2
      die "the tenant-operator did not set ${TENANT_NS_LABEL}=${TENANT_NS_LABEL_VALUE} on ${missing} within ${bound}s. The restore creates each tenant namespace without that label (the admission policy lets only the operator set it), and the operator sets it when it reconciles the restored Tenant. A namespace still without it has no reconciled Tenant"
    }
    sleep 10
  done
}

# tenant_volumes_restored <restore> — each volume of a tenant namespace that
# the backup holds bytes for has a Completed PodVolumeRestore in <restore>.
# The pods of the gibson namespace are left out: Argo has made them before
# the restore, so Velero finds them and moves no data, by design today. A
# tenant pod that a StatefulSet made first is the case this catches: the
# Restore then ends Completed, with the graph on an empty volume.
tenant_volumes_restored() {
  local want got missing
  want="$(kubectl -n "$VELERO_NS" get podvolumebackups.velero.io -l velero.io/backup-name="$RESTORE_FROM" \
    -o jsonpath='{range .items[*]}{.spec.pod.namespace}/{.spec.pod.name}/{.spec.volume} {.status.progress.totalBytes}{"\n"}{end}')" \
    || die "could not list the PodVolumeBackups of ${RESTORE_FROM}"
  got="$(kubectl -n "$VELERO_NS" get podvolumerestores.velero.io -l velero.io/restore-name="$1" \
    -o jsonpath='{range .items[*]}{.spec.pod.namespace}/{.spec.pod.name}/{.spec.volume} {.status.phase}{"\n"}{end}')" \
    || die "could not list the PodVolumeRestores of ${1}"
  missing="$(printf '%s\n' "$want" | awk '$1 ~ /^tenant-/ && $2 + 0 > 0 { print $1 }' | while read -r v; do
    printf '%s\n' "$got" | grep -qxF "${v} Completed" || printf '%s ' "$v"
  done)"
  if [ -n "$missing" ]; then
    restore_diag "$1"
    die "restore ${1} moved no data for: ${missing}The backup holds bytes for each one, and no PodVolumeRestore of this Restore completed for it. The pod was there before the Restore (a StatefulSet restored first makes it at once on an empty volume), or the selector left it out"
  fi
}

restore_data() {
  local builtins="${RESTORE_FROM}-builtins" pods="${RESTORE_FROM}-pods" statefulsets="${RESTORE_FROM}-statefulsets"
  local tenants="${RESTORE_FROM}-tenants" moved
  wait_priority_classes
  log "restore 2/3: namespaces, claims and volumes, from backup ${RESTORE_FROM}"
  precreate_tenant_namespaces
  kubectl apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${builtins}
  namespace: ${VELERO_NS}
spec:
  backupName: ${RESTORE_FROM}
  existingResourcePolicy: none
  # The tenant namespaces exist already, with no label (see above).
  includedResources:
    - namespaces
    # No priorityclasses: see wait_priority_classes above. Everything else a
    # restored pod is admitted against (its ServiceAccount, its ConfigMaps)
    # is namespaced and chart-owned too, and Velero restores it here because
    # Argo has not reached the wave that creates it yet; existingResourcePolicy
    # none leaves Argo's later apply to find it equal.
    - serviceaccounts
    - configmaps
    - persistentvolumeclaims
    - persistentvolumes
YAML
  wait_restore "$builtins" "$RESTORE_DATA_TIMEOUT"

  # THE PODS THAT CARRY DATA, AND NO OTHER POD (drill run 39189378263). The
  # backup holds each pod of the release, the pods of the Deployments too.
  # Velero created those as velero-server, and the identity admission
  # policies of the chart (gibson-platform-identity-pods and the SaaS ones)
  # refused each one: a pod with a platform identity comes only from its
  # controller. Ten such refusals made restore 2 PartiallyFailed. A pod of a
  # Deployment holds no volume data, and its ReplicaSet makes a new one. So
  # the pods restore takes only the pods of a StatefulSet (Kubernetes sets
  # statefulset.kubernetes.io/pod-name on each) and the backup canary. A
  # label selector applies to each resource of a Restore, so the pods are a
  # Restore of their own, after the claims they mount. It still names both
  # volume kinds: Velero makes a PodVolumeRestore only when the kinds are
  # included (a check on the kind, not on the labels, velero v1.18.1
  # restore.go), and the selector leaves the claims out, which restore 2 made.
  kubectl apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${pods}
  namespace: ${VELERO_NS}
spec:
  backupName: ${RESTORE_FROM}
  existingResourcePolicy: none
  # Not the release namespace: Argo makes its workloads (see above).
  excludedNamespaces:
    - ${NS}
  includedResources:
    - pods
    - persistentvolumeclaims
    - persistentvolumes
  orLabelSelectors:
    - matchExpressions:
        - key: statefulset.kubernetes.io/pod-name
          operator: Exists
    - matchExpressions:
        - key: gibson.zeroroot.ai/backup-canary
          operator: Exists
YAML
  wait_restore "$pods" "$RESTORE_DATA_TIMEOUT"
  moved="$(volume_restores_completed "$pods")"
  tenant_volumes_restored "$pods"
  printf '  ✓ %s volume(s) restored\n' "${moved:-0}"

  # THE STATEFULSETS COME AFTER THEIR PODS. A StatefulSet restored first
  # makes its pod at once, the pod binds the restored claim to a new empty
  # volume, and the pods Restore then finds the pod there and moves no data
  # (review of hosted#790). In one Restore, Velero restores pods before
  # statefulsets. In two, the order is the order of the Restores.
  kubectl apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${statefulsets}
  namespace: ${VELERO_NS}
spec:
  backupName: ${RESTORE_FROM}
  existingResourcePolicy: none
  # Not the release namespace: Argo makes its workloads (see above).
  excludedNamespaces:
    - ${NS}
  includedResources:
    - statefulsets
YAML
  wait_restore "$statefulsets" "$RESTORE_STORE_TIMEOUT"

  wait_tenant_webhook
  log "restore 3/3: the tenant records, so the operator adopts what is already on disk"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${tenants}
  namespace: ${VELERO_NS}
spec:
  backupName: ${RESTORE_FROM}
  existingResourcePolicy: none
  includedResources:
    - tenants.gibson.zeroroot.ai
    # The membership records too. A TenantMember is data (who belongs to
    # the tenant, accepted by whom), not something the operator derives
    # from the Tenant: the pending-provisioning reconcile creates the
    # founding member ONCE, on a Tenant it sees for the first time, and a
    # restored Tenant comes back with its status already Ready. Blocker 3
    # loop #19 (2026-09-09): the whole restore completed, then the
    # first-admin hook crashlooped on "create founding TenantMember
    # tenant-primary/...: forbidden", and the sync never closed.
    - tenantmembers.gibson.zeroroot.ai
  includeClusterResources: true
YAML
  wait_restore "$tenants" "$RESTORE_TENANTS_TIMEOUT"
  printf '  ✓ tenants now in the cluster: %s\n' \
    "$(kubectl get tenants.gibson.zeroroot.ai -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)"
  wait_tenant_namespace_labels
}
