#!/usr/bin/env bash
# velero-backup-log.sh: explain_bad_backup, the errors that Velero recorded in
# the log of one backup, grouped and counted, and velero_backup_log, that log
# as plain text. Sourced by lib/preserve-backup.sh
# (the teardown) and test/rotation/exit-test-rotation.sh (the keyring class).
# It needs kubectl, curl and python3, and VELERO_NS (default velero).
VELERO_NS="${VELERO_NS:-velero}"

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
  local work
  work="$(mktemp -d)" || return 0
  velero_backup_log "$1" "$work/backup.log" || { rm -rf "$work"; return 0; }
  # Everything that makes two reports of the SAME fault look different goes
  # before the grouping: the timestamp, the log source, the backup name, the
  # Go function, and the NAMESPACE. The item collector lists every kind once
  # per included namespace, so one kind Velero cannot read is one error per
  # namespace; folding the namespace away turns those back into one line that
  # says which kind, and how many. Measured on 2026-09-02 (deploy#1740): with
  # the namespace left in, one kind filled four lines and the display cap hid
  # two thirds of the kinds behind the ones late in the alphabet.
  # A log with no error line makes grep exit 1. Under pipefail that ended the
  # caller before its own message (review of hosted#152), so it is no error.
  local grouped="$work/backup-errors.txt"
  { grep 'level=error' "$work/backup.log" || true; } \
    | sed -e 's/^time="[^"]*" //' -e 's/^level=error //' \
          -e 's/ logSource="[^"]*"//' -e 's/ backup=[^ ]*//' \
          -e 's/ error\.function="[^"]*"//' \
          -e 's/ in the namespace \\"[^\\]*\\"//' \
    | sort | uniq -c | sort -rn > "$grouped" || true
  printf '\n  %s distinct errors in the backup log, most frequent first, at most 40 shown.\n' \
    "$(wc -l < "$grouped")" >&2
  printf '  The count is how many namespaces the fault was reported in.\n' >&2
  head -40 "$grouped" >&2
  rm -rf "$work"
}

# velero_backup_log NAME FILE: the log of backup NAME, as plain text, in FILE.
# Returns 1 and says why on stderr when Velero signs no URL, the URL does not
# answer, or the log is unreadable. The DownloadRequest is deleted in every
# case after it was made.
velero_backup_log() {
  local name="$1" out="$2" dr="velero-explain-${1}" url="" deadline rc=0
  kubectl apply -f - >/dev/null <<YAML || { printf '  (the DownloadRequest for the log of %s was refused; the error is above)\n' "$name" >&2; return 1; }
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
  deadline=$(( $(date +%s) + ${VELERO_LOG_WAIT:-60} ))
  while :; do
    url="$(kubectl -n "$VELERO_NS" get "downloadrequest.velero.io/${dr}" -o jsonpath='{.status.downloadURL}')" || true
    [ -n "$url" ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '  (Velero signed no download URL for the log of %s within %ss, so the errors cannot be named here)\n' "$name" "${VELERO_LOG_WAIT:-60}" >&2
      rc=1; break
    fi
    sleep 2
  done
  # curl -fsS names the HTTP status on stderr, never the signed URL.
  if [ "$rc" -eq 0 ] && ! curl -fsSL "$url" -o "${out}.gz"; then
    printf '  (the signed URL for the log of %s did not answer)\n' "$name" >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ] && ! python3 -c 'import gzip,sys;sys.stdout.write(gzip.open(sys.stdin.buffer,"rt",errors="replace").read())' \
       < "${out}.gz" > "$out"; then
    printf '  (the log of %s came back unreadable)\n' "$name" >&2
    rc=1
  fi
  rm -f "${out}.gz"
  kubectl -n "$VELERO_NS" delete "downloadrequest.velero.io/${dr}" --ignore-not-found >/dev/null \
    || printf '  (the DownloadRequest %s was not deleted; the error is above. Velero expires it on its own)\n' "$dr" >&2
  return "$rc"
}
