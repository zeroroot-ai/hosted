#!/usr/bin/env bats
#
# setec-cpu-template.bats: test/setec/exit-test-cpu-template.sh fails when the
# env has no m8i node, when the scenario fails, skips or never passes, and it
# refuses a setec version whose suite would install a second release
# (setec#271) or a release with snapshots off. Offline: kubectl, make and go are stubs. The setec checkout is a
# small git repo with two tags.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$REPO_ROOT/test/setec/exit-test-cpu-template.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/bin"; SETEC="$BATS_TEST_TMPDIR/setec"
  mkdir -p "$STUBS" "$SETEC/test/e2e"
  git -C "$SETEC" init -q
  git -C "$SETEC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m old
  git -C "$SETEC" tag v0.1.0
  echo 'const installedNamespaceEnv = "SETEC_E2E_INSTALLED_NAMESPACE"' > "$SETEC/test/e2e/installed_run_test.go"
  git -C "$SETEC" add -A
  git -C "$SETEC" -c user.email=t@t -c user.name=t commit -q -m installed
  git -C "$SETEC" tag v0.2.0

  cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"io/instance}"*) printf '%s' "${STUB_RELEASE-gibson}" ;;
  *"{.args}"*)
    case "${STUB_SNAPSHOTS-on}" in
      on) printf '["--leader-elect=true","--snapshots-enabled"]\n' ;;
      false) printf '["--leader-elect=true","--snapshots-enabled=false"]\n' ;;
      unreadable) echo "the server is unreachable" >&2; exit 1 ;;
      *) printf '["--leader-elect=true"]\n' ;;
    esac ;;
  *"get pods"*)
    v="${STUB_VERSION-v0.2.0}"
    [ -n "$v" ] || exit 0
    printf 'ghcr.io/zeroroot-ai/setec:%s@sha256:aaa\n' "$v"
    a="${STUB_AGENT_VERSION-$v}"
    printf 'registry.local:5000/mirror/setec-node-agent%s@sha256:bbb\n' "${a:+:$a}"
    printf 'docker.io/library/busybox:1.36\n' ;;
  *"get nodes"*) printf '%s\n' ${STUB_TYPES-m8i.2xlarge} ;;
  *"current-context"*) printf 'default' ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
STUB
  cat > "$STUBS/make" <<'STUB'
#!/usr/bin/env bash
echo "make $* in $PWD with ${SETEC_E2E_RELEASE} in ${SETEC_E2E_INSTALLED_NAMESPACE}/${SETEC_E2E_SANDBOX_NAMESPACE} on ${SETEC_E2E_CONTEXT}"
case "${STUB_RESULT:-pass}" in
  pass) echo '--- PASS: TestLauncher_CPUTemplateSnapshotLoads (95.1s)' ;;
  skip) echo '--- SKIP: TestLauncher_CPUTemplateSnapshotLoads (0.0s)' ;;
  fail) echo '--- FAIL: TestLauncher_CPUTemplateSnapshotLoads (12.0s)'; exit 1 ;;
  none) echo 'ok  github.com/zeroroot-ai/setec/test/e2e 0.1s [no tests to run]' ;;
esac
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/go"
  chmod +x "$STUBS"/*
  export PATH="$STUBS:$PATH"
}

@test "a PASS on an env with m8i nodes passes, against the installed setec, at its tag" {
  run bash "$CHECK" "$SETEC"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the env runs setec v0.2.0, release gibson"* ]]
  [[ "$output" == *"with gibson in setec-system/setec-sandboxes on default"* ]]
  [[ "$output" == *"PASS: a snapshot loads with the m8i CPU template on setec v0.2.0"* ]]
  [ "$(git -C "$SETEC" describe --tags)" = v0.2.0 ]
}

@test "FAILING FIXTURE: an env with no m8i node fails" {
  STUB_TYPES="m6a.large c8i.xlarge" run bash "$CHECK" "$SETEC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the env has no m8i node"* ]]
}

@test "FAILING FIXTURE: a failed scenario fails" {
  STUB_RESULT=fail run bash "$CHECK" "$SETEC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"make e2e-cpu-template exited 1"* ]]
}

@test "FAILING FIXTURE: a skipped scenario fails" {
  STUB_RESULT=skip run bash "$CHECK" "$SETEC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIPPED"* ]]
}

@test "FAILING FIXTURE: a run where the scenario never passed fails" {
  STUB_RESULT=none run bash "$CHECK" "$SETEC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not report PASS"* ]]
}

@test "a setec version with no installed mode does not run, so no second release is installed" {
  STUB_VERSION=v0.1.0 run bash "$CHECK" "$SETEC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"has no installed mode"* ]]
  [[ "$output" != *"make e2e-cpu-template"* ]]
}

@test "FAILING FIXTURE: no setec Pod fails" {
  STUB_VERSION="" run bash "$CHECK" "$SETEC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no setec Pod with a setec image"* ]]
}

@test "FAILING FIXTURE: setec images with different tags fail" {
  STUB_AGENT_VERSION=v0.1.0 run bash "$CHECK" "$SETEC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"carry different tags"* ]]
}

@test "FAILING FIXTURE: a setec image with no tag fails" {
  STUB_AGENT_VERSION="" run bash "$CHECK" "$SETEC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no tag"* ]]
}

@test "FAILING FIXTURE: no release label fails" {
  STUB_RELEASE="" run bash "$CHECK" "$SETEC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no label app.kubernetes.io/instance"* ]]
}

@test "a release with snapshots off does not run, and says why" {
  STUB_SNAPSHOTS=off run bash "$CHECK" "$SETEC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"runs with snapshots off"* ]]
  [[ "$output" != *"make e2e-cpu-template"* ]]
}

@test "a release with --snapshots-enabled=false does not run" {
  STUB_SNAPSHOTS=false run bash "$CHECK" "$SETEC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"runs with snapshots off"* ]]
}

@test "a failed read of the setec arguments says so, with the kubectl error" {
  STUB_SNAPSHOTS=unreadable run bash "$CHECK" "$SETEC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not read the arguments"* ]]
  [[ "$output" == *"the server is unreachable"* ]]
}
