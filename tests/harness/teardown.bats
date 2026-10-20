#!/usr/bin/env bats
#
# teardown.bats — proves the teardown verb FAILS CLOSED (deploy#1738,
# ADR-0083).
#
# WHY THIS SUITE EXISTS
# ---------------------
# A teardown is the one verb that cannot be undone. Three ways it can go
# quietly wrong, and one fixture each:
#
#   1. MODE by omission. A preserve teardown that silently becomes a wipe
#      destroys customer data and reports success. MODE has no default, in
#      make and in the script, and both refusals name BOTH modes.
#   2. A backup nobody can open. Without the bringup keyring the archive is
#      ciphertext, so backup-verify must abort BEFORE the destroy and leave
#      the cluster standing, with no fallback to a wipe.
#   3. A PartiallyFailed backup treated as good enough. PartiallyFailed
#      means items the spec asked for are missing; destroying behind one is
#      destroying behind a hole.
#
# What this suite deliberately does NOT re-test: the Schedule template's own
# contract (the `secrets` exclusion and the rest). That is asserted against
# the render, with its own failing fixture, by
# helm/gibson-velero/tests/velero-schedule.bats — which also proves a
# preserve teardown can build its Backup from that render. One owner per
# assertion.
#
# HOW IT IS OFFLINE
# -----------------
# `kind` and `aws` and `kubectl` are stubbed on PATH and record every call
# they receive. The whole preserve path runs against those stubs, including
# the REAL openssl canary encrypt and decrypt, so the happy-path test proves
# the verb prints its backup name and the failure tests prove the one thing
# that matters after a failure: `kind delete cluster` was NEVER called, so
# the cluster is still running.
#
# Run:
#   bats tests/harness/teardown.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TEARDOWN="$REPO_ROOT/scripts/teardown-kind.sh"
VERIFY="$REPO_ROOT/scripts/backup-verify.sh"

# The stage 0 shape the stubs answer for. The two keys are real 32-byte
# base64 values, because the canary really is encrypted and decrypted.
SEAL_KEY="c2VhbC1rZXktZm9yLXRoZS10ZWFyZG93bi1iYXRzLXN1aQ=="
OTHER_SEAL_KEY="YW5vdGhlci1rZXktdGhhdC1uZXZlci1zZWFsZWQtdGhpcw=="
REPO_PASSWORD="dmVsZXJvLXJlcG8tcGFzc3dvcmQtZm9yLXRoZS1iYXRzLXM="

load "$BATS_TEST_DIRNAME/assert.bash"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR" "$STATE/bucket"
  PATH="$STUB_DIR:$PATH"

  # Stage 0: a substrate.env and the keyring it names.
  KEYRING="$BATS_TEST_TMPDIR/keyring.env"
  SUBSTRATE="$BATS_TEST_TMPDIR/substrate.env"
  write_keyring "$SEAL_KEY" "$REPO_PASSWORD"
  cat > "$SUBSTRATE" <<EOF
SUBSTRATE_ENV=kind
BUCKET_ENDPOINT=http://127.0.0.1:9000
BUCKET_REGION=us-east-1
BUCKET_NAME=gibson-kind
KEYRING_FILE=$KEYRING
EOF

  # Stub knobs. Each test flips exactly one.
  export STATE
  export STUB_SEAL_KEY="$SEAL_KEY"
  export STUB_REPO_PASSWORD="$REPO_PASSWORD"
  export STUB_VELERO_BACKUP_PHASE=Completed
  export STUB_WAL_GAP=0
  write_stubs
}

write_keyring() {
  cat > "$KEYRING" <<EOF
OPENBAO_SEAL_KEY=$1
VELERO_REPO_PASSWORD=$2
BUCKET_ACCESS_KEY=AKIAEXAMPLEBATS00000
BUCKET_SECRET_KEY=YnVja2V0LXNlY3JldC1rZXktZm9yLWJhdHMtc3Vp
SMTP_PASSWORD=smtp-password-for-the-bats-suite
GHCR_PULL_TOKEN=
EOF
}

# The stubs. `kind` and `aws` and `kubectl` answer the exact calls the
# preserve path makes, and log every one of them so a test can assert what
# did and did not happen.
write_stubs() {
  cat > "$STUB_DIR/kind" <<'SH'
#!/usr/bin/env bash
echo "kind $*" >> "$STATE/kind.log"
exit 0
SH

  cat > "$STUB_DIR/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$STATE/aws.log"
# Drop the global flags so the s3 verb is $1.
while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint-url) shift 2 ;;
    --no-progress|--recursive|--quiet) shift ;;
    s3) shift; break ;;
    *) shift ;;
  esac
done
verb="${1:-}"; shift || true
args=()
for a in "$@"; do case "$a" in --*) ;; *) args+=("$a") ;; esac; done
key_of() { printf '%s' "${1#s3://gibson-kind/}"; }
case "$verb" in
  cp)
    src="${args[0]}"; dst="${args[1]}"
    case "$dst" in
      s3://*) k="$(key_of "$dst")"; mkdir -p "$STATE/bucket/$(dirname "$k")"; cp "$src" "$STATE/bucket/$k" ;;
      *)      k="$(key_of "$src")"; [ -f "$STATE/bucket/$k" ] || exit 1; cp "$STATE/bucket/$k" "$dst" ;;
    esac
    exit 0 ;;
  ls)
    target="${args[0]}"
    case "$target" in
      *"/base/"*)
        echo "2026-09-02 03:15:00        512 backup.info" ;;
      *"/wals/"*)
        # Three contiguous segments, or a hole in the middle when the test
        # asks for one. The gap is the fixture for the continuity check.
        echo "2026-09-02 03:10:00   16777216 backups/postgres/platform-postgres/wals/0000000100000000/000000010000000000000003.gz"
        if [ "${STUB_WAL_GAP:-0}" = 0 ]; then
          echo "2026-09-02 03:11:00   16777216 backups/postgres/platform-postgres/wals/0000000100000000/000000010000000000000004.gz"
        fi
        echo "2026-09-02 03:12:00   16777216 backups/postgres/platform-postgres/wals/0000000100000000/000000010000000000000005.gz" ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
esac
exit 0
SH

  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
args="$*"
echo "kubectl $args" >> "$STATE/kubectl.log"
b64() { printf '%s' "$1" | base64 -w0; }
case "$args" in
  *"cluster-info"*) exit 0 ;;
  *"config current-context"*) printf 'kind-%s' "${STUB_CONTEXT_CLUSTER:-teardown-bats}"; exit 0 ;;
  *"apply -f -"*) cat > /dev/null; exit 0 ;;

  # --- backup-verify record -------------------------------------------------
  *"get pods -l app.kubernetes.io/component=openbao"*) printf 'gibson-workloads-openbao-0'; exit 0 ;;
  *"exec gibson-workloads-openbao-0 -c openbao -- bao status"*)
    # STUB_BAO_STATUS: "ok" (default), "sealed", "flaky:N" (the first N execs
    # fail the way a kubelet round trip fails under load), or "dead".
    n=$(cat "$STATE/bao-status-calls" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STATE/bao-status-calls"
    case "${STUB_BAO_STATUS:-ok}" in
      sealed) echo "Sealed          true"; exit 0 ;;
      dead)   echo "error: unable to upgrade connection: container not found" >&2; exit 1 ;;
      flaky:*) k="${STUB_BAO_STATUS#flaky:}"; if [ "$n" -le "$k" ]; then echo "error: error dialing backend: EOF" >&2; exit 1; fi; echo "Sealed          false"; exit 0 ;;
      *) echo "Sealed          false"; exit 0 ;;
    esac ;;
  *"get secret bringup-keyring"*) b64 "$STUB_SEAL_KEY"; exit 0 ;;
  # The marker write. The marker comes in as the last ARGUMENT (drill run
  # 39171920065: the stdin of kubectl exec -i lost the bytes). The stub keeps
  # it, so the restored copy reads back the same marker.
  # STUB_MARKER_DROP=1: the write leaves the file empty, as the stdin path did.
  *"exec pod/backup-canary -- sh -c printf %s \"\$1\" > /data/marker && sync sh backup-canary "*)
    w=$(( $(cat "$STATE/marker-writes" 2>/dev/null || echo 0) + 1 )); echo "$w" > "$STATE/marker-writes"
    # STUB_MARKER_WRITE: flaky:N fails the first N write execs, dead fails each.
    case "${STUB_MARKER_WRITE:-ok}" in
      flaky:*) [ "$w" -gt "${STUB_MARKER_WRITE#flaky:}" ] || { echo "error: write exec dropped" >&2; exit 1; } ;;
      dead) echo "error: write exec container not found" >&2; exit 1 ;;
    esac
    if [ -n "${STUB_MARKER_DROP:-}" ]; then : > "$STATE/marker"; exit 0; fi
    printf '%s' "${@: -1}" > "$STATE/marker"
    exit 0 ;;
  # The stdin path is gone. A call to it is an undeclared call.
  # The read back of the marker, before the backup.
  # STUB_MARKER_RBACK: flaky:N fails the first N read back execs, dead fails each.
  *"exec pod/backup-canary -- cat /data/marker"*)
    r=$(( $(cat "$STATE/marker-readbacks" 2>/dev/null || echo 0) + 1 )); echo "$r" > "$STATE/marker-readbacks"
    case "${STUB_MARKER_RBACK:-ok}" in
      flaky:*) [ "$r" -gt "${STUB_MARKER_RBACK#flaky:}" ] || { echo "error: read back exec dropped" >&2; exit 1; } ;;
      dead) echo "error: read back exec container not found" >&2; exit 1 ;;
    esac
    cat "$STATE/marker" 2>/dev/null; exit 0 ;;

  # --- backup-verify verify -------------------------------------------------
  *"get secret velero-repo-credentials"*) b64 "$STUB_REPO_PASSWORD"; exit 0 ;;
  *"get restore.velero.io/"*".status.phase"*) printf '%s' "${STUB_RESTORE_PHASE:-Completed}"; exit 0 ;;
  # The Restore carries a Velero finalizer. A delete without --wait=false
  # blocks until it clears, which for a PodVolumeRestore the node-agent
  # never picked up is Velero's item-operation timeout: four hours. The stub
  # records such a blocking delete in a file, and the fixture below asserts
  # that the file does not exist. A file is deterministic. A wall-clock
  # bound fails on a loaded host (hosted#151).
  *"delete restore.velero.io/"*"--wait=false"*) exit 0 ;;
  *"delete restore.velero.io/"*) echo "kubectl $args" >> "$STATE/blocking-delete.log"; exit 0 ;;
  *"get podvolumerestores.velero.io"*) printf 'Completed\n'; exit 0 ;;
  # STUB_MARKER_READ: flaky:N fails the first N reads on the stream, empty
  # answers with no bytes, dead fails every read.
  *"exec pod/backup-canary -- sh -c if [ -f /data/marker ]; then cat /data/marker || { echo; echo MARKER-READ-FAILED; }; else echo NO-MARKER-FILE; fi"*)
    m=$(( $(cat "$STATE/marker-reads" 2>/dev/null || echo 0) + 1 )); echo "$m" > "$STATE/marker-reads"
    case "${STUB_MARKER_READ:-ok}" in
      flaky:*) [ "$m" -gt "${STUB_MARKER_READ#flaky:}" ] || { echo "error: error reading from error stream: EOF" >&2; exit 1; } ;;
      empty) exit 0 ;;
      missing) echo NO-MARKER-FILE; exit 0 ;;
      unreadable) echo "cat: read error: I/O error" >&2; printf '\nMARKER-READ-FAILED\n'; exit 0 ;;
      partial) echo "cat: read error: I/O error" >&2; printf 'backup-canary\nMARKER-READ-FAILED\n'; exit 0 ;;
      dead) echo "error: unable to upgrade connection: container not found" >&2; exit 1 ;;
      foreign) printf 'a marker from another backup'; exit 0 ;;
    esac
    cat "$STATE/marker" 2>/dev/null || printf 'no marker was recorded'
    exit 0 ;;
  *"exec pod/backup-canary -- ls -la /data"*) printf 'total 4\ndrwxrwxrwx 2 root root 4096 Oct 18 05:40 .\n'; exit 0 ;;

  # --- CNPG -----------------------------------------------------------------
  *"backup.postgresql.cnpg.io"*".status.phase"*) printf 'completed'; exit 0 ;;
  *"backup.postgresql.cnpg.io"*".status.backupId"*) printf '20260902T031500'; exit 0 ;;
  *"backup.postgresql.cnpg.io"*".status.beginWal"*) printf '000000010000000000000003'; exit 0 ;;
  *"backup.postgresql.cnpg.io"*".status.endWal"*) printf '000000010000000000000005'; exit 0 ;;
  *"cluster.postgresql.cnpg.io"*"destinationPath"*) printf 's3://gibson-kind/backups/postgres/'; exit 0 ;;
  *"cluster.postgresql.cnpg.io"*"ContinuousArchiving"*) printf 'True'; exit 0 ;;
  *"cluster.postgresql.cnpg.io"*"firstRecoverabilityPoint"*) printf '2026-09-02T03:00:00Z'; exit 0 ;;

  # --- Velero backup --------------------------------------------------------
  *"get schedule.velero.io/platform-hourly -o json"*)
    cat <<'JSON'
{"metadata":{"name":"platform-hourly","namespace":"velero"},
 "spec":{"schedule":"0 * * * *","template":{
   "includedNamespaces":["gibson","tenant-*"],
   "includedNamespaceScopedResources":["*"],
   "excludedNamespaceScopedResources":["secrets","*.generators.external-secrets.io"],
   "includedClusterScopedResources":["tenants.gibson.zeroroot.ai"],
   "defaultVolumesToFsBackup":true,"storageLocation":"default","ttl":"4320h0m0s"}}}
JSON
    exit 0 ;;
  # The Velero queue: the location is Available, and no backup is in flight.
  *"get backupstoragelocation.velero.io/default -o jsonpath={.status.phase}|"*) printf 'Available|2026-09-02T03:00:00Z|'; exit 0 ;;
  *"get backups.velero.io -o jsonpath={range .items[*]}"*) exit 0 ;;
  # No tenant delete is in flight (hosted run 39072863923).
  "get tenants.gibson.zeroroot.ai -o jsonpath={range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{\"\\n\"}{end}") exit 0 ;;
  "get namespaces -o jsonpath={range .items[?(@.status.phase==\"Terminating\")]}{.metadata.name}{\"\\n\"}{end}") exit 0 ;;
  *"get backup.velero.io/preserve-kind-"*".status.phase"*) printf '%s' "$STUB_VELERO_BACKUP_PHASE"; exit 0 ;;
  *"get backup.velero.io/preserve-kind-"*) printf '{"phase":"%s"}' "$STUB_VELERO_BACKUP_PHASE"; exit 0 ;;

  # --- the backup log, signed by Velero ------------------------------------
  *"get downloadrequest.velero.io/teardown-explain-preserve-kind-"*) printf 'http://bucket.invalid/signed/backup-logs.gz'; exit 0 ;;
  # backup-verify cleans up its canary and its namespace.
  "-n tenant-"*"-canary delete pod backup-canary --ignore-not-found --wait=true") exit 0 ;;
  "-n backup-verify-"*" wait --for=condition=Ready pod/backup-canary --timeout=30s") exit 0 ;;
  "delete namespace backup-verify-"*" --ignore-not-found --wait=false") exit 0 ;;
  "-n tenant-"*"-canary wait --for=condition=Ready pod/backup-canary --timeout="*) exit 0 ;;
  # The archive name of the platform Postgres: this suite's Cluster sets none.
  "-n gibson get cluster.postgresql.cnpg.io/platform-postgres -o jsonpath={.spec.backup.barmanObjectStore.serverName}") exit 0 ;;
  *) echo "$args" >> "${UNDECLARED_LOG:-$STATE/undeclared.log}"; echo "kubectl stub: undeclared call: $args" >&2; exit 1 ;;
esac
SH

  # curl fetches the signed URL. The stub answers with a gzipped backup log
  # holding the SAME fault reported in two namespaces, plus one info line, so
  # the fixture measures the fold: one kind is one line, whatever the
  # namespace count.
  cat > "$STUB_DIR/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$STATE/curl.log"
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ] || exit 1
{
  echo 'time="2026-09-02T20:55:00Z" level=error msg="Error listing resources" backup=velero/b error="applications.argoproj.io is forbidden: cannot list resource \"applications\" in the namespace \"gibson\"" logSource="pkg/backup/item_collector.go:689"'
  echo 'time="2026-09-02T20:55:01Z" level=error msg="Error listing resources" backup=velero/b error="applications.argoproj.io is forbidden: cannot list resource \"applications\" in the namespace \"tenant-one\"" logSource="pkg/backup/item_collector.go:689"'
  echo 'time="2026-09-02T20:55:02Z" level=info msg="Backing up item" backup=velero/b'
} | gzip -c > "$out"
exit 0
SH
  # docker removes the LoadBalancer container of the cluster. The stub keeps
  # the suite off the Docker daemon of the host, so a slow or absent daemon
  # cannot change a result (hosted#151).
  cat > "$STUB_DIR/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "$STATE/docker.log"
exit 0
SH
  chmod +x "$STUB_DIR/kind" "$STUB_DIR/aws" "$STUB_DIR/kubectl" "$STUB_DIR/curl" "$STUB_DIR/docker"
}

# The one assertion every failure test makes: the cluster is still running.
refute_cluster_deleted() {
  if [ -f "$STATE/kind.log" ] && grep -q "delete cluster" "$STATE/kind.log"; then
    echo "the cluster WAS deleted: $(cat "$STATE/kind.log")" >&2
    return 1
  fi
}

# ===========================================================================
# 1. MODE has no default
# ===========================================================================

@test "make teardown with no MODE is refused and names BOTH modes" {
  run make -C "$REPO_ROOT" teardown ENV=kind
  [ "$status" -ne 0 ]
  assert_output_has "MODE is required and has no default"
  assert_output_has "wipe"
  assert_output_has "preserve"
}

@test "make teardown with an unknown MODE is refused the same way" {
  run make -C "$REPO_ROOT" teardown ENV=kind MODE=nuke
  [ "$status" -ne 0 ]
  assert_output_has "MODE is required and has no default"
}

@test "make teardown with no ENV is refused: ENV has no default" {
  run make -C "$REPO_ROOT" teardown MODE=wipe
  [ "$status" -ne 0 ]
  assert_output_has "ENV is required and has no default"
}

@test "an ENV with no teardown row is refused and the four rows are named" {
  # The list is the thing under test, so it is pinned on purpose and updating it
  # when an environment arrives is the test working. `drill` is the fourth
  # (ADR-0095).
  run make -C "$REPO_ROOT" teardown ENV=azure MODE=wipe
  [ "$status" -ne 0 ]
  assert_output_has "ENV=azure has no teardown in this repo"
  assert_output_has "kind, staging, drill, prod"
}

@test "the script itself refuses an unset MODE, so no other caller can slip one past" {
  run env -u MODE bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "MODE is required and has no default"
  refute_cluster_deleted
}

# ===========================================================================
# 2. MODE=wipe destroys and touches nothing else
# ===========================================================================

@test "MODE=wipe deletes the cluster and never reads or writes the durable bucket" {
  run env MODE=wipe CLUSTER=teardown-bats bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -eq 0 ]
  grep -q "delete cluster --name teardown-bats" "$STATE/kind.log"
  grep -q "rm -f cloud-provider-teardown-bats" "$STATE/docker.log"
  [ ! -f "$STATE/aws.log" ]
  assert_output_has "nothing was deleted from the durable bucket"
  assert_output_has "comes up EMPTY"
}

# ===========================================================================
# 3. MODE=preserve: the happy path, then one fixture per failure mode
# ===========================================================================

@test "MODE=preserve backs up, verifies, destroys, and prints the backup name last" {
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -eq 0 ]
  grep -q "delete cluster --name teardown-bats" "$STATE/kind.log"
  # The last line is the name, in the form a recreate takes (ADR-0083).
  last="$(printf '%s\n' "$output" | tail -n1)"
  [[ "$last" =~ ^RESTORE_FROM=preserve-kind-[0-9]{8}-[0-9]{6}$ ]]
  # And every half of the gate ran.
  assert_output_has "backup-verify PASS"
  grep -q "backup.postgresql.cnpg.io" "$STATE/kubectl.log"
  grep -q "get schedule.velero.io/platform-hourly" "$STATE/kubectl.log"
  # The marker written before the backup is the marker read back after the
  # restore. A stub that dropped the bytes would print its own placeholder.
  assert_output_has "restored marker: backup-canary preserve-kind-"
}

@test "FAILING FIXTURE: the canary marker goes in as an argument, not on stdin (drill run 39171920065)" {
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$STATE/marker-writes")" = 1 ]
  run grep -c "exec -i pod/backup-canary" "$STATE/kubectl.log"
  [ "$output" = 0 ]
}

@test "FAILING FIXTURE: a marker that does not read back stops the teardown at once, before any backup" {
  export STUB_MARKER_DROP=1
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "the canary marker read back 0 bytes, not the"
  # No retry: one write, then the stop.
  [ "$(cat "$STATE/marker-writes")" = 1 ]
  run grep -cE "backup\.postgresql\.cnpg\.io|backup\.velero\.io" "$STATE/kubectl.log"
  [ "$output" = 0 ]
  run grep -q "delete cluster" "$STATE/kind.log"
  [ "$status" -ne 0 ]
}

@test "a write exec that fails twice is tried again, and the teardown proceeds (hosted#11)" {
  run env STUB_MARKER_WRITE=flaky:2 MARKER_WRITE_POLL=0 MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$STATE/marker-writes")" = 3 ]
  assert_output_has "restored marker: backup-canary preserve-kind-"
}

@test "a read back exec that fails twice is tried again, and the teardown proceeds (hosted#11)" {
  run env STUB_MARKER_RBACK=flaky:2 MARKER_WRITE_POLL=0 MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$STATE/marker-readbacks")" = 3 ]
}

@test "FAILING FIXTURE: a write exec that never succeeds stops the teardown before any backup and names the error (hosted#11)" {
  run env STUB_MARKER_WRITE=dead MARKER_WRITE_POLL=0 MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "in 4 tries (last error, write: error: write exec container not found"
  run grep -cE "backup\.postgresql\.cnpg\.io|backup\.velero\.io" "$STATE/kubectl.log"
  [ "$output" = 0 ]
}

@test "FAILING FIXTURE: a read back exec that never succeeds stops the teardown before any backup and names the error (hosted#11)" {
  run env STUB_MARKER_RBACK=dead MARKER_WRITE_POLL=0 MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "in 4 tries (last error, read back: error: read back exec container not found"
  run grep -cE "backup\.postgresql\.cnpg\.io|backup\.velero\.io" "$STATE/kubectl.log"
  [ "$output" = 0 ]
}

@test "FAILING FIXTURE: a restored marker that is not the recorded marker stops the teardown (hosted#11)" {
  run env STUB_MARKER_READ=foreign MARKER_READ_POLL=0 MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "the restored canary marker is not the marker written before the backup"
  assert_output_has "Restored: 'a marker from another backup'"
  run grep -q "delete cluster" "$STATE/kind.log"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: a backup name with a quote is refused before any call (hosted#11)" {
  run bash "$VERIFY" record --substrate-env kind --backup-name "x'y: z"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a Kubernetes object name"* ]]
}

@test "a restored marker read that fails twice on the stream is retried, and the teardown proceeds" {
  # Drill run 39097037534: one read of the restored marker gave nothing, and
  # its error went to /dev/null. A lost answer is not an empty volume.
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    STUB_MARKER_READ=flaky:2 MARKER_READ_POLL=0 bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_has "restored marker: backup-canary preserve-kind-"
  grep -q "delete cluster --name teardown-bats" "$STATE/kind.log"
}

@test "FAILING FIXTURE: a restored marker read that never answers stops the teardown and names the error" {
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    STUB_MARKER_READ=dead MARKER_READ_POLL=0 bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "PodVolumeRestores for it:"
  assert_output_has "did not answer the marker read in 4 tries (last error: error: unable to upgrade connection: container not found"
  run grep -q "delete cluster" "$STATE/kind.log"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: a restored volume with no marker file stops the teardown and lists the volume" {
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    STUB_MARKER_READ=missing MARKER_READ_POLL=0 bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "the restored canary volume /data:"
  assert_output_has "drwxrwxrwx 2 root root"
  assert_output_has "PodVolumeRestores for it:"
  assert_output_has "the restored canary volume holds no marker"
  [ "$(cat "$STATE/marker-reads")" = 1 ]
  run grep -q "delete cluster" "$STATE/kind.log"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: a marker that cannot be read in the pod stops the teardown after one read and names the error" {
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    STUB_MARKER_READ=unreadable MARKER_READ_POLL=0 bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "the restored canary volume /data:"
  assert_output_has "PodVolumeRestores for it:"
  assert_output_has "the restored canary marker exists and cannot be read: cat: read error: I/O error"
  [ "$(cat "$STATE/marker-reads")" = 1 ]
  run grep -q "delete cluster" "$STATE/kind.log"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: a marker read that fails after part of the file is no pass" {
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    STUB_MARKER_READ=partial MARKER_READ_POLL=0 bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "the restored canary marker exists and cannot be read"
  run grep -q "delete cluster" "$STATE/kind.log"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: a restored volume with an empty marker stops the teardown and lists the volume" {
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    STUB_MARKER_READ=empty MARKER_READ_POLL=0 bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  [ "$(cat "$STATE/marker-reads")" = 1 ]
  assert_output_has "the restored canary volume /data:"
  assert_output_has "the restored canary volume holds no marker"
  run grep -q "delete cluster" "$STATE/kind.log"
  [ "$status" -ne 0 ]
}

@test "a seal-status read that fails twice under load is retried, and the teardown proceeds" {
  # 2026-09-08: one kubectl exec failed on a memory-starved host and the
  # record step reported the store SEALED while it answered sealed=false a
  # minute later. Two failures, then the truth: the teardown must go on.
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    STUB_BAO_STATUS=flaky:2 bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -eq 0 ]
  assert_output_has "backup-verify PASS"
  [ "$(cat "$STATE/bao-status-calls")" -ge 3 ]
}

@test "FIXTURE: a store that ANSWERS sealed aborts as SEALED, and the cluster is STILL RUNNING" {
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    STUB_BAO_STATUS=sealed bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "is SEALED"
  refute_cluster_deleted
  [ ! -f "$STATE/aws.log" ]
}

@test "FIXTURE: a store that cannot be asked is could-not-run, never SEALED, and the cluster is STILL RUNNING" {
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    STUB_BAO_STATUS=dead bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "could not read the seal status"
  refute_output_has "is SEALED"
  refute_cluster_deleted
  [ "$(cat "$STATE/bao-status-calls")" -eq 12 ]
}

@test "FIXTURE: a canary Restore that never finishes aborts within the timeout, and the abort itself does not block" {
  # hosted run 34138863972 (2026-09-07): check 2 failed after its 240 s, then
  # the cleanup trap's `kubectl delete restore` waited on the Restore's
  # finalizer until Velero's four-hour item-operation timeout cancelled the
  # stuck PodVolumeRestore. A four-minute gate took four hours to say no.
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=5 \
    STUB_RESTORE_PHASE=InProgress bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "the canary Restore did not finish within 5s (last phase: InProgress)"
  assert_output_has "ABORTED"
  refute_cluster_deleted
  # The diagnostics name what was stuck, before the abort.
  assert_output_has "PodVolumeRestores for it"
  # The cleanup deleted the Restore WITHOUT waiting on its finalizer.
  grep -qE "delete restore.velero.io/backup-verify-[0-9-]+ --ignore-not-found --wait=false" "$STATE/kubectl.log"
  # And no delete waited on the finalizer.
  if [ -f "$STATE/blocking-delete.log" ]; then
    echo "a delete waited on the Restore finalizer: $(cat "$STATE/blocking-delete.log")" >&2
    return 1
  fi
}

@test "FIXTURE: with the keyring gone, backup-verify aborts and the cluster is STILL RUNNING" {
  rm -f "$KEYRING"
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "keyring"
  assert_output_has "no readable keyring"
  assert_output_has "NOTHING was backed up and NOTHING was destroyed"
  refute_cluster_deleted
  # It aborted before it touched the cluster or the bucket at all.
  [ ! -f "$STATE/aws.log" ]
}

@test "FIXTURE: a keyring missing one member aborts on the named member" {
  grep -v '^VELERO_REPO_PASSWORD=' "$KEYRING" > "$KEYRING.tmp" && mv "$KEYRING.tmp" "$KEYRING"
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "VELERO_REPO_PASSWORD is missing"
  refute_cluster_deleted
}

@test "FIXTURE: a kubeconfig context that is not CLUSTER is refused before anything happens" {
  # The backup is taken through the current context and the destroy names
  # CLUSTER. Two different clusters there means backing one up and destroying
  # the other, and reporting success.
  export STUB_CONTEXT_CLUSTER=somebody-elses-cluster
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "would back up one cluster and destroy another"
  refute_cluster_deleted
  [ ! -f "$STATE/aws.log" ]
}

@test "FIXTURE: a PartiallyFailed backup FAILS the teardown, and the cluster is STILL RUNNING" {
  export STUB_VELERO_BACKUP_PHASE=PartiallyFailed
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "PartiallyFailed"
  assert_output_has "That is a FAILURE, not a warning"
  refute_cluster_deleted
}

@test "FIXTURE: a PartiallyFailed backup NAMES the errors, grouped and counted" {
  # `.status` holds a count and not one cause, and Velero keeps the per-item
  # errors in the backup's own log in the bucket rather than on the server
  # pod's stdout. A teardown that aborts on a count nobody can explain is
  # what three runs of the kind loop hit on 2026-09-02 (deploy#1740).
  export STUB_VELERO_BACKUP_PHASE=PartiallyFailed
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "applications.argoproj.io is forbidden"
  # ONE distinct error: the same kind in two namespaces folds into one line
  # with the count 2, so the display cap counts kinds and not namespaces.
  assert_output_has "1 distinct errors in the backup log"
  assert_output_has "2 msg=\"Error listing resources\""
  refute_output_has "in the namespace"
  refute_output_has "Backing up item"
  refute_cluster_deleted
}

@test "FIXTURE: a repository password that is not the keyring's aborts before the destroy" {
  export STUB_REPO_PASSWORD="c29tZS1vdGhlci1yZXBvc2l0b3J5LXBhc3N3b3JkLWhlcmU="
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "is NOT the password the cluster seals the kopia repository with"
  refute_cluster_deleted
}

@test "FIXTURE: a seal key the automation does not hold aborts before the destroy" {
  # The cluster seals under one key; the keyring holds another. The canary
  # ciphertext then does not open, which is the whole point of the check.
  export STUB_SEAL_KEY="$OTHER_SEAL_KEY"
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "does NOT decrypt the ciphertext recorded before the backup"
  refute_cluster_deleted
}

@test "FIXTURE: a gap in the WAL archive aborts before the destroy" {
  export STUB_WAL_GAP=1
  run env MODE=preserve CLUSTER=teardown-bats BACKUP_TIMEOUT=30 VERIFY_TIMEOUT=30 \
    bash "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  assert_output_has "gap"
  assert_output_has "recovery stops at the hole"
  refute_cluster_deleted
}

# ===========================================================================
# 4. backup-verify on its own
# ===========================================================================

@test "backup-verify refuses to run without a subcommand, and that is NOT a pass" {
  run bash "$VERIFY" --substrate-env "$SUBSTRATE" --backup-name x
  [ "$status" -eq 2 ]
  assert_output_has "must be \`record\` or \`verify\`"
  assert_output_has "could not run"
}

# plant_canary <backup> <mac> — write a canary record into the stub bucket the
# way `record` does, sealed under SEAL_KEY (the key the keyring holds), with
# the given tag in place of the real one.
plant_canary() {
  local pf="$STATE/pf"
  printf '%s\n' "$SEAL_KEY" > "$pf"
  printf 'openbao-seal-canary %s' "$1" > "$STATE/plain"
  # The marker that the stub volume holds and the record names.
  printf 'backup-canary %s' "$1" > "$STATE/marker"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass "file:$pf" \
    -in "$STATE/plain" -out "$STATE/cipher"
  mkdir -p "$STATE/bucket/backups/canary"
  python3 - "$STATE/cipher" "$1" "$2" > "$STATE/bucket/backups/canary/$1.json" <<'PY'
import base64, json, sys
rec = {"backup": sys.argv[2], "plaintext": "openbao-seal-canary " + sys.argv[2],
       "alg": "aes-256-cbc/pbkdf2-100000/salted+hmac-sha256",
       "ciphertext": base64.b64encode(open(sys.argv[1], "rb").read()).decode(),
       "marker": "backup-canary " + sys.argv[2]}
if sys.argv[3] != "none":
    rec["mac"] = sys.argv[3]
json.dump(rec, sys.stdout)
PY
}

@test "FIXTURE: a canary record whose tag does not match is a wrong key, never a decrypt" {
  # Same key on both sides, so a bare CBC decrypt would open it. The tag is
  # what refuses, and it refuses every time, not 255 times in 256.
  plant_canary tampered "$(printf '%064d' 0)"
  run bash "$VERIFY" verify --substrate-env "$SUBSTRATE" \
    --backup-name tampered --cnpg-backup tampered --timeout 30
  [ "$status" -ne 0 ]
  assert_output_has "does NOT decrypt the ciphertext recorded before the backup"
  assert_output_has "authentication tag does not match"
  refute_cluster_deleted
}

@test "FIXTURE: a canary record with no tag is refused, it is never decrypted on trust" {
  plant_canary untagged none
  run bash "$VERIFY" verify --substrate-env "$SUBSTRATE" \
    --backup-name untagged --cnpg-backup untagged --timeout 30
  [ "$status" -ne 0 ]
  assert_output_has "carries no mac"
  refute_cluster_deleted
}

@test "backup-verify verify with no canary record in the bucket fails, it never assumes" {
  run bash "$VERIFY" verify --substrate-env "$SUBSTRATE" \
    --backup-name never-recorded --cnpg-backup never-recorded --timeout 30
  [ "$status" -ne 0 ]
  assert_output_has "no canary record"
  refute_cluster_deleted
}
