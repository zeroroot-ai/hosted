#!/usr/bin/env bats
#
# drill-rotate-keys.bats: the drill starts the access key rotation of its IAM
# users, continues each open rotation in every run, and fails only on a
# rotation that fails (ADR-0083, drill sweep row 24).
#
# Offline. with-cluster.sh and stage0-store.sh are stubs. The with-cluster
# stub records each user and answers with the exit code that STUB_<user>
# names: 0 rotated, 1 waits, 2 failed.
#
# Run:
#   bats tests/harness/drill-rotate-keys.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
load assert

setup() {
  export SUBSTRATE_DIR="$BATS_TEST_TMPDIR/substrate"
  mkdir -p "$SUBSTRATE_DIR/drill" "$BATS_TEST_TMPDIR/bin"
  printf 'GITHUB_APP_ID=4900007\nGITHUB_APP_INSTALLATION_ID=160662894\n' > "$SUBSTRATE_DIR/drill/substrate.env"
  echo '{"key_slots": {"platform": {"active": "b", "keep": ["a", "b"]}, "smtp": {"active": "a", "keep": ["a"]}, "dns": {"active": "a", "keep": ["a"]}, "setec-disk-builder": {"active": "b", "keep": ["a", "b"]}}}' \
    > "$SUBSTRATE_DIR/drill/key-slots.tfvars.json"
  export CALLS="$BATS_TEST_TMPDIR/calls"
  cat > "$BATS_TEST_TMPDIR/bin/with-cluster" <<'SH'
#!/usr/bin/env bash
# with-cluster.sh drill <substrate-rotate.sh> <state> drill <user>
[ "$1" = drill ] && [ "$4" = drill ] || { echo "with-cluster stub: undeclared call: $*" >&2; exit 2; }
echo "$5 TF_VAR=${TF_VAR_argocd_github_app_id} WAIT=${WAIT_SECS} SLEEP=${SLEEP_SECS:-unset} SECRET_WAIT=${SECRET_WAIT_SECS:-unset}" >> "$CALLS"
v="STUB_${5//-/_}"; exit "${!v:-0}"
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/stage0-store"
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  export WITH_CLUSTER="$BATS_TEST_TMPDIR/bin/with-cluster" STAGE0_STORE="$BATS_TEST_TMPDIR/bin/stage0-store"
}

@test "continue runs only the users with an open rotation" {
  run "$REPO_ROOT/scripts/drill-rotate-keys.sh" continue
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cut -d' ' -f1 "$CALLS" | tr '\n' ' ')" = "platform setec-disk-builder " ]
  assert_output_has "smtp: no open rotation"
}

@test "start runs every user, with the app ids of substrate.env and a short wait" {
  run "$REPO_ROOT/scripts/drill-rotate-keys.sh" start
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cut -d' ' -f1 "$CALLS" | tr '\n' ' ')" = "platform smtp dns setec-disk-builder " ]
  grep -qx 'platform TF_VAR=4900007 WAIT=900 SLEEP=30 SECRET_WAIT=600' "$CALLS"
}

@test "a rotation that waits is not a failure, and says that a later run continues" {
  STUB_platform=10 run "$REPO_ROOT/scripts/drill-rotate-keys.sh" continue
  [ "$status" -eq 0 ]
  assert_output_has "platform: the rotation waits; a later drill run continues it"
}

@test "FAILING FIXTURE: with-cluster.sh that ran nothing (exit 1) fails the step, never reads as a wait" {
  # with-cluster.sh die() exits 1: no instance, two instances, no session
  # plugin, an API that does not answer. Only exit 10 is a wait.
  STUB_platform=1 run "$REPO_ROOT/scripts/drill-rotate-keys.sh" continue
  [ "$status" -eq 1 ]
  assert_output_has "the access key rotation failed for: platform"
  [[ "$output" != *"the rotation waits"* ]]
}

@test "FAILING FIXTURE: a rotation that fails fails the step and names the user" {
  STUB_setec_disk_builder=2 run "$REPO_ROOT/scripts/drill-rotate-keys.sh" continue
  [ "$status" -eq 1 ]
  assert_output_has "the access key rotation failed for: setec-disk-builder"
}

@test "FAILING FIXTURE: no SUBSTRATE_DIR is refused before any rotation" {
  SUBSTRATE_DIR="" run "$REPO_ROOT/scripts/drill-rotate-keys.sh" start
  [ "$status" -eq 2 ]
  [ ! -s "$CALLS" ]
}

@test "FAILING FIXTURE: a rotation that halts for a person fails the step, never reads as a wait" {
  STUB_platform=3 run "$REPO_ROOT/scripts/drill-rotate-keys.sh" continue
  [ "$status" -eq 1 ]
  assert_output_has "the access key rotation failed for: platform"
}
