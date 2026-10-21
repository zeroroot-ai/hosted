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
printf '%s\n' "$@" > "$REC/terraform.args"
exit 0
SH
  cat > "$BIN/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "sts get-caller-identity --query Account --output text") echo 447184491447; exit 0 ;;
  "s3api head-bucket --bucket "*) [ -z "${NO_BUCKET:-}" ] && exit 0; exit 254 ;;
esac
echo "aws stub: undeclared call: $*" >&2; exit 1
SH
  chmod +x "$BIN/"*
  export PATH="$BIN:$PATH"
}

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
