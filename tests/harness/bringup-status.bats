#!/usr/bin/env bats
#
# bringup-status.bats: the bringup status tool waits only for the Argo
# Applications that the overlay of the environment loads (hosted#506).
#
# A healthy staging failed with "bringup blocked at: arc-controller", because
# the DAG declares the ARC stages and staging parks both Applications in
# gitops/envs/staging/pending/. Offline: kubectl is a stub that reports each
# Application as Healthy unless the test names it in UNHEALTHY, and each
# substage as ready.
#
# Run:
#   bats tests/harness/bringup-status.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TOOL="$REPO_ROOT/scripts/bringup-status.sh"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  # The stub answers ONLY the exact reads of the gates and fails every other
  # read, so a gate that reads a name the chart no longer makes fails here
  # too (hosted#645). STUB_ADMIN and STUB_READY are the PlatformBootstrap
  # conditions AdminTokenReady and Ready.
  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"get application "*)
    # Only an Application that the overlay of the env declares exists.
    app="$3"
    grep -rhqx --include='*.yaml' --exclude-dir=pending "  name: ${app}" "${GITOPS_ENVS:-$STUB_OVERLAYS}/staging" \
      || { echo "Error from server (NotFound): applications.argoproj.io \"${app}\" not found" >&2; exit 1; }
    for u in ${UNHEALTHY:-}; do [ "$u" = "$app" ] && { printf 'Progressing'; exit 0; }; done
    printf 'Healthy'; exit 0 ;;
  *'get platformbootstrap -o jsonpath={.items[0].status.conditions[?(@.type=="AdminTokenReady")].status}'*)
    printf '%s' "${STUB_ADMIN:-True}"; exit 0 ;;
  *'get platformbootstrap -o jsonpath={.items[0].status.conditions[?(@.type=="Ready")].status}'*)
    printf '%s' "${STUB_READY:-True}"; exit 0 ;;
  "get secret -n gibson gibson-master-key") exit 0 ;;
  "get statefulset -n gibson -l app.kubernetes.io/component=daemon -o jsonpath={.items[*].status.readyReplicas}")
    printf '1'; exit 0 ;;
  *"jsonpath={.items[*].status.readyReplicas}"*) printf '1'; exit 0 ;;
esac
echo "kubectl stub: no such object: $*" >&2
exit 1
SH
  chmod +x "$STUB_DIR/kubectl"
  export PATH="$STUB_DIR:$PATH" STUB_OVERLAYS="$REPO_ROOT/gitops/envs"
}

@test "the staging overlay parks ARC in pending/, and the tool does not wait for it" {
  # The real DAG and the real staging overlay. ARC is unhealthy on purpose:
  # before hosted#506 the tool stopped here.
  UNHEALTHY="arc-controller arc-runners-zeroroot" run "$TOOL" staging
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"[skip]    arc-controller"* ]]
  [[ "$output" == *"[skip]    arc-runners"* ]]
  [[ "$output" == *"bringup complete"* ]]
}

@test "FAILING FIXTURE: an Application the overlay loads still blocks the bringup" {
  UNHEALTHY="gibson" run "$TOOL" staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"bringup blocked at: gibson-umbrella (argo:gibson)"* ]]
}

@test "FAILING FIXTURE: a parked Application that moves back into the overlay is waited for again" {
  envs="$BATS_TEST_TMPDIR/envs"
  mkdir -p "$envs/staging"
  cp -r "$REPO_ROOT/gitops/envs/staging/." "$envs/staging/"
  mv "$envs/staging/pending/arc-controller.yaml" "$envs/staging/arc-controller.yaml"
  UNHEALTHY="arc-controller" GITOPS_ENVS="$envs" run "$TOOL" staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"bringup blocked at: arc-controller"* ]]
}

@test "no env argument, or an env with no overlay, cannot run" {
  run "$TOOL"
  [ "$status" -eq 2 ]
  run "$TOOL" nowhere
  [ "$status" -eq 2 ]
  [[ "$output" == *"no overlay for ENV=nowhere"* ]]
}

@test "FAILING FIXTURE: an admin token the platform operator does not report ready blocks the bringup" {
  STUB_ADMIN=False run "$TOOL" staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"bringup blocked at: zitadel-admin-token"* ]]
}

@test "FAILING FIXTURE: a PlatformBootstrap that is not Ready blocks the bringup" {
  STUB_READY=False run "$TOOL" staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"bringup blocked at: platform-bootstrap"* ]]
}

@test "FAILING FIXTURE: a gate that reads an object name the stub does not know fails" {
  # The copy sources lib/cluster-probe.sh from beside itself.
  mkdir -p "$BATS_TEST_TMPDIR/lib"
  cp "$REPO_ROOT/scripts/lib/cluster-probe.sh" "$BATS_TEST_TMPDIR/lib/"
  tool="$BATS_TEST_TMPDIR/bringup-status.sh"
  sed 's|pb_condition_true AdminTokenReady ;;|kget _x get secret -n "${NS}" zitadel-admin-token ;;|' "$TOOL" > "$tool"
  chmod +x "$tool"
  grep -q 'kget _x get secret -n "${NS}" zitadel-admin-token' "$tool"
  BRINGUP_DAG="$REPO_ROOT/bringup-dag.yaml" GITOPS_ENVS="$REPO_ROOT/gitops/envs" run "$tool" staging
  [ "$status" -eq 1 ]
  [[ "$output" == *"bringup blocked at: zitadel-admin-token"* ]]
  # The BLOCKED line names the kubectl error, so a refusal never reads as a
  # gate that is only not ready (scripts/lib/smoke-probe.sh, THE RULE).
  [[ "$output" == *"error: kubectl stub: no such object: get secret -n gibson zitadel-admin-token"* ]] || { echo "$output"; false; }
}
