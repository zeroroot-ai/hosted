#!/usr/bin/env bats
#
# ec2-cluster-access.bats: kubectl exec uses SPDY, not WebSocket, in each
# make verb and after the connect to an EC2 cluster.
#
# The WebSocket transport of kubectl dropped stream bytes, and the exec still
# exited 0: a canary marker sent on stdin arrived empty (drill runs
# 39171920065 and 39175834377), and stdout was lost on kind (#253).
#
# Offline: aws, ssm_forward_start and kubectl are stubs. kubectl records the
# value of KUBECTL_REMOTE_COMMAND_WEBSOCKETS it runs with.
#
# Run:
#   bats tests/harness/ec2-cluster-access.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  STUBS="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUBS"
  export SEEN="$BATS_TEST_TMPDIR/seen"
  cat > "$STUBS/aws" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"send-command"*) echo cmd-1 ;;
  *"--query Status"*) echo Success ;;
  *"StandardOutputContent"*) printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://10.60.0.5:6443\n' ;;
  *) exit 1 ;;
esac
STUB
  cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "cluster-info") exit 0 ;;
  "exec pod/canary -- true") printf '%s\n' "${KUBECTL_REMOTE_COMMAND_WEBSOCKETS-unset}" > "$SEEN"; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$STUBS/aws" "$STUBS/kubectl"
  export PATH="$STUBS:$PATH"
}

connect() {
  run env -u KUBECTL_REMOTE_COMMAND_WEBSOCKETS bash -c '
    set -u
    AWS_REGION=us-east-1 API_LOCAL_PORT=6443
    die() { echo "DIE: $*" >&2; exit 1; }
    ssm_forward_start() { return 0; }
    . "$1"
    ec2_cluster_connect i-stub "$2" || exit 1
    kubectl exec pod/canary -- true
    echo "server: $(grep -o "server: .*" "$2")"' _ \
    "$REPO_ROOT/scripts/lib/ec2-cluster-access.sh" "$BATS_TEST_TMPDIR/kc"
}

@test "FAILING FIXTURE: after the connect, kubectl runs with WebSocket exec off" {
  connect
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$SEEN")" = false ]
  [[ "$output" == *"server: https://127.0.0.1:6443"* ]]
}

@test "FAILING FIXTURE: each make verb runs with WebSocket exec off, whatever the caller set" {
  run env KUBECTL_REMOTE_COMMAND_WEBSOCKETS=true make -s -C "$REPO_ROOT" \
    --eval 'spdy-probe: ; @echo "spdy=$$KUBECTL_REMOTE_COMMAND_WEBSOCKETS"' spdy-probe
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"spdy=false"* ]] || { echo "$output"; false; }
}
