#!/usr/bin/env bats
#
# port-forward-loop.bats: an exit test stops its port-forward loops with
# their kubectl children (hosted#745).
#
# Offline. kubectl is a stub that writes its own pid and then sleeps, as a
# port-forward that holds its port does.
#
# Run:
#   bats tests/harness/port-forward-loop.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/port-forward-loop.sh"

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n gibson port-forward --address 127.0.0.1 svc/gibson-mailpit 18025:8025")
    echo "$$" >> "$PF_RECORD"; exec sleep 300 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
  export PF_RECORD="$TMP/kubectl.pids"
}

teardown() {
  # Never leave a stub behind, whatever the test did.
  [ -s "$PF_RECORD" ] && xargs -r kill -9 < "$PF_RECORD" 2>/dev/null || true
  rm -rf "$TMP"
}

# wait_for_kubectl: until the stub has written its pid, up to 10 s.
wait_for_kubectl() {
  for _ in $(seq 1 50); do [ -s "$PF_RECORD" ] && return 0; sleep 0.2; done
  return 1
}

alive() { kill -0 "$1" 2>/dev/null; }

@test "pf_stop_all stops the loop and its kubectl child" {
  PATH="$TMP/bin:$PATH"
  . "$LIB"
  pf_loop gibson svc/gibson-mailpit 18025:8025
  loop="${PF_PIDS[0]}"
  wait_for_kubectl
  child="$(head -n1 "$PF_RECORD")"
  alive "$child"
  pf_stop_all
  for _ in $(seq 1 25); do alive "$child" || break; sleep 0.2; done
  ! alive "$child" || { echo "kubectl ${child} survived pf_stop_all"; false; }
  ! alive "$loop" || { echo "the loop ${loop} survived pf_stop_all"; false; }
  [ "${#PF_PIDS[@]}" -eq 0 ]
}

@test "FAILING FIXTURE: a kill of the loop alone leaves the kubectl child alive" {
  # The old cleanup of the exit tests. This case proves that the stub models
  # the defect, so the case above can fail.
  PATH="$TMP/bin:$PATH"
  . "$LIB"
  pf_loop gibson svc/gibson-mailpit 18025:8025
  wait_for_kubectl
  child="$(head -n1 "$PF_RECORD")"
  kill "${PF_PIDS[0]}"
  sleep 1
  alive "$child" || { echo "the stub did not model a surviving child"; false; }
}

# own_loops FILE...: the lines that start a port-forward loop by hand, in the
# two shapes the exit tests used. Such a loop is not in PF_PIDS as a group,
# so pf_stop_all cannot reach its child.
own_loops() {
  grep -n -E '\( *while true; do|port-forward[^#]*\|\| true; *sleep' "$@"
}

@test "no exit test starts a port-forward loop of its own" {
  # Status 1 is "no match". Status 2 (no file, a read error) is no proof.
  run own_loops "$REPO_ROOT"/test/*/exit-test-*.sh
  [ "$status" -eq 1 ] || { echo "status ${status}: $output"; false; }
}

@test "FAILING FIXTURE: pf_loop refuses a shell with job control" {
  PATH="$TMP/bin:$PATH"
  . "$LIB"
  set -m
  run pf_loop gibson svc/gibson-mailpit 18025:8025
  set +m
  [ "$status" -eq 2 ]
  [[ "$output" == *"job control is on"* ]]
}

@test "FAILING FIXTURE: a loop started by hand is found, in either shape" {
  printf '( while true; do\n    kubectl -n "$NS" port-forward svc/x 1:1 >/dev/null 2>&1 || true\n    sleep 1\n  done ) &\n' > "$TMP/multi.sh"
  printf '( while true; do kubectl -n "$NS" port-forward svc/x 1:1 >/dev/null 2>&1 || true; sleep 1; done ) &\n' > "$TMP/one.sh"
  run own_loops "$TMP/multi.sh"; [ "$status" -eq 0 ]
  run own_loops "$TMP/one.sh"; [ "$status" -eq 0 ]
}
