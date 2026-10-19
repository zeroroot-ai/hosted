#!/usr/bin/env bats
#
# wait-archiving.bats — a bringup that cannot say the archive WORKS has not
# finished (ADR-0083, blocker 3).
#
# WHY THIS SUITE EXISTS
# ---------------------
# CNPG reports the Cluster Ready and Argo reports the Application Healthy
# whether or not a single WAL segment ever reaches the bucket. Both failures
# in this class were therefore SILENT, and both were found weeks later by a
# human looking at the bucket:
#
#   the kind MinIO endpoint on an AWS cluster   Every AWS bringup pointed
#     platform Postgres at an address that is not on the network. Measured on
#     the 2026-09-14 from-zero staging bringup.
#   an archive directory that already held WAL  barman-cloud-check-wal-archive
#     refuses it, and every base backup sits in walArchivingFailing. Measured
#     2026-09-07.
#
# So the two things under test are: the wait passes ONLY when a segment has
# actually been archived AND a base backup has completed, and when it fails it
# names which of the two is missing and why.
#
# Offline: `kubectl` is stubbed on PATH and answers from files the test writes.
#
# Run:
#   bats tests/harness/wait-archiving.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/wait-archiving.sh"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR" "$STATE"
  PATH="$STUB_DIR:$PATH"
  export STATE

  # The stub answers the three jsonpaths the library asks for, from files.
  # `condition` is the ContinuousArchiving status, `reason` its reason and
  # message, `backups` the names of completed Backup objects.
  printf '' > "$STATE/condition"
  printf '' > "$STATE/reason"
  printf '' > "$STATE/backups"
  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"type=='ContinuousArchiving'"*".reason"*) cat "$STATE/reason" ;;
  *"type=='ContinuousArchiving'"*)           cat "$STATE/condition" ;;
  *"get backups"*)                           cat "$STATE/backups" ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$STUB_DIR/kubectl"
}

# The caller's contract: NS, ARCHIVING_TIMEOUT and a die() that exits non-zero.
run_wait() {
  # ARCHIVING_POLL=0: the suite never sleeps, so a stub this suite gets wrong
  # fails in seconds instead of sleeping to the CI job timeout.
  run env NS=gibson ARCHIVING_TIMEOUT="${1:-0}" ARCHIVING_POLL=0 bash -c '
    die() { printf "%s\n" "$*" >&2; exit 1; }
    . "$0"
    wait_archiving
  ' "$LIB"
}

@test "a cluster archiving WAL with a completed base backup passes" {
  printf 'True' > "$STATE/condition"
  printf 'platform-postgres-20260914-1\n' > "$STATE/backups"
  run_wait 60
  [ "$status" -eq 0 ]
  [[ "$output" == *"archives its WAL, and 1 base backup(s) completed"* ]]
}

# FAILING FIXTURE: the kind MinIO endpoint on an AWS cluster. The Cluster is
# Ready, Argo is Healthy, and not one segment has left the pod.
@test "FAILING FIXTURE: ContinuousArchiving False fails the bringup and names the reason" {
  printf 'False' > "$STATE/condition"
  printf 'ContinuousArchivingFailing: Connect timeout on endpoint URL: http://172.18.255.250:9000/gibson-kind' > "$STATE/reason"
  printf '' > "$STATE/backups"
  run_wait 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"ContinuousArchiving=False"* ]]
  [[ "$output" == *"Connect timeout on endpoint URL"* ]]
}

# FAILING FIXTURE: an archive directory that already held another cluster's
# WAL. barman-cloud-check-wal-archive refuses it by name.
@test "FAILING FIXTURE: a refused archive directory fails the bringup" {
  printf 'False' > "$STATE/condition"
  printf 'WALArchivingFailing: barman-cloud-check-wal-archive: WAL archive check failed for server platform-postgres: Expected empty archive' > "$STATE/reason"
  run_wait 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"Expected empty archive"* ]]
}

# FAILING FIXTURE: WAL flowing, no base backup. The archive then holds
# segments with nothing to replay them onto, and a restore has no starting
# point at all (ADR-0083).
@test "FAILING FIXTURE: archiving without a completed base backup is not done" {
  printf 'True' > "$STATE/condition"
  printf '' > "$STATE/backups"
  run_wait 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"completed base backups=0"* ]]
}

# FAILING FIXTURE: the operator has written no condition at all. An unset
# condition must never read as a pass, which is how "Ready and Healthy" came
# to stand in for "backed up" in the first place.
@test "FAILING FIXTURE: an unset ContinuousArchiving condition is not a pass" {
  printf '' > "$STATE/condition"
  printf 'platform-postgres-1\n' > "$STATE/backups"
  run_wait 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"ContinuousArchiving=<unset>"* ]]
  [[ "$output" == *"no ContinuousArchiving condition at all"* ]]
}

# Both bringup verbs run the SAME file. A second copy is how the AWS stall
# detector came to measure less than the kind one did (ADR-0027, deploy#1746).
@test "every recreate arm sources one archiving proof, and none redefines it" {
  grep -q 'lib/wait-archiving.sh' "$REPO_ROOT/scripts/recreate-kind.sh"
  # The two AWS arms reach it through the shared tail (hosted#159).
  grep -q 'lib/wait-archiving.sh' "$REPO_ROOT/scripts/lib/bringup-after-cluster.sh"
  for arm in recreate-kind.sh recreate-aws.sh recreate-ec2.sh; do
    [ "$(grep -c '^wait_archiving() {' "$REPO_ROOT/scripts/$arm")" -eq 0 ]
  done
  [ "$(grep -c '^wait_archiving() {' "$LIB")" -eq 1 ]
}

# The proof runs AFTER stage 2. The Cluster does not exist until the umbrella
# syncs it, so asserting earlier fails every time on a bringup that is fine.
@test "the archiving proof runs after the Applications converge, never before" {
  local code wait_line archive_line
  # The order lives in the shared tail, which both AWS arms source.
  code="$(grep -vE '^[[:space:]]*#' "$REPO_ROOT/scripts/lib/bringup-after-cluster.sh")"
  wait_line=$(printf '%s\n' "$code" | grep -n '^wait_apps$' | head -1 | cut -d: -f1)
  archive_line=$(printf '%s\n' "$code" | grep -n '^wait_archiving$' | head -1 | cut -d: -f1)
  [ -n "$wait_line" ] && [ -n "$archive_line" ]
  [ "$wait_line" -lt "$archive_line" ]
}
