#!/usr/bin/env bats
#
# restore-markers-redis.bats: the Redis records of the restore read-back
# (hosted#7). A JSON document and a stream entry go into the logical DB of the
# tenant before the backup, and after the restore both must read back. A Redis
# that came back empty fails the check, and a wipe that keeps the records
# fails the absence check.
#
# Offline. kubectl is a stub with a small Redis: one directory, one file per
# key. The password goes on stdin, as in the real exec.
#
# Run:
#   bats tests/harness/restore-markers-redis.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  TMP="$(mktemp -d)"; export TMP
  mkdir -p "$TMP/bin" "$TMP/redis"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
R="$TMP/redis"
case "$*" in
  "-n gibson get secret gibson-redis-stack -o json")
    printf '{"data":{"redis-password":"%s"}}' "$(printf '%s' hunter2 | base64)"; exit 0 ;;
  "-n gibson exec -i gibson-redis-stack-0 -c redis-stack -- sh -c "*) ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
while [ "$1" != "redis-cli" ]; do shift; done; shift
read -r p
# STUB_DROP: the password is lost on stdin.
[ -z "${STUB_DROP:-}" ] || p=""
[ "$p" = hunter2 ] || { echo "NOAUTH Authentication required."; exit 0; }
[ "$1" = -n ] && { db="$2"; shift 2; } || db=0
cmd="$1"; shift
case "$cmd" in
  HGET)   cat "$R/idx.$2" 2>/dev/null ;;
  HKEYS)  ls "$R" | sed -n 's/^idx\.//p' ;;
  JSON.SET) printf '%s' "$3" > "$R/doc.$db.$1" ;;
  JSON.GET) if [ -f "$R/doc.$db.$1" ]; then printf '["%s"]\n' "$(sed 's/.*"id":"\([^"]*\)".*/\1/' "$R/doc.$db.$1")"; fi ;;
  XADD)   printf '1-0\nmarker\n%s\n' "$4" > "$R/stream.$db.$1"; echo 1-0 ;;
  XRANGE) cat "$R/stream.$db.$1" 2>/dev/null ;;
  *) echo "ERR unknown command $cmd"; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
  cat > "$TMP/drive.sh" <<SH
set -euo pipefail
export PATH="$TMP/bin:\$PATH"
NS=gibson TENANT=restore-loop GRAPH_MARKER=marker-42
die() { echo "DIE \$*" >&2; exit 1; }
note() { echo "NOTE \$*"; }
sleep() { :; }
. "$REPO_ROOT/test/dr/lib/restore-markers.sh"
"\$@"
SH
}

teardown() { rm -rf "$TMP"; }

drive() { run bash "$TMP/drive.sh" "$@"; }

@test "the seed writes the document and the stream entry, and the check reads them back" {
  echo 3 > "$TMP/redis/idx.restore-loop"
  drive markers_redis_seed
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"written to DB 3 and read back"* ]]
  drive markers_redis_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a Redis that came back with no master index fails the check (an empty volume)" {
  echo 3 > "$TMP/redis/idx.restore-loop"
  drive markers_redis_seed
  [ "$status" -eq 0 ]
  rm -f "$TMP"/redis/*
  drive markers_redis_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"the Redis volume came back empty"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a Redis that kept the index and lost the documents fails the check (a mission doc class)" {
  echo 3 > "$TMP/redis/idx.restore-loop"
  drive markers_redis_seed
  [ "$status" -eq 0 ]
  rm -f "$TMP"/redis/doc.*
  drive markers_redis_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not hold the document written before the teardown"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a Redis that kept the index and lost the stream fails the check (the Timeline tail class)" {
  echo 3 > "$TMP/redis/idx.restore-loop"
  drive markers_redis_seed
  [ "$status" -eq 0 ]
  rm -f "$TMP"/redis/stream.*
  drive markers_redis_check
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not hold the stream entry written before the teardown"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a seed with no logical DB for the tenant stops and lists the fields of the index" {
  echo 5 > "$TMP/redis/idx.someone-else"
  drive markers_redis_seed
  [ "$status" -ne 0 ]
  [[ "$output" == *"holds no logical DB for the tenant restore-loop"* ]]
  [[ "$output" == *"someone-else"* ]]
}

@test "FAILING FIXTURE: a password lost on every try is a stop, never an empty answer (stdin)" {
  echo 3 > "$TMP/redis/idx.restore-loop"
  STUB_DROP=1 drive markers_redis_seed
  [ "$status" -ne 0 ]
}

@test "the absence check passes on an empty Redis and fails when the index still names the tenant" {
  drive markers_redis_absent
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  echo 3 > "$TMP/redis/idx.restore-loop"
  drive markers_redis_absent
  [ "$status" -ne 0 ]
  [[ "$output" == *"restored without being asked"* ]]
}
