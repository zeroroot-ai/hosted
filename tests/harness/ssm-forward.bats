#!/usr/bin/env bats
#
# ssm-forward.bats — proves scripts/lib/ssm-forward.sh stops the forward it
# started, plugin included, and refuses a port another process holds
# (hosted#209).
#
# WHY THIS SUITE EXISTS
# ---------------------
# `aws ssm start-session` runs session-manager-plugin, and the plugin is what
# holds the local port. Killing the aws pid alone leaves the plugin alive. On
# 2026-09-29 the orphan from one teardown held 127.0.0.1:6443 for the next
# teardown and the recreate after it, and the recreate read a dead cluster
# through it. Fixture 2 plants exactly that shape: an `aws` stub whose child
# outlives it unless the group is killed.
#
# Offline, by construction: `aws` is a stub, and the bound port is a local
# python socket. Nothing here reaches AWS.
#
# Run:
#   bats tests/harness/ssm-forward.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
load assert

setup() {
  STUBS="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBS"
  # The stub is the shape of the real thing: the parent (aws) spawns a child
  # (the plugin) and both sleep. The child's pid lands in CHILD_PID_FILE.
  cat > "$STUBS/aws" <<'STUB'
#!/usr/bin/env bash
sleep 300 &
echo $! > "$CHILD_PID_FILE"
wait
STUB
  chmod +x "$STUBS/aws"
  export CHILD_PID_FILE="$BATS_TEST_TMPDIR/child.pid"
  export PATH="$STUBS:$PATH"
}

teardown() {
  # Never leave the fixture's own processes behind, whatever the assertion did.
  if [ -n "${SSM_FORWARD_PGID:-}" ]; then kill -KILL -- "-$SSM_FORWARD_PGID" 2>/dev/null || true; fi
  if [ -s "$CHILD_PID_FILE" ]; then kill -KILL "$(cat "$CHILD_PID_FILE")" 2>/dev/null || true; fi
  if [ -n "${PORT_HOLDER_PID:-}" ]; then kill "$PORT_HOLDER_PID" 2>/dev/null || true; fi
}

# A free loopback port, chosen by the kernel and released again.
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

@test "1. the stop kills the plugin the aws command started, not only the aws command" {
  . "$REPO_ROOT/scripts/lib/ssm-forward.sh"
  port="$(free_port)"
  ssm_forward_start i-stub us-east-1 "$port"
  [ -n "$SSM_FORWARD_PGID" ]
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CHILD_PID_FILE" ] && break; sleep 0.2; done
  child="$(cat "$CHILD_PID_FILE")"
  kill -0 "$child"
  parent="$SSM_FORWARD_PGID"
  ssm_forward_stop
  # `! kill -0 ...` would be inert here: bats's error tracking never sees a
  # negated command fail, so the assertions are explicit on the exit status.
  run kill -0 "$parent"
  [ "$status" -ne 0 ]
  run kill -0 "$child"
  [ "$status" -ne 0 ]
  [ -z "${SSM_FORWARD_PGID:-}" ]
}

@test "2. a bound local port is refused, and the refusal names the holder" {
  port="$(free_port)"
  python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); time.sleep(60)' "$port" 3>&- &
  PORT_HOLDER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do ss -ltnH "sport = :$port" | grep -q . && break; sleep 0.2; done
  run bash -c ". '$REPO_ROOT/scripts/lib/ssm-forward.sh'; ssm_forward_start i-stub us-east-1 '$port'"
  [ "$status" -eq 1 ]
  assert_output_has "already bound"
  assert_output_has "python3"
  # The refusal started nothing: the stub never ran.
  [ ! -s "$CHILD_PID_FILE" ]
}

@test "3. every verb forwards through the helper and nowhere else" {
  # A COMMENT IS NOT A CALL. Judge code lines only, one file at a time: a
  # `grep -v` piped across many files merges them, and `grep -l` on that prints
  # "(standard input)" for any hit, which names no file and cannot be acted on.
  for f in "$REPO_ROOT"/scripts/*.sh; do
    run bash -c "grep -vE '^[[:space:]]*#' '$f' | grep -q 'aws ssm start-session' && echo '$f' || true"
    [ -z "$output" ]
  done
  # Since ADR-0095 the three steps around the forward live in one place,
  # lib/ec2-cluster-access.sh, so there is exactly ONE caller of the helper in
  # the tree and the verbs reach it through that. Before, the recreate and the
  # teardown each had their own copy and the two had already drifted.
  run bash -c "grep -rlE '^[^#]*ssm_forward_start ' \"$REPO_ROOT\"/scripts | sort"
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  assert_output_has "lib/ec2-cluster-access.sh"
  # Each verb still arms its own stop, because the forward must die with the
  # process that owns it and no two verbs share one.
  run grep -c 'ssm_forward_stop' "$REPO_ROOT/scripts/recreate-ec2.sh" "$REPO_ROOT/scripts/teardown-ec2.sh" "$REPO_ROOT/scripts/with-cluster.sh"
  assert_output_has "recreate-ec2.sh:1"
  assert_output_has "teardown-ec2.sh:1"
  assert_output_has "with-cluster.sh:1"
}

@test "4. FAILING FIXTURE: with job control on, the stop still kills the plugin" {
  # An interactive shell has job control, so a background job is already a
  # process-group leader and setsid forks. A stop keyed on `$!` then kills a
  # process that has exited and leaves the plugin on the port. The group id
  # must come from inside the new session.
  port="$(free_port)"
  run bash -c '
    set -m
    . "$1/scripts/lib/ssm-forward.sh"
    ssm_forward_start i-stub us-east-1 "$2"
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CHILD_PID_FILE" ] && break; sleep 0.2; done
    child="$(cat "$CHILD_PID_FILE")"
    kill -0 "$child" || { echo "child never started"; exit 3; }
    ssm_forward_stop
    if kill -0 "$child" 2>/dev/null; then echo "child $child survived the stop"; exit 4; fi
    echo "child gone"
  ' _ "$REPO_ROOT" "$port"
  [ "$status" -eq 0 ]
  assert_output_has "child gone"
}


@test "5. the console verb reaches staging and drill through with-cluster.sh, and prod through the EKS kubeconfig (hosted#437)" {
  # The private console path rides the SAME forward as every other verb: it
  # opens no SSM session of its own, so its forward dies with with-cluster.sh.
  for env in staging drill; do
    run make -s -C "$REPO_ROOT" --no-print-directory -n zitadel-console ENV="$env"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scripts/with-cluster.sh ${env} scripts/zitadel-console.sh"* ]]
  done
  run make -s -C "$REPO_ROOT" --no-print-directory -n zitadel-console ENV=prod
  [ "$status" -eq 0 ]
  [[ "$output" == *"eks-kubeconfig ENV=prod"* ]]
  [[ "$output" == *"env KUBECONFIG=/tmp/eks-prod.kubeconfig scripts/zitadel-console.sh"* ]]
  run grep -cE '^[^#]*(ssm_forward_start|aws ssm start-session)' "$REPO_ROOT/scripts/zitadel-console.sh"
  [ "$output" = 0 ]
}

@test "6. FAILING FIXTURE: the console verb refuses an env with no cluster access" {
  run make -s -C "$REPO_ROOT" --no-print-directory zitadel-console ENV=azure
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENV=azure has no private console path"* ]]
}
