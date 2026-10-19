#!/usr/bin/env bash
# preserve-backup.sh — the preserve half of a teardown, for EVERY substrate
# (ADR-0083, deploy#1738, deploy#1746).
#
# A preserve teardown is four steps before the destroy, and not one of them
# knows what the cluster runs on. They speak kubectl, the durable bucket and
# the keyring, so kind and EKS run the SAME code and there is no second
# implementation to drift (ADR-0027). What differs per substrate is the
# destroy, and the destroy stays in the caller.
#
# Source this file, then call `preserve_backup <backup-name>`. The caller
# supplies these before the call, and the function reads nothing else:
#
#   SUBSTRATE_ENV  path to substrate.env            (required)
#   REPO           repo root                        (required)
#   HERE           the scripts/ directory           (required)
#   MODE           preserve, for the log prefix     (required)
#   NS             release namespace                (default gibson)
#   VELERO_NS      velero namespace                 (default velero)
#   SCHEDULE       the shipped Velero Schedule      (default platform-hourly)
#   CNPG_CLUSTER   the CNPG Cluster CR              (default platform-postgres)
#   BACKUP_TIMEOUT / VERIFY_TIMEOUT  seconds        (defaults 1800 / 600)
#   QUEUE_TIMEOUT  seconds the Velero queue may hold the backup (default 3600)
#   VELERO_QUEUE_POLL  seconds between two reads of the backups in flight
#                  (default 20). A test seam: the tests set 0 or 1 so a
#                  queued backup does not cost a test 20 s. It is not a
#                  tuning value.
#   WORK           a scratch directory the caller cleans up (required)
#
# THE DEFAULTS LIVE HERE, AND ONLY HERE. Each caller runs under `set -u`, and
# each one used to set its own copy of them. teardown-ec2.sh set none, so
# `make teardown ENV=drill MODE=preserve` died on an unbound VELERO_NS at
# step 0, before it backed anything up. A caller may still set any of them
# before it sources this file. tests/harness/teardown-ec2.bats runs the EC2
# preserve teardown with none of them set.
#
# The caller also supplies `log` and `die`. `die` MUST exit non-zero without
# destroying anything: every failure below leaves the estate standing, names
# the step, and never falls back to a wipe (CONTEXT.md § Preserve teardown).
#
# The steps, in the order docs/bringup.md § A preserve teardown states:
#
#   0. backup-verify record — plant the canary that has to ride IN the backup,
#      and record a ciphertext sealed under the LIVE store's key. It runs
#      FIRST because it needs the keyring: a teardown that cannot read its
#      keyring must abort before it has touched Postgres, Velero or anything
#      else.
#   1. test/dr/cnpg-backup-and-wait.sh — a CNPG Backup CR, waited to
#      `completed`. This is a script step and NOT a Velero hook: Velero's only
#      hook mechanism is an exec inside a target pod, and "create a Backup CR
#      and watch its status" is an API interaction. A timeout ABORTS the
#      teardown (deploy#1735).
#   2. the Velero backup, built from the shipped `platform-hourly` Schedule
#      template — the same object `velero backup create --from-schedule`
#      builds, built with kubectl so no velero CLI is needed on a runner.
#      PartiallyFailed is a FAILURE, not a warning: it is what a spec that
#      asks for Secrets comes back as, and it means items are missing.
#   3. backup-verify verify — the canary decrypt gate.
#
# One name covers all three artifacts, so a later recreate finds every piece
# of a restore from the single string the teardown prints (ADR-0083).

NS="${NS:-gibson}"
VELERO_NS="${VELERO_NS:-velero}"
SCHEDULE="${SCHEDULE:-platform-hourly}"
CNPG_CLUSTER="${CNPG_CLUSTER:-platform-postgres}"
# The upper bounds of a cloud substrate, where the base backup and the Velero
# backup go to S3. They are bounds, not waits: kind finishes well inside them.
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-1800}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-600}"
# THE VELERO QUEUE. Velero 1.18 holds a Backup in Queued while a backup with
# overlapping namespaces runs, and every backup here covers gibson and
# tenant-*. Drill 38484872614 created its preserve backup at 00:02:45, behind
# the hourly that fired at 00:00:35. On a fresh cluster the first hourly
# makes a new kopia repository for each namespace, and it ran past 00:34. The
# preserve backup sat Queued for its whole 1800 s and the teardown refused.
# The queue now has its own budget, and BACKUP_TIMEOUT counts only the run.
QUEUE_TIMEOUT="${QUEUE_TIMEOUT:-3600}"
# The phases of a backup that has not finished (Velero pkg/apis/velero/v1
# backup_types.go). An empty phase is a backup the server has not seen yet.
VELERO_ACTIVE_PHASES=" New Queued ReadyToStart InProgress WaitingForPluginOperations WaitingForPluginOperationsPartiallyFailed Finalizing FinalizingPartiallyFailed "
VELERO_QUEUED_PHASES=" New Queued ReadyToStart "

# explain_bad_backup <name> — WHY a backup is not Completed, in the words
# Velero itself recorded.
#
# `.status` carries a NUMBER of errors and not one of them. Velero writes the
# per-item errors to the backup's OWN log, which it stores beside the backup
# in the durable bucket and never sends to the server pod's stdout, so
# `kubectl logs deploy/velero` does not hold them either. An operator whose
# teardown aborted therefore had a count and no cause: measured on 2026-09-02
# (deploy#1740), three runs of the kind loop reported `errors: 134` and no way
# to learn which items those were without a live cluster.
#
# The log comes back through a DownloadRequest: Velero signs a URL for the
# object and this reads it. That path needs no bucket credential here and no
# velero CLI, and it works the same on kind's MinIO and on S3.
#
# This function only ever prints. Every failure inside it is swallowed,
# because it runs on the way to an abort and must not replace the real
# message with one about diagnostics.
explain_bad_backup() {
  local name="$1" dr="teardown-explain-${1}" url="" deadline
  kubectl apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: DownloadRequest
metadata:
  name: ${dr}
  namespace: ${VELERO_NS}
spec:
  target:
    kind: BackupLog
    name: ${name}
YAML
  deadline=$(( $(date +%s) + 60 ))
  while :; do
    url="$(kubectl -n "$VELERO_NS" get "downloadrequest.velero.io/${dr}" -o jsonpath='{.status.downloadURL}')" || true
    [ -n "$url" ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '  (Velero signed no download URL for the log of %s within 60s, so the errors cannot be named here)\n' "$name" >&2
      return 0
    fi
    sleep 2
  done
  # curl -fsS names the HTTP status on stderr, never the signed URL.
  if ! curl -fsSL "$url" -o "$WORK/backup-log.gz"; then
    printf '  (the signed URL for the log of %s did not answer)\n' "$name" >&2
    return 0
  fi
  if ! python3 -c 'import gzip,sys;sys.stdout.write(gzip.open(sys.stdin.buffer,"rt",errors="replace").read())' \
       < "$WORK/backup-log.gz" > "$WORK/backup.log"; then
    printf '  (the log of %s came back unreadable)\n' "$name" >&2
    return 0
  fi
  # Everything that makes two reports of the SAME fault look different goes
  # before the grouping: the timestamp, the log source, the backup name, the
  # Go function, and the NAMESPACE. The item collector lists every kind once
  # per included namespace, so one kind Velero cannot read is one error per
  # namespace; folding the namespace away turns those back into one line that
  # says which kind, and how many. Measured on 2026-09-02 (deploy#1740): with
  # the namespace left in, one kind filled four lines and the display cap hid
  # two thirds of the kinds behind the ones late in the alphabet.
  local grouped="$WORK/backup-errors.txt"
  grep 'level=error' "$WORK/backup.log" \
    | sed -e 's/^time="[^"]*" //' -e 's/^level=error //' \
          -e 's/ logSource="[^"]*"//' -e 's/ backup=[^ ]*//' \
          -e 's/ error\.function="[^"]*"//' \
          -e 's/ in the namespace \\"[^\\]*\\"//' \
    | sort | uniq -c | sort -rn > "$grouped"
  printf '\n  %s distinct errors in the backup log, most frequent first, at most 40 shown.\n' \
    "$(wc -l < "$grouped")" >&2
  printf '  The count is how many namespaces the fault was reported in.\n' >&2
  head -40 "$grouped" >&2
  kubectl -n "$VELERO_NS" delete "downloadrequest.velero.io/${dr}" --ignore-not-found >/dev/null \
    || printf '  (the DownloadRequest %s was not deleted; the error is above. Velero expires it on its own)\n' "$dr" >&2
}

# velero_bsl_ready <bsl> — the BackupStorageLocation the backup writes to is
# Available. Velero holds a backup whose location is not Available, so a
# broken bucket used to read as a 30-minute wait.
velero_bsl_ready() {
  local bsl="$1" status
  status="$(kubectl -n "$VELERO_NS" get "backupstoragelocation.velero.io/$bsl" \
    -o 'jsonpath={.status.phase}|{.status.lastValidationTime}|{.status.message}')" \
    || die "cannot read the BackupStorageLocation ${VELERO_NS}/${bsl} (the error is above). Nothing was destroyed"
  case "$status" in
    Available\|*) printf '  ✓ BackupStorageLocation %s Available (last validated %s)\n' "$bsl" "$(cut -d'|' -f2 <<<"$status")" ;;
    *) die "the BackupStorageLocation ${VELERO_NS}/${bsl} is not Available (phase|last validation|message: ${status}). Velero cannot write a backup to it. Nothing was destroyed" ;;
  esac
}

# velero_backups — "<name> <phase>" for each Backup in VELERO_NS. A kubectl
# error goes to stderr and returns non-zero.
velero_backups() {
  kubectl -n "$VELERO_NS" get backups.velero.io \
    -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}'
}

# velero_in_flight [except] — the backups that have not finished, other than
# <except>, one "<name> <phase>" per line.
velero_in_flight() {
  local except="${1:-}" list name phase
  list="$(velero_backups)" || return 1
  while read -r name phase; do
    [ -n "$name" ] && [ "$name" != "$except" ] || continue
    case "$VELERO_ACTIVE_PHASES" in *" ${phase:-New} "*) printf '%s %s\n' "$name" "${phase:-New}" ;; esac
  done <<<"$list"
}

# tenant_deletes_in_flight — one line for each Tenant that is being deleted,
# and for each tenant namespace that is Terminating. A tenant delete takes the
# last backup of the tenant first (gibson finalbackup), then deletes the
# child objects of the tenant (its data plane first), then the namespace. A
# preserve backup that runs during that delete ends PartiallyFailed on a pod
# hook of a pod that no longer exists (drill run 39072863923:
# tenant-smoke-*-neo4j-0). A kubectl error returns non-zero.
tenant_deletes_in_flight() {
  local tenants namespaces
  tenants="$(kubectl get tenants.gibson.zeroroot.ai \
    -o 'jsonpath={range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}')" || return 1
  namespaces="$(kubectl get namespaces \
    -o 'jsonpath={range .items[?(@.status.phase=="Terminating")]}{.metadata.name}{"\n"}{end}')" || return 1
  printf '%s\n' "$tenants" | sed '/^$/d; s/^/Tenant /; s/$/ deleting/'
  # Only non-empty tenant namespaces: an empty read prints no line.
  printf '%s\n' "$namespaces" | sed -n '/^tenant-./{s/^/namespace /;s/$/ Terminating/;p}'
}

# explain_stuck_backup <name> — what Velero is doing while <name> waits: every
# backup and its phase, the pod-volume backups that have not completed, and
# the tail of the server log. Each read prints its own error.
explain_stuck_backup() {
  local name="$1"
  printf '\n  the Velero backups and their phases:\n' >&2
  velero_backups | sed 's/^/    /' >&2 || true
  printf '\n  the pod-volume backups that have not completed:\n' >&2
  kubectl -n "$VELERO_NS" get podvolumebackups.velero.io \
    -o 'custom-columns=BACKUP:.metadata.labels.velero\.io/backup-name,POD:.spec.pod.name,VOLUME:.spec.volume,PHASE:.status.phase,STARTED:.status.startTimestamp' \
    | awk 'NR==1 || $4 != "Completed"' | sed 's/^/    /' >&2 || true
  printf '\n  the last 40 lines of the Velero server log:\n' >&2
  kubectl -n "$VELERO_NS" logs deploy/velero --tail=40 | sed 's/^/    /' >&2 || true
}

# preserve_backup <backup-name> — steps 0 through 3. Returns 0 only when the
# backup exists AND has been proven readable with the keyring.
preserve_backup() {
  local backup_name="$1"

  # --- 0. record ----------------------------------------------------------
  log "0/4 backup-verify record: the canary and the seal ciphertext, before the backup"
  "$HERE/backup-verify.sh" record \
    --substrate-env "$SUBSTRATE_ENV" \
    --backup-name "$backup_name" \
    --namespace "$NS" \
    --velero-namespace "$VELERO_NS" \
    --timeout "$VERIFY_TIMEOUT" \
    || die "backup-verify record failed. NOTHING was backed up and NOTHING was destroyed"

  # --- 1. Postgres --------------------------------------------------------
  log "1/4 CNPG base backup ${backup_name}, waited to completed"
  "$REPO/test/dr/cnpg-backup-and-wait.sh" \
    --namespace "$NS" --cluster "$CNPG_CLUSTER" \
    --name "$backup_name" --timeout "$BACKUP_TIMEOUT" \
    || die "the CNPG base backup did not complete. A preserve teardown MUST NOT proceed past this: the estate is still standing and nothing was destroyed"

  # --- 2. Velero ----------------------------------------------------------
  log "2/4 Velero backup ${backup_name} from the shipped Schedule ${SCHEDULE}"
  local schedule_json="$WORK/schedule.json" backup_json bsl
  kubectl -n "$VELERO_NS" get "schedule.velero.io/$SCHEDULE" -o json > "$schedule_json" \
    || die "the Schedule ${VELERO_NS}/${SCHEDULE} cannot be read (the error is above): if it is NotFound, the gibson-velero release is not installed, so there is no shipped backup spec to build from"
  backup_json="$(python3 "$HERE/lib/velero-backup-from-schedule.py" "$backup_name" < "$schedule_json")" \
    || die "the shipped Schedule ${SCHEDULE} cannot be used for a preserve backup (see the line above). Nothing was destroyed"

  # 2a. The location the backup writes to answers. Fail now, not after a wait.
  bsl="$(python3 -c 'import json,sys; print((json.load(sys.stdin).get("spec") or {}).get("storageLocation") or "default")' <<<"$backup_json")"
  velero_bsl_ready "$bsl"

  # 2b. Let the backups already in flight finish first. Velero would queue
  # this one behind them anyway: waiting here names what it waits for. A
  # tenant delete in flight is busy too: its namespace goes away after its
  # last backup, and must be gone before this backup reads the namespaces.
  local queue_deadline in_flight deletes last="" queue_start run_start=""
  queue_start=$(date +%s)
  queue_deadline=$(( queue_start + QUEUE_TIMEOUT ))
  while :; do
    in_flight="$(velero_in_flight "$backup_name")" \
      || die "cannot list the Velero backups (the error is above). Nothing was destroyed"
    deletes="$(tenant_deletes_in_flight)" \
      || die "cannot list the Tenants and the namespaces (the error is above). Nothing was destroyed"
    in_flight="$(printf '%s\n%s\n' "$in_flight" "$deletes" | sed '/^$/d')"
    [ -n "$in_flight" ] || break
    if [ "$in_flight" != "$last" ]; then
      printf '  waiting for the backups and the tenant deletes already in flight, which cover the same namespaces:\n'
      printf '%s\n' "$in_flight" | sed 's/^/    /'
      last="$in_flight"
    fi
    if [ "$(date +%s)" -ge "$queue_deadline" ]; then
      explain_stuck_backup "$backup_name"
      die "the Velero backups and the tenant deletes in flight did not finish within ${QUEUE_TIMEOUT}s (QUEUE_TIMEOUT), still waiting for: $(printf '%s' "$in_flight" | tr '\n' ';'). The estate is still standing"
    fi
    sleep "${VELERO_QUEUE_POLL:-20}"
  done

  printf '%s' "$backup_json" | kubectl apply -f - >/dev/null \
    || die "could not create the Velero Backup ${backup_name}"

  # 2c. Wait for it. Time in a queued phase counts against QUEUE_TIMEOUT (a
  # Schedule can fire between 2b and the apply). BACKUP_TIMEOUT starts when
  # the backup leaves the queue.
  local run_deadline="" phase=""
  while :; do
    phase="$(kubectl -n "$VELERO_NS" get "backup.velero.io/$backup_name" -o jsonpath='{.status.phase}')" \
      || printf '  (the read of the backup phase failed; the error is above)\n'
    printf '  backup %s phase=%s\n' "$backup_name" "${phase:-<none>}"
    case "$phase" in
      Completed)
        [ -n "$run_start" ] || run_start=$(date +%s)
        break ;;
      PartiallyFailed)
        kubectl -n "$VELERO_NS" get "backup.velero.io/$backup_name" -o jsonpath='{.status}' >&2
        explain_bad_backup "$backup_name"
        die "the Velero backup finished PartiallyFailed. That is a FAILURE, not a warning: items the spec asked for are missing from the backup, so it is not a backup this teardown may destroy behind. The estate is still standing" ;;
      Failed)
        kubectl -n "$VELERO_NS" get "backup.velero.io/$backup_name" -o jsonpath='{.status}' >&2
        explain_bad_backup "$backup_name"
        die "the Velero backup finished Failed. The estate is still standing" ;;
      FailedValidation)
        # A spec Velero refused. It ran nothing, so it wrote no log to read:
        # the reason is in the object itself.
        kubectl -n "$VELERO_NS" get "backup.velero.io/$backup_name" -o jsonpath='{.status}' >&2
        die "the Velero backup finished FailedValidation: Velero refused the spec this teardown built from the Schedule ${SCHEDULE}. The estate is still standing" ;;
    esac
    case "$VELERO_QUEUED_PHASES" in
      *" ${phase:-New} "*)
        if [ "$(date +%s)" -ge "$queue_deadline" ]; then
          explain_stuck_backup "$backup_name"
          die "the Velero backup stayed in phase ${phase:-<none>} past QUEUE_TIMEOUT (${QUEUE_TIMEOUT}s): Velero did not start it. The estate is still standing"
        fi ;;
      *)
        if [ -z "$run_deadline" ]; then
          run_start=$(date +%s)
          run_deadline=$(( run_start + BACKUP_TIMEOUT ))
        fi
        if [ "$(date +%s)" -ge "$run_deadline" ]; then
          explain_stuck_backup "$backup_name"
          die "the Velero backup did not finish within ${BACKUP_TIMEOUT}s of its start (last phase: ${phase}). The estate is still standing"
        fi ;;
    esac
    sleep 10
  done
  printf '  ✓ backup %s Completed\n' "$backup_name"
  # The two costs of the preserve backup, so a drill run states what a fresh
  # cluster costs: the wait for the Velero queue, and the backup's own run.
  local waited ran
  waited=$(( run_start - queue_start ))
  ran=$(( $(date +%s) - run_start ))
  printf '  preserve Velero backup: waited %ss for the queue, ran %ss\n' "$waited" "$ran"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '| preserve Velero backup %s | waited for the queue %ss | ran %ss |\n|---|---|---|\n' \
      "$backup_name" "$waited" "$ran" >> "$GITHUB_STEP_SUMMARY"
  fi

  # --- 3. backup-verify ---------------------------------------------------
  log "3/4 backup-verify: open the backup with the keyring the automation holds"
  "$HERE/backup-verify.sh" verify \
    --substrate-env "$SUBSTRATE_ENV" \
    --backup-name "$backup_name" \
    --cnpg-backup "$backup_name" \
    --namespace "$NS" \
    --velero-namespace "$VELERO_NS" \
    --cnpg-cluster "$CNPG_CLUSTER" \
    --timeout "$VERIFY_TIMEOUT" \
    || die "backup-verify failed on backup ${backup_name}. The teardown is ABORTED and the estate is STILL RUNNING. There is no fallback to MODE=wipe (CONTEXT.md § Preserve teardown)"
}
