# shellcheck shell=bash
# redis-cli.sh: run redis-cli in the Redis pod with the password on stdin.
#
# SOURCED by test/rotation/exit-test-rotation.sh, test/dr/lib/restore-markers.sh
# and scripts/lib/velero-restore.sh. The caller sets NS.
#
# STDIN_LOST: the exit code of an in-pod reader that got no secret on stdin.
# The stdin of `kubectl exec -i` can arrive empty with the exec exit 0 (drill
# runs 39171920065 and 39175834377). An empty secret is then no credential,
# and the service refuses it: redis-cli answers NOAUTH. A refusal check would
# read that as a pass. So the reader exits STDIN_LOST on an empty read, and
# the caller sends the secret again, at most 4 times (audit of the restore
# path, 2026-10-19).
STDIN_LOST=97

# redis_cli POD PASSWORD ARGS...: run redis-cli in POD. The password goes on
# stdin, never on an argv that a process list or a log could show. To use a
# tenant DB, start ARGS with -n <index>.
redis_cli() {
  local pod="$1" pw="$2" out rc; shift 2
  for _ in 1 2 3 4; do
    rc=0
    out="$(printf '%s\n' "$pw" | kubectl -n "$NS" exec -i "$pod" -c redis-stack -- \
      sh -c 'IFS= read -r p; [ -n "$p" ] || exit 97; REDISCLI_AUTH="$p" exec redis-cli --no-auth-warning "$@"' redis-cli "$@" 2>&1)" || rc=$?
    [ "$rc" -eq "$STDIN_LOST" ] || { printf '%s\n' "$out"; return "$rc"; }
    sleep 1
  done
  printf 'the password did not reach redis-cli on stdin in 4 tries\n'
  return "$STDIN_LOST"
}

# redis_password — the password in the Secret that External Secrets writes.
redis_password() {
  kubectl -n "$NS" get secret "${NS}-redis-stack" -o json 2>/dev/null \
    | jq -r '.data["redis-password"] // ((.data // {}) | to_entries | .[0].value) // empty' \
    | base64 -d 2>/dev/null
}
