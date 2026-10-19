#!/usr/bin/env bats
#
# with-cluster.bats — the connect verb fails closed (ADR-0095).
#
# Staging is permanent and publishes no API port, so everything that talks to it
# goes through one SSM forward whose lifetime is the command's. The refusals are
# the point: a verb that guesses which instance to forward to, or that runs the
# command with no forward at all, reads the wrong cluster and reports it as fact.
#
# Run:
#   bats tests/harness/with-cluster.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  PATH="$STUB_DIR:$PATH"
  # One instance, running, by default. Each test overwrites what it needs.
  cat > "$STUB_DIR/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"describe-instances"*) cat "${IDS_FILE:-/dev/null}" ;;
  *"send-command"*) echo cmd-1 ;;
  *"get-command-invocation"*Status*) echo Success ;;
  *"get-command-invocation"*) printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://10.0.0.5:6443\n' ;;
  *) : ;;
esac
exit 0
SH
  cat > "$STUB_DIR/session-manager-plugin" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # with-cluster.sh asks the API one question: does it answer (hosted#654).
  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "cluster-info") exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$STUB_DIR"/aws "$STUB_DIR"/session-manager-plugin "$STUB_DIR"/kubectl
  export IDS_FILE="$BATS_TEST_TMPDIR/ids"
  printf 'i-0123456789abcdef0\n' > "$IDS_FILE"
}

@test "FAILING FIXTURE: an environment that is not up is named, never silently skipped" {
  : > "$IDS_FILE"
  run "$REPO_ROOT/scripts/with-cluster.sh" staging true
  [ "$status" -ne 0 ]
  [[ "$output" == *"no RUNNING instance"* ]]
  [[ "$output" == *"is not up"* ]]
}

@test "FAILING FIXTURE: two instances with the same Name tag is a refusal, not a coin flip" {
  printf 'i-aaa\ni-bbb\n' > "$IDS_FILE"
  run "$REPO_ROOT/scripts/with-cluster.sh" staging true
  [ "$status" -ne 0 ]
  [[ "$output" == *"running instances carry"* ]]
  [[ "$output" == *"forwarding to the wrong one"* ]]
}

@test "FAILING FIXTURE: a missing session-manager-plugin is named before anything is attempted" {
  # The workstation HAS the plugin, at /usr/local/bin, which is why this test
  # narrows PATH to the stubs plus the system minimum instead of deleting the
  # stub and trusting it is gone. A test that passes because the machine
  # running it happens to be configured is not a test.
  rm -f "$STUB_DIR/session-manager-plugin"
  run env PATH="$STUB_DIR:/usr/bin:/bin" "$REPO_ROOT/scripts/with-cluster.sh" staging true
  [ "$status" -ne 0 ]
  [[ "$output" == *"session-manager-plugin is not on PATH"* ]]
}

@test "ENV=prod is refused here and told where to go: it is EKS, not an EC2 cluster" {
  run "$REPO_ROOT/scripts/with-cluster.sh" prod true
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no EC2 cluster"* ]]
  [[ "$output" == *"aws eks update-kubeconfig"* ]]
}

@test "no command is a usage error, so a typo cannot open a forward and do nothing" {
  run "$REPO_ROOT/scripts/with-cluster.sh" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}
