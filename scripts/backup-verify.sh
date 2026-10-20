#!/usr/bin/env bash
# backup-verify.sh — the gate inside a preserve teardown (ADR-0083, deploy#1738).
#
# In plain words: before a preserve teardown destroys anything, prove the
# backup it just took can be OPENED again with the keyring the automation
# will hold at recreate. A manifest check (phase Completed, sizes non-zero)
# proves an upload happened and nothing about readability, which is how 34
# secrets "survived" a teardown unreadable on 2026-09-01 (CONTEXT.md
# § Backup-verify). This is a canary decrypt, not a manifest check and not a
# full restore. The full restore rehearsal is the backup-restore exit test for
# blocker 3 (test/dr/), never a per-teardown step.
#
# TWO SUBCOMMANDS, because half the work has to happen BEFORE the backup.
#
#   record   Runs before the Velero backup. It plants the canary object that
#            has to ride IN the backup, and records the ciphertext the seal
#            check will decrypt afterwards. Both are cheap and both are
#            useless if they run late.
#   verify   Runs after the backup and before the destroy. Three checks, in
#            this order, each named in its own output line:
#
#     1 velero      The kopia repository password the keyring holds is the
#                   one the cluster seals the repository with, and a Restore
#                   of the canary from THIS backup lands its volume bytes in
#                   a scratch namespace and reads back byte for byte. The
#                   volume path is the one that goes through the repository
#                   password: object data rides in the plain backup tarball,
#                   volume data rides in kopia.
#     2 cnpg        The base backup this teardown took is in the barman
#                   catalog in the durable bucket, read with the keyring's
#                   OWN bucket credential, and the WAL archive is continuous
#                   from that backup forward: CNPG reports ContinuousArchiving
#                   True with a firstRecoverabilityPoint, the backup's own
#                   endWal segment is archived, and the segment sequence from
#                   its beginWal to the newest archived segment has NO GAP. A
#                   base backup with a broken archive restores only to the
#                   instant it was taken.
#     3 openbao     The ciphertext `record` wrote, encrypted under the key the
#                   LIVE store is sealed with (Secret <ns>/bringup-keyring,
#                   key openbao-seal-key), decrypts under the key the KEYRING
#                   FILE holds. That is the whole property: the automation's
#                   copy of the seal key opens what the cluster sealed. A
#                   restored store auto-unseals from that key alone, so if
#                   this fails the archive is ciphertext nobody can open.
#
# The canary cipher is this script's own (AES-256-CBC, pbkdf2, a random salt,
# the passphrase read from a 0600 file so no secret reaches argv). It is NOT
# OpenBao's internal seal format and does not claim to be. What it proves is
# key identity, proven by using the key AS a key rather than by comparing two
# strings.
#
# ANY failure exits non-zero, names the failing check, and leaves the estate
# standing. This script never destroys anything and never falls back to a
# wipe teardown (CONTEXT.md § Preserve teardown).
#
# The keyring is read and checked FIRST, before any cluster or bucket call.
# A verify that cannot read its keyring must abort before it has touched
# anything at all, which is what tests/harness/teardown.bats measures.
#
# Usage:
#   backup-verify.sh record --substrate-env <substrate.env> --backup-name <name>
#   backup-verify.sh verify --substrate-env <substrate.env> --backup-name <name> \
#       --cnpg-backup <cnpg-backup-cr-name>
# Options (both subcommands):
#   --namespace <ns>         release namespace          (default gibson)
#   --velero-namespace <ns>  velero namespace           (default velero)
#   --cnpg-cluster <name>    CNPG Cluster CR            (default platform-postgres)
#   --timeout <seconds>      per-wait deadline          (default 240)
#
# Exit codes: 0 every check passed · 1 a check failed, named · 2 could not run.
# Tools: kubectl, aws, openssl, python3.
set -uo pipefail

SUB=""
BACKUP_NAME=""
CNPG_BACKUP=""
NS=gibson
VELERO_NS=velero
CNPG_CLUSTER=platform-postgres
TIMEOUT=240

CMD="${1:-}"
shift || true
# The subcommand is validated before the options are, so a caller that
# forgot it is told what the two subcommands are, not that its first flag is
# unknown.
case "$CMD" in
  record|verify) ;;
  *) echo "backup-verify.sh: the first argument must be \`record\` or \`verify\`, got '${CMD}'." >&2
     echo "usage: backup-verify.sh record|verify --substrate-env <substrate.env> --backup-name <name>" >&2
     echo "backup-verify could not run (NOT a pass, the teardown is ABORTED)" >&2
     exit 2 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --substrate-env)     SUB="$2"; shift 2 ;;
    --backup-name)       BACKUP_NAME="$2"; shift 2 ;;
    --cnpg-backup)       CNPG_BACKUP="$2"; shift 2 ;;
    --namespace)         NS="$2"; shift 2 ;;
    --velero-namespace)  VELERO_NS="$2"; shift 2 ;;
    --cnpg-cluster)      CNPG_CLUSTER="$2"; shift 2 ;;
    --timeout)           TIMEOUT="$2"; shift 2 ;;
    *) echo "backup-verify.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'; else GREEN=''; RED=''; NC=''; fi

n=0
ok()     { n=$((n + 1)); printf '  %s✓%s %d %-9s %s\n' "$GREEN" "$NC" "$n" "$1" "$2"; }
elapsed() { printf '%ds' "$(( $(date +%s) - STARTED_AT ))"; }
fail()   { n=$((n + 1)); printf '  %s✗%s %d %-9s %s\n' "$RED" "$NC" "$n" "$1" "$2"
           printf '%sbackup-verify FAIL%s at check %d %s, after %s\n' "$RED" "$NC" "$n" "$1" "$(elapsed)"
           printf 'The teardown is ABORTED. The estate is still standing and nothing was destroyed.\n'
           printf 'There is no fallback to MODE=wipe: fix the named check and run the teardown again.\n'
           exit 1; }
cannot() { printf '  %s!%s %s\n' "$RED" "$NC" "$1"
           printf '%sbackup-verify could not run%s (NOT a pass, the teardown is ABORTED)\n' "$RED" "$NC"
           exit 2; }
note()   { printf '    %s\n' "$*"; }

[ -n "$SUB" ] || cannot "--substrate-env is required"
[ -n "$BACKUP_NAME" ] || cannot "--backup-name is required"
# The name goes into a Restore manifest and into an S3 key, so it must be a
# Kubernetes object name. A quote or a newline in it would write more YAML.
[[ "$BACKUP_NAME" =~ ^[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?$ ]] \
  || cannot "--backup-name '${BACKUP_NAME}' is not a Kubernetes object name (lowercase letters, digits, '-' and '.')"
[ "$CMD" != verify ] || [ -n "$CNPG_BACKUP" ] || cannot "--cnpg-backup is required for verify"
for tool in kubectl aws openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || cannot "$tool is not on PATH"
done
[ -r "$SUB" ] || cannot "no substrate.env at $SUB. Run make substrate ENV=<env> first (ADR-0083)"

umask 077
STARTED_AT=$(date +%s)
WORK="$(mktemp -d)"
SCRATCH_NS=""
cleanup() {
  # The scratch namespace is this script's own litter and never outlives it,
  # pass or fail. The canary in the release namespace is deliberately left:
  # it is IN the backup, and deleting it here would not change that.
  #
  # Both deletes are --wait=false. The Restore carries a Velero finalizer
  # that clears only when its PodVolumeRestore settles, and a PodVolumeRestore
  # the node-agent never picked up settles only at Velero's item-operation
  # timeout, four hours by default. Measured on hosted run 34138863972
  # (2026-09-07): check 2 failed at 16:14:25 after its 240 s, and this trap
  # then blocked on the Restore delete until 20:10:31, when the timeout
  # cancelled the PodVolumeRestore. A gate bounded to four minutes must not
  # take four hours to say no; the litter is Velero's to finish reaping.
  if [ -n "$SCRATCH_NS" ]; then
    kubectl delete namespace "$SCRATCH_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl -n "$VELERO_NS" delete "restore.velero.io/$SCRATCH_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

sub_get() { grep -E "^$1=" "$SUB" | head -n1 | cut -d= -f2-; }
BUCKET_ENDPOINT="$(sub_get BUCKET_ENDPOINT)"
BUCKET_NAME="$(sub_get BUCKET_NAME)"
BUCKET_REGION="$(sub_get BUCKET_REGION)"
KEYRING_FILE="${KEYRING_FILE:-$(sub_get KEYRING_FILE)}"
[ -n "$BUCKET_ENDPOINT" ] && [ -n "$BUCKET_NAME" ] \
  || cannot "$SUB is missing BUCKET_ENDPOINT or BUCKET_NAME"

# ---------------------------------------------------------------------------
# The keyring, first and before anything else. This is the whole point of the
# gate: the checks below use the EXACT keyring the automation will hold at
# recreate, so a keyring that cannot be read has to abort here, with no
# cluster call and no bucket call behind it.
# ---------------------------------------------------------------------------
[ -n "$KEYRING_FILE" ] || cannot "$SUB names no KEYRING_FILE"
[ -s "$KEYRING_FILE" ] \
  || fail keyring "no readable keyring at ${KEYRING_FILE}. Without the bringup keyring nothing in the durable bucket can be opened, so a preserve teardown MUST NOT destroy anything (CONTEXT.md § Bringup keyring)"
keyring_get() { grep -E "^$1=" "$KEYRING_FILE" | head -n1 | cut -d= -f2- || true; }
OPENBAO_SEAL_KEY="$(keyring_get OPENBAO_SEAL_KEY)"
VELERO_REPO_PASSWORD="$(keyring_get VELERO_REPO_PASSWORD)"
BUCKET_ACCESS_KEY="$(keyring_get BUCKET_ACCESS_KEY)"
BUCKET_SECRET_KEY="$(keyring_get BUCKET_SECRET_KEY)"
for member in OPENBAO_SEAL_KEY VELERO_REPO_PASSWORD BUCKET_ACCESS_KEY BUCKET_SECRET_KEY; do
  [ -n "${!member}" ] \
    || fail keyring "keyring member ${member} is missing from ${KEYRING_FILE}. Every check below needs it, so nothing is destroyed"
done
ok keyring "4 members read from ${KEYRING_FILE}"

# The canary pod's image. A mirrored busybox, the same one the Velero drills
# use, overridable for an air-gapped registry.
CANARY_IMAGE="${CANARY_IMAGE:-ghcr.io/zeroroot-ai/mirror/busybox:1.36}"
CANARY_KEY="backups/canary/${BACKUP_NAME}.json"
CANARY_LABEL="gibson.zeroroot.ai/backup-canary"
CANARY_NAME="backup-canary"
# The canary lives in its OWN namespace, and that namespace is `tenant-`
# shaped so the shipped Schedule includes it through its `tenant-*` glob with
# no change to the backup spec. Its own namespace is what makes the verify
# restore the same shape the Velero drills prove works: restore ONE namespace
# whole into a scratch namespace. A narrower restore (a labelSelector plus
# includedResources naming pods and PVCs) reached Completed and created no
# PodVolumeRestore at all, so the kopia repository was never opened and the
# check could not do its job (measured on a runner, deploy#1738 run
# 33634970927).
CANARY_NS="tenant-backup-canary"

s3() {
  # The keyring's own credential, and nothing of the caller's. On a runner the
  # OIDC role leaves AWS_SESSION_TOKEN in the environment, and a key pair sent
  # with a foreign session token is refused as InvalidToken (drill run
  # 37413963774, 2026-10-06). AWS_PROFILE goes for the same reason.
  env -u AWS_SESSION_TOKEN -u AWS_PROFILE \
  AWS_ACCESS_KEY_ID="$BUCKET_ACCESS_KEY" \
  AWS_SECRET_ACCESS_KEY="$BUCKET_SECRET_KEY" \
  AWS_DEFAULT_REGION="${BUCKET_REGION:-us-east-1}" \
    aws --endpoint-url "$BUCKET_ENDPOINT" "$@"
}

# passfile <base64-key> — write one secret on one line into a 0600 file and
# print the path. openssl reads a passphrase from a file with `-pass file:`,
# so no secret ever reaches argv or the process table.
passfile() {
  local f="$WORK/pass.$$.$RANDOM"
  printf '%s\n' "$1" > "$f"
  chmod 0600 "$f"
  printf '%s' "$f"
}

# hmac <passfile> <file> — print the hex HMAC-SHA256 of the file under the
# key in the passfile. The key never reaches argv: `openssl dgst -hmac` would
# put it in the process table.
hmac() {
  python3 - "$1" "$2" <<'PY'
import hashlib, hmac, sys
key = open(sys.argv[1], "rb").read().rstrip(b"\n")
print(hmac.new(key, open(sys.argv[2], "rb").read(), hashlib.sha256).hexdigest())
PY
}

# ===========================================================================
# record — plant the canary and record the ciphertext, BEFORE the backup.
# ===========================================================================
if [ "$CMD" = record ]; then
  printf 'backup-verify record (backup %s)\n' "$BACKUP_NAME"

  # The Velero canary. It lives in the release namespace, which the shipped
  # Schedule includes whole, so it rides in the backup with no change to the
  # backup spec. Its volume is what makes it a canary: a ConfigMap would
  # restore out of the plain tarball and would never open the kopia
  # repository. The `volumeType: local` annotation is read by the
  # local-path provisioner of kind and of k3s (drill, staging), whose default
  # hostPath PV the node-agent skips. A substrate with a CSI driver ignores it.
  # A stale canary from an earlier run is deleted, and a delete that FAILS
  # is not swallowed: the apply below would fail on the surviving pod
  # anyway, and it would fail with a less obvious message.
  kubectl -n "$CANARY_NS" delete pod "$CANARY_NAME" --ignore-not-found --wait=true >/dev/null 2>&1 \
    || fail canary "could not remove a stale canary pod in namespace ${CANARY_NS}"
  kubectl apply -f - >/dev/null <<YAML || fail canary "could not create the canary in namespace ${CANARY_NS}"
apiVersion: v1
kind: Namespace
metadata:
  name: ${CANARY_NS}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${CANARY_NAME}
  namespace: ${CANARY_NS}
  labels:
    ${CANARY_LABEL}: "true"
  annotations:
    volumeType: local
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${CANARY_NAME}
  namespace: ${CANARY_NS}
  labels:
    ${CANARY_LABEL}: "true"
spec:
  containers:
    - name: canary
      image: ${CANARY_IMAGE}
      command: ["sh", "-c", "sleep 86400"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: ${CANARY_NAME}
YAML
  kubectl -n "$CANARY_NS" wait --for=condition=Ready "pod/$CANARY_NAME" --timeout="${TIMEOUT}s" >/dev/null \
    || fail canary "the canary pod never became Ready in namespace ${CANARY_NS}"
  MARKER="backup-canary ${BACKUP_NAME} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # The marker goes in as an ARGUMENT, not on stdin. Drill run 39171920065:
  # `printf | kubectl exec -i ... cat > /data/marker` returned 0, and the
  # file had 0 bytes. The stdin of `kubectl exec -i` sometimes delivers
  # nothing, and the backup then carried an empty marker. kubectl passes
  # each argument to the container as it is, and the in-pod shell reads it
  # as "$1" and never parses it again, so a quote in BACKUP_NAME (an
  # operator argument) cannot run a command. The marker is not a secret: it
  # holds the backup name and a time.
  # Each try writes and reads back. An exec that exits non-zero (write or
  # read back) is a fault of the transport, so the loop tries again. A read
  # back that answers with other bytes is a fault of the write path: it fails
  # at once, because a second try would hide it.
  marker_err="$WORK/marker-readback.err"
  marker_ok=0 marker_last=""
  for _try in 1 2 3 4; do
    if ! kubectl -n "$CANARY_NS" exec "pod/$CANARY_NAME" -- sh -c 'printf %s "$1" > /data/marker && sync' sh "$MARKER" 2>"$marker_err"; then
      marker_last="write: $(tr '\n' ' ' < "$marker_err" | cut -c1-300)"
      [ "$_try" -lt 4 ] && sleep "${MARKER_WRITE_POLL:-3}"
      continue
    fi
    if ! got="$(kubectl -n "$CANARY_NS" exec "pod/$CANARY_NAME" -- cat /data/marker 2>"$marker_err")"; then
      marker_last="read back: $(tr '\n' ' ' < "$marker_err" | cut -c1-300)"
      [ "$_try" -lt 4 ] && sleep "${MARKER_WRITE_POLL:-3}"
      continue
    fi
    [ "$got" = "$MARKER" ] \
      || fail canary "the canary marker read back ${#got} bytes, not the ${#MARKER} bytes written"
    marker_ok=1
    break
  done
  [ "$marker_ok" -eq 1 ] \
    || fail canary "could not write and read back the canary marker in 4 tries (last error, ${marker_last:-none})"
  ok canary "pod/${CANARY_NAME} in ${CANARY_NS} holds a volume marker, read back, and rides in the backup"

  # The OpenBao ciphertext. The key comes from the CLUSTER, so what is
  # recorded is sealed under the key the live store actually runs on. The
  # verify half decrypts it with the key the KEYRING FILE holds. If the two
  # ever drift, that decrypt fails and the teardown aborts.
  BAO_POD="$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=openbao \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [ -n "$BAO_POD" ] || fail openbao "no OpenBao pod in namespace ${NS} (label app.kubernetes.io/component=openbao)"
  # One `kubectl exec` is one network round trip through the API server to
  # the kubelet, and on a host under memory pressure it fails on its own
  # (measured 2026-09-08 on the blocker 3 loop: the store answered
  # sealed=false to three consecutive calls a minute after this line had
  # reported it SEALED). So: up to twelve reads five seconds apart, and the
  # two outcomes told apart. A store that ANSWERS sealed is the refusal this
  # gate exists for; a store that cannot be asked is "could not run".
  bao_status=""
  for _try in $(seq 1 12); do
    if bao_status="$(kubectl -n "$NS" exec "$BAO_POD" -c openbao -- bao status 2>&1)"; then
      break
    fi
    bao_status=""
    sleep 5
  done
  [ -n "$bao_status" ] \
    || cannot "could not read the seal status of ${BAO_POD} in 12 tries (kubectl exec failed each time). Not a pass: the store may well be unsealed"
  printf '%s\n' "$bao_status" | grep -q 'Sealed  *false' \
    || fail openbao "${BAO_POD} is SEALED. The key this check would record is not opening anything, so recording it would prove nothing"
  CLUSTER_SEAL_KEY="$(kubectl -n "$NS" get secret bringup-keyring \
    -o jsonpath='{.data.openbao-seal-key}' 2>/dev/null | base64 -d)"
  [ -n "$CLUSTER_SEAL_KEY" ] \
    || fail openbao "Secret ${NS}/bringup-keyring has no openbao-seal-key: the live store's seal key cannot be read"
  PLAINTEXT="openbao-seal-canary ${BACKUP_NAME} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s' "$PLAINTEXT" > "$WORK/plain"
  PF="$(passfile "$CLUSTER_SEAL_KEY")"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass "file:$PF" \
    -in "$WORK/plain" -out "$WORK/cipher" \
    || { rm -f "$PF"; fail openbao "could not encrypt the canary under the live store's seal key"; }
  # Encrypt-then-MAC. CBC with PKCS#7 padding is not authenticated: a wrong
  # key opens a fresh salted ciphertext with a valid pad about once in 256
  # tries (measured 7 of 3000 on 2026-09-21), and `openssl enc -d` then exits
  # 0 with garbage. The tag makes a wrong key a certain refusal.
  MAC="$(hmac "$PF" "$WORK/cipher")" \
    || { rm -f "$PF"; fail openbao "could not authenticate the canary under the live store's seal key"; }
  rm -f "$PF"
  python3 - "$WORK/cipher" "$BACKUP_NAME" "$PLAINTEXT" "$MAC" "$MARKER" > "$WORK/canary.json" <<'PY'
import base64, json, sys
cipher = open(sys.argv[1], "rb").read()
json.dump({
    "backup": sys.argv[2],
    "plaintext": sys.argv[3],
    "alg": "aes-256-cbc/pbkdf2-100000/salted+hmac-sha256",
    "ciphertext": base64.b64encode(cipher).decode(),
    "mac": sys.argv[4],
    "marker": sys.argv[5],
    "note": "sealed under the key the live OpenBao ran on; backup-verify opens it with the bringup keyring",
}, sys.stdout)
PY
  s3 s3 cp --no-progress "$WORK/canary.json" "s3://${BUCKET_NAME}/${CANARY_KEY}" >/dev/null \
    || fail openbao "could not write the canary record to s3://${BUCKET_NAME}/${CANARY_KEY}"
  ok openbao "a ciphertext sealed under the live store's key is recorded at s3://${BUCKET_NAME}/${CANARY_KEY}"
  printf '%srecorded%s: the canary rides in backup %s\n' "$GREEN" "$NC" "$BACKUP_NAME"
  exit 0
fi

# ===========================================================================
# verify — the three checks, after the backup and before the destroy.
# ===========================================================================
printf 'backup-verify (backup %s)\n' "$BACKUP_NAME"

# ---------------------------------------------------------------------------
# 1 velero — the repository password opens the repository, and the canary's
#   volume bytes come back.
# ---------------------------------------------------------------------------
CLUSTER_REPO_PASSWORD="$(kubectl -n "$VELERO_NS" get secret velero-repo-credentials \
  -o jsonpath='{.data.repository-password}' 2>/dev/null | base64 -d)"
[ -n "$CLUSTER_REPO_PASSWORD" ] \
  || fail velero "Secret ${VELERO_NS}/velero-repo-credentials has no repository-password: the kopia repository has no password this teardown can prove"
[ "$CLUSTER_REPO_PASSWORD" = "$VELERO_REPO_PASSWORD" ] \
  || fail velero "the keyring's VELERO_REPO_PASSWORD is NOT the password the cluster seals the kopia repository with. The restore below would succeed with the cluster's copy and the automation could never open the repository again"

velero_restore_diagnostics() {
  printf '    Restore %s status:\n' "$SCRATCH_NS" >&2
  kubectl -n "$VELERO_NS" get "restore.velero.io/$SCRATCH_NS" \
    -o jsonpath='      phase={.status.phase} itemsRestored={.status.progress.itemsRestored} totalItems={.status.progress.totalItems} warnings={.status.warnings} errors={.status.errors}{"\n"}' >&2 2>/dev/null || true
  kubectl -n "$VELERO_NS" get "restore.velero.io/$SCRATCH_NS" \
    -o jsonpath='      failureReason={.status.failureReason}{"\n"}' >&2 2>/dev/null || true
  # BYTES and TOTAL print <none> for zero: Velero omits a zero count.
  printf '    PodVolumeRestores for it:\n' >&2
  kubectl -n "$VELERO_NS" get podvolumerestores.velero.io \
    -l velero.io/restore-name="$SCRATCH_NS" --no-headers \
    -o custom-columns='NAME:.metadata.name,POD:.spec.pod.name,VOLUME:.spec.volume,PHASE:.status.phase,BYTES:.status.progress.bytesDone,TOTAL:.status.progress.totalBytes' >&2 2>/dev/null \
    || printf '      (none)\n' >&2
  printf '    PodVolumeBackups in backup %s (what the restore had to work from):\n' "$BACKUP_NAME" >&2
  kubectl -n "$VELERO_NS" get podvolumebackups.velero.io \
    -l velero.io/backup-name="$BACKUP_NAME" --no-headers \
    -o custom-columns='NAME:.metadata.name,POD:.spec.pod.name,VOLUME:.spec.volume,PHASE:.status.phase,BYTES:.status.progress.bytesDone,TOTAL:.status.progress.totalBytes' >&2 2>/dev/null \
    || printf '      (none)\n' >&2
  printf '    restored pod in %s:\n' "$SCRATCH_NS" >&2
  kubectl -n "$SCRATCH_NS" get pods -o wide --no-headers >&2 2>/dev/null || printf '      (none)\n' >&2
  # A restored pod that sits Pending is the case the two runner failures of
  # 2026-09-08 (34190800718, 34217032807) left unexplained: the pod had no
  # node, and nothing here said whether the scheduler refused it, the PVC
  # never bound, or the node was tainted NotReady at that moment. The events
  # of the scratch namespace, its PVCs and the node's conditions say which.
  printf '    events in %s, newest last:\n' "$SCRATCH_NS" >&2
  kubectl -n "$SCRATCH_NS" get events --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -15 >&2 || true
  printf '    PVCs in %s:\n' "$SCRATCH_NS" >&2
  kubectl -n "$SCRATCH_NS" get pvc --no-headers >&2 2>/dev/null || printf '      (none)\n' >&2
  printf '    nodes, Ready condition and taints:\n' >&2
  kubectl get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,TAINTS:.spec.taints[*].key' >&2 2>/dev/null || true
  printf '    node-agent, last 20 lines:\n' >&2
  kubectl -n "$VELERO_NS" logs daemonset/node-agent --tail=20 >&2 2>/dev/null || printf '      (unavailable)\n' >&2
  # A PartiallyFailed Restore has no failureReason. The item that failed is
  # only in the restore results in object storage, which the velero binary in
  # the server pod reads (hosted#663). Four runs on 2026-10-12 failed here
  # with an empty reason.
  printf '    Restore %s results (velero restore describe --details):\n' "$SCRATCH_NS" >&2
  # The whole tail, errors included: a filter on the Warnings section hid the
  # error of the CLI itself and printed only "(unavailable)" (run 38247261452).
  # The server pod by its label name=velero. deploy/velero resolves through
  # the Deployment selector, which the node-agent pods also match, so the exec
  # landed on a node-agent pod (run 38316404113).
  local server_pod
  server_pod="$(kubectl -n "$VELERO_NS" get pods -l name=velero -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  { kubectl -n "$VELERO_NS" exec "pod/${server_pod:-<none>}" -c velero -- \
      /velero restore describe "$SCRATCH_NS" --details -n "$VELERO_NS" 2>&1 \
      || printf '      (velero restore describe exited %s)\n' "$?"; } | tail -80 >&2
}
SCRATCH_NS="backup-verify-$(date -u +%Y%m%d-%H%M%S)"
kubectl -n "$VELERO_NS" apply -f - >/dev/null <<YAML \
  || fail velero "could not create the Restore of the canary from backup ${BACKUP_NAME}"
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${SCRATCH_NS}
  namespace: ${VELERO_NS}
spec:
  backupName: ${BACKUP_NAME}
  # ONE namespace, whole, into a scratch namespace. No resource filter and no
  # label selector: the canary namespace holds nothing else, so narrowing buys
  # nothing, and a narrowed restore is what silently did nothing before.
  includedNamespaces: ["${CANARY_NS}"]
  namespaceMapping:
    ${CANARY_NS}: ${SCRATCH_NS}
  existingResourcePolicy: none
YAML
RESTORE_PHASE=""
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  RESTORE_PHASE="$(kubectl -n "$VELERO_NS" get "restore.velero.io/$SCRATCH_NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null)"
  case "$RESTORE_PHASE" in
    Completed|PartiallyFailed|Failed|FailedValidation) break ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] \
    && { sleep 5; continue; }
  velero_restore_diagnostics
  fail velero "the canary Restore did not finish within ${TIMEOUT}s (last phase: ${RESTORE_PHASE:-<none>})"
done
if [ "$RESTORE_PHASE" != Completed ]; then
  velero_restore_diagnostics
  fail velero "the canary Restore finished ${RESTORE_PHASE}, not Completed: $(kubectl -n "$VELERO_NS" get "restore.velero.io/$SCRATCH_NS" -o jsonpath='{.status.failureReason}' 2>/dev/null)"
fi
# A restore that reports Completed having done nothing is the failure this
# check exists to catch, so when it happens say what Velero actually did.
# The scratch namespace and the Restore are deleted by the EXIT trap, which
# is why this prints BEFORE failing rather than leaving it to a later step.
PVR_DONE="$(kubectl -n "$VELERO_NS" get podvolumerestores.velero.io \
  -l velero.io/restore-name="$SCRATCH_NS" \
  -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c '^Completed$')"
if [ "${PVR_DONE:-0}" -lt 1 ]; then
  velero_restore_diagnostics
  fail velero "the Restore reported Completed but NO PodVolumeRestore completed: the kopia repository was never opened, so nothing proves the volume data is readable"
fi
kubectl -n "$SCRATCH_NS" wait --for=condition=Ready "pod/$CANARY_NAME" --timeout="${TIMEOUT}s" >/dev/null \
  || fail velero "the restored canary pod never became Ready in ${SCRATCH_NS}"
# A lost answer is not an empty answer, and a missing file is not a lost
# answer (drill run 39097037534 read nothing, and its error went to
# /dev/null). The in-pod shell exits 0 whenever it runs. It prints a fixed
# line when the file does not exist, and a fixed last line when the file
# cannot be read, also after part of it. So a non-zero exit is the exec
# itself failing, which the read tries again, and an empty answer or a fixed
# line is the volume.
RESTORED="" read_err="" read_ok=0 tries=0
read_err_file="$WORK/marker-read.err"
while [ "$tries" -lt 4 ]; do
  tries=$((tries + 1))
  if RESTORED="$(kubectl -n "$SCRATCH_NS" exec "pod/$CANARY_NAME" -- \
      sh -c 'if [ -f /data/marker ]; then cat /data/marker || { echo; echo MARKER-READ-FAILED; }; else echo NO-MARKER-FILE; fi' 2>"$read_err_file")"; then
    read_ok=1; break
  fi
  read_err="$(tr '\n' ' ' < "$read_err_file" | cut -c1-300)"
  [ "$tries" -lt 4 ] && sleep "${MARKER_READ_POLL:-3}"
done
if [ "$read_ok" -ne 1 ]; then
  velero_restore_diagnostics
  fail velero "the restored canary pod did not answer the marker read in 4 tries (last error: ${read_err:-none})"
fi
case "$RESTORED" in
  *MARKER-READ-FAILED)
    # The file exists and cat failed, maybe after part of it.
    printf '    the restored canary volume /data:\n' >&2
    kubectl -n "$SCRATCH_NS" exec "pod/$CANARY_NAME" -- ls -la /data 2>&1 | sed 's/^/      /' >&2 || true
    velero_restore_diagnostics
    fail velero "the restored canary marker exists and cannot be read: $(tr '\n' ' ' < "$read_err_file" | cut -c1-300)" ;;
  ""|NO-MARKER-FILE)
    # Say what the restored volume holds, so the next run names the cause.
    printf '    the restored canary volume /data:\n' >&2
    kubectl -n "$SCRATCH_NS" exec "pod/$CANARY_NAME" -- ls -la /data 2>&1 | sed 's/^/      /' >&2 || true
    velero_restore_diagnostics
    fail velero "the restored canary volume holds no marker: the repository opened but the bytes did not come back" ;;
esac
# The restored bytes must be the bytes that record wrote. Any non-empty text
# is not enough: a stale or foreign file would pass it. The record holds the
# marker in the canary record in the bucket.
s3 s3 cp --no-progress "s3://${BUCKET_NAME}/${CANARY_KEY}" "$WORK/canary.json" >/dev/null 2>&1 \
  || fail velero "no canary record at s3://${BUCKET_NAME}/${CANARY_KEY}: backup-verify record never ran, so the restored marker has nothing to match"
RECORDED_MARKER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("marker",""), end="")' "$WORK/canary.json")" \
  || fail velero "the canary record at s3://${BUCKET_NAME}/${CANARY_KEY} is not JSON"
[ -n "$RECORDED_MARKER" ] \
  || fail velero "the canary record at s3://${BUCKET_NAME}/${CANARY_KEY} carries no marker: it was written by an older backup-verify. Run record again"
[ "$RESTORED" = "$RECORDED_MARKER" ] \
  || fail velero "the restored canary marker is not the marker written before the backup. Restored: '${RESTORED}'. Recorded: '${RECORDED_MARKER}'"
ok velero "repository password matches the keyring, and ${CANARY_NS} restored into ${SCRATCH_NS} with its volume (${PVR_DONE} PodVolumeRestore completed)"
note "restored marker: ${RESTORED}"

# ---------------------------------------------------------------------------
# 2 cnpg — the catalog holds this teardown's base backup, and the WAL archive
#   is continuous from it forward.
# ---------------------------------------------------------------------------
cnpg_backup_field() {
  kubectl -n "$NS" get "backup.postgresql.cnpg.io/$CNPG_BACKUP" -o jsonpath="$1" 2>/dev/null
}
BACKUP_ID="$(cnpg_backup_field '{.status.backupId}')"
BEGIN_WAL="$(cnpg_backup_field '{.status.beginWal}')"
END_WAL="$(cnpg_backup_field '{.status.endWal}')"
[ -n "$BACKUP_ID" ] \
  || fail cnpg "the CNPG Backup ${NS}/${CNPG_BACKUP} reports no backupId: there is no base backup to restore from"
DEST="$(kubectl -n "$NS" get "cluster.postgresql.cnpg.io/$CNPG_CLUSTER" \
  -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}' 2>/dev/null)"
[ -n "$DEST" ] \
  || fail cnpg "Cluster ${NS}/${CNPG_CLUSTER} declares no barmanObjectStore.destinationPath: Postgres is not archiving anywhere"
ARCHIVE_PREFIX="${DEST#s3://}"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX%/}"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX#"${BUCKET_NAME}"/}"
# The archive directory is the Cluster's backup serverName, which the bringup
# stamps per bootstrap; only a Cluster with none set archives under its own
# name (CNPG's default).
ARCHIVE_NAME="$(kubectl -n "$NS" get "cluster.postgresql.cnpg.io/$CNPG_CLUSTER" \
  -o jsonpath='{.spec.backup.barmanObjectStore.serverName}' 2>/dev/null)"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX}/${ARCHIVE_NAME:-$CNPG_CLUSTER}"
s3 s3 ls "s3://${BUCKET_NAME}/${ARCHIVE_PREFIX}/base/${BACKUP_ID}/" > "$WORK/base.ls" 2>/dev/null
grep -q . "$WORK/base.ls" \
  || fail cnpg "base backup ${BACKUP_ID} is NOT in the catalog at s3://${BUCKET_NAME}/${ARCHIVE_PREFIX}/base/, read with the keyring's own bucket credential"
COND="$(kubectl -n "$NS" get "cluster.postgresql.cnpg.io/$CNPG_CLUSTER" \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}' 2>/dev/null)"
FRP="$(kubectl -n "$NS" get "cluster.postgresql.cnpg.io/$CNPG_CLUSTER" \
  -o jsonpath='{.status.firstRecoverabilityPoint}' 2>/dev/null)"
[ "$COND" = True ] && [ -n "$FRP" ] \
  || fail cnpg "ContinuousArchiving is '${COND:-<unset>}' and firstRecoverabilityPoint is '${FRP:-<unset>}': the archive is not continuous and a restore stops at the base backup"
s3 s3 ls --recursive "s3://${BUCKET_NAME}/${ARCHIVE_PREFIX}/wals/" > "$WORK/wals.ls" 2>/dev/null
# Continuity, not presence. A WAL segment name is timeline(8) + logid(8) +
# segno(8) in hex, and with the default 16 MiB segment size the segments of
# one timeline form the unbroken sequence logid*256 + segno. A missing
# segment between the base backup's beginWal and the newest archived segment
# is a hole recovery cannot cross: the replay stops at the hole, silently,
# behind a base backup that looked healthy.
python3 "$HERE/lib/wal-continuity.py" "$WORK/wals.ls" "${BEGIN_WAL:-}" "${END_WAL:-}" \
  > "$WORK/wals.out" 2>&1
WAL_RC=$?
[ "$WAL_RC" -eq 0 ] || fail cnpg "WAL archive continuity: $(cat "$WORK/wals.out")"
ok cnpg "base backup ${BACKUP_ID} is in the catalog, and $(cat "$WORK/wals.out")"

# ---------------------------------------------------------------------------
# 3 openbao — the recorded ciphertext opens under the keyring's seal key.
# ---------------------------------------------------------------------------
[ -s "$WORK/canary.json" ] || s3 s3 cp --no-progress "s3://${BUCKET_NAME}/${CANARY_KEY}" "$WORK/canary.json" >/dev/null 2>&1 \
  || fail openbao "no canary record at s3://${BUCKET_NAME}/${CANARY_KEY}: backup-verify record never ran, so there is nothing to decrypt"
python3 - "$WORK/canary.json" "$WORK/cipher" "$WORK/expected" "$WORK/mac" <<'PY' || exit 2
import base64, json, sys
rec = json.load(open(sys.argv[1]))
open(sys.argv[2], "wb").write(base64.b64decode(rec["ciphertext"]))
open(sys.argv[3], "w").write(rec["plaintext"])
open(sys.argv[4], "w").write(rec.get("mac", ""))
PY
RECORDED_MAC="$(cat "$WORK/mac")"
[ -n "$RECORDED_MAC" ] \
  || fail openbao "the canary record at s3://${BUCKET_NAME}/${CANARY_KEY} carries no mac: it was written by an older backup-verify, so this run cannot tell a wrong key from a lucky pad. Run record again"
# The tag is checked BEFORE the decrypt. A CBC decrypt alone accepts a wrong
# key about once in 256 tries (see record), which read as a flake in
# tests/harness/teardown.bats fixture 18 on 2026-09-15 and 2026-09-16.
PF="$(passfile "$OPENBAO_SEAL_KEY")"
ACTUAL_MAC="$(hmac "$PF" "$WORK/cipher")" || { rm -f "$PF"; cannot "could not compute the canary tag"; }
[ "$ACTUAL_MAC" = "$RECORDED_MAC" ] \
  || { rm -f "$PF"; fail openbao "the keyring's OPENBAO_SEAL_KEY does NOT decrypt the ciphertext recorded before the backup (its authentication tag does not match). The automation holds a key that cannot open this store, so a recreate would come up sealed forever"; }
openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "file:$PF" \
  -in "$WORK/cipher" -out "$WORK/decrypted" 2>/dev/null \
  || { rm -f "$PF"; fail openbao "the ciphertext authenticated under the keyring's OPENBAO_SEAL_KEY but did not decrypt: the canary record is corrupt"; }
rm -f "$PF"
cmp -s "$WORK/decrypted" "$WORK/expected" \
  || fail openbao "the ciphertext decrypted to different bytes than were recorded: the canary record is corrupt"
ok openbao "the ciphertext recorded before the backup decrypts under the keyring's OPENBAO_SEAL_KEY"

# The budget is stated in CONTEXT.md § Backup-verify: under two minutes. It
# is printed, not assumed, so a check that grows past it is visible on every
# teardown instead of on the one where somebody times it.
printf '%sbackup-verify PASS%s in %s — backup %s is readable with the bringup keyring. The destroy may proceed.\n' \
  "$GREEN" "$NC" "$(elapsed)" "$BACKUP_NAME"
