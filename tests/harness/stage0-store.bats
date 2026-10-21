#!/usr/bin/env bats
#
# stage0-store.bats: the stage 0 state, key slots and rotation record of every
# environment live in the durable bucket under tfstate/stage0/. Only drill
# keeps its keyring in Secrets Manager (ADR-0083 amendment of 2026-10-21,
# scripts/stage0-store.sh).
#
# Offline. terraform and aws are stubs that record their arguments.
#
# Run:
#   bats tests/harness/stage0-store.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
load assert

setup() {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export REC="$BATS_TEST_TMPDIR/rec"; mkdir -p "$REC"
  TF="$BATS_TEST_TMPDIR/tf"; mkdir -p "$TF"
  cat > "$BIN/terraform" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$REC/terraform.args"
exit 0
SH
  cat > "$BIN/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "sts get-caller-identity --query Account --output text") echo 447184491447; exit 0 ;;
  "s3api head-bucket --bucket "*) [ -z "${NO_BUCKET:-}" ] && exit 0; exit 254 ;;
  # An object exists when the test made $REC/obj/<bucket>/<key>.
  "s3api head-object --bucket "*)
    b="$4"; k="$6"
    [ -e "$REC/obj/$b/$k" ] && exit 0
    echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254 ;;
  "s3 cp --only-show-errors "*)
    # A copy down from the old drill key, or a copy up of a slot file.
    case "$4" in s3://*) mkdir -p "$(dirname "$5")"; echo '{}' > "$5" ;; *) echo "up $5" >> "$REC/uploads" ;; esac
    exit 0 ;;
esac
echo "aws stub: undeclared call: $*" >&2; exit 1
SH
  chmod +x "$BIN/"*
  export PATH="$BIN:$PATH"
}

# The state of this env exists at tfstate/stage0/ of its durable bucket.
remote_state() { mkdir -p "$REC/obj/zeroroot-ai-$1-durable-447184491447/tfstate/stage0"; : > "$REC/obj/zeroroot-ai-$1-durable-447184491447/tfstate/stage0/terraform.tfstate"; }

lib() { bash -c 'die() { echo "DIE: $*" >&2; exit 2; }; . "$1"; shift; "$@"' _ "$REPO_ROOT/scripts/stage0-store.sh" "$@"; }

@test "only drill keeps its keyring in AWS, as its tfvars say" {
  run lib stage0_keyring_remote drill
  [ "$status" -eq 0 ]
  run lib stage0_keyring_remote staging
  [ "$status" -ne 0 ]
  run lib stage0_keyring_remote prod
  [ "$status" -ne 0 ]
}

@test "every env inits on the state in its own durable bucket, with lock files" {
  for e in staging prod drill; do
    remote_state "$e"
    rm -f "$REC/terraform.args"
    run lib stage0_init "$TF" "$e" "$BATS_TEST_TMPDIR/state"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qx -- "-backend-config=bucket=zeroroot-ai-${e}-durable-447184491447" "$REC/terraform.args"
    grep -qx -- '-backend-config=key=tfstate/stage0/terraform.tfstate' "$REC/terraform.args"
    grep -qx -- '-backend-config=use_lockfile=true' "$REC/terraform.args"
    [ ! -e "$TF/backend_override.tf" ]
  done
}

@test "FAILING FIXTURE: an env with no durable bucket yet inits on a local state, and a stale local override is replaced when the bucket exists" {
  NO_BUCKET=1 run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
  grep -q 'backend "local"' "$TF/backend_override.tf"
  [ -e "$BATS_TEST_TMPDIR/state/.stage0-bootstrap" ]
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
  [ ! -e "$TF/backend_override.tf" ]
  [ ! -e "$BATS_TEST_TMPDIR/state/.stage0-bootstrap" ]
}

@test "FAILING FIXTURE: an empty state key with a local state in the state directory is refused, and the migrate command is named" {
  mkdir -p "$BATS_TEST_TMPDIR/state"; echo '{"version":4}' > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -ne 0 ]
  [[ "$output" == *"start from nothing"* ]]
  [[ "$output" == *"scripts/stage0-store.sh migrate staging $BATS_TEST_TMPDIR/state"* ]]
  [ ! -e "$REC/terraform.args" ]
}

@test "FAILING FIXTURE: an empty state key with the old drill state in the prod state bucket is refused" {
  mkdir -p "$REC/obj/zeroroot-ai-prod-tfstate-447184491447-us-east-1/substrate/drill"
  : > "$REC/obj/zeroroot-ai-prod-tfstate-447184491447-us-east-1/substrate/drill/terraform.tfstate"
  run lib stage0_init "$TF" drill "$BATS_TEST_TMPDIR/state"
  [ "$status" -ne 0 ]
  [[ "$output" == *"migrate drill"* ]]
}

@test "an empty state key with no old state anywhere is a fresh start and inits" {
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx -- '-backend-config=key=tfstate/stage0/terraform.tfstate' "$REC/terraform.args"
}

@test "a state at the new key inits even when a local file exists" {
  remote_state staging
  mkdir -p "$BATS_TEST_TMPDIR/state"; echo '{"version":4}' > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the migrate command moves a local state to the new key, and the slot files with it" {
  mkdir -p "$BATS_TEST_TMPDIR/state"; echo '{"version":4}' > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
  echo '{}' > "$BATS_TEST_TMPDIR/state/key-slots.tfvars.json"
  run "$REPO_ROOT/scripts/stage0-store.sh" migrate staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx -- '-migrate-state' "$REC/terraform.args"
  grep -q "key-slots.tfvars.json" "$REC/uploads"
}

@test "FAILING FIXTURE: the migrate command refuses when the new key already holds a state" {
  remote_state staging
  mkdir -p "$BATS_TEST_TMPDIR/state"; echo '{"version":4}' > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
  run "$REPO_ROOT/scripts/stage0-store.sh" migrate staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already holds a state"* ]]
  [ ! -e "$REC/terraform.args" ]
}

@test "FAILING FIXTURE: the migrate command refuses when there is no state to move" {
  run "$REPO_ROOT/scripts/stage0-store.sh" migrate staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no state to migrate"* ]]
}

@test "the state migrates into the bucket once, after the apply that made it" {
  NO_BUCKET=1 run lib stage0_init "$TF" prod "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
  run lib stage0_migrate "$TF" prod "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
  grep -qx -- '-migrate-state' "$REC/terraform.args"
  [ ! -e "$BATS_TEST_TMPDIR/state/.stage0-bootstrap" ]
  rm -f "$REC/terraform.args"
  run lib stage0_migrate "$TF" prod "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
  [ ! -e "$REC/terraform.args" ]
}

@test "FAILING FIXTURE: the pull command refuses an env whose keyring is in the GitHub environment" {
  run "$REPO_ROOT/scripts/stage0-store.sh" pull staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 2 ]
  [[ "$output" == *"keeps its keyring in the GitHub environment"* ]]
}

@test "the bucket policy denies tfstate/stage0/ to every principal but the rotation role and the operator roles" {
  f="$REPO_ROOT/substrate/gibson-bootstrap/bucket.tf"
  grep -q 'DenyStage0StateToEveryoneElse' "$f"
  grep -q 'aws_iam_role.rotation\[0\].arn' "$f"
  grep -q 'stage0_state_principal_role_names' "$f"
}
