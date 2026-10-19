#!/usr/bin/env bats
#
# stage0-store.bats: drill keeps stage 0 in AWS, and staging and prod keep it
# on the workstation (ADR-0083 amendment of 2026-10-13,
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
esac
echo "aws stub: undeclared call: $*" >&2; exit 1
SH
  chmod +x "$BIN/"*
  export PATH="$BIN:$PATH"
}

lib() { bash -c 'die() { echo "DIE: $*" >&2; exit 2; }; . "$1"; shift; "$@"' _ "$REPO_ROOT/scripts/stage0-store.sh" "$@"; }

@test "only drill keeps stage 0 in AWS, as its tfvars say" {
  run lib stage0_remote drill
  [ "$status" -eq 0 ]
  run lib stage0_remote staging
  [ "$status" -ne 0 ]
  run lib stage0_remote prod
  [ "$status" -ne 0 ]
}

@test "drill inits on the prod state bucket, with the lock table and the KMS key" {
  run lib stage0_init "$TF" drill "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q 'backend "s3"' "$TF/backend_override.tf"
  grep -qx -- '-backend-config=bucket=zeroroot-ai-prod-tfstate-447184491447-us-east-1' "$REC/terraform.args"
  grep -qx -- '-backend-config=key=substrate/drill/terraform.tfstate' "$REC/terraform.args"
  grep -qx -- '-backend-config=dynamodb_table=zeroroot-ai-prod-tf-locks' "$REC/terraform.args"
  grep -qx -- '-backend-config=kms_key_id=alias/zeroroot-ai-prod-tf-bootstrap' "$REC/terraform.args"
}

@test "FAILING FIXTURE: staging inits on its local state and removes a stale S3 override" {
  printf 'terraform {\n  backend "s3" {}\n}\n' > "$TF/backend_override.tf"
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
  [ ! -e "$TF/backend_override.tf" ]
  grep -qx -- "-backend-config=path=$BATS_TEST_TMPDIR/state/terraform.tfstate" "$REC/terraform.args"
}

@test "pull and push do nothing for an env on the workstation" {
  run lib stage0_pull staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
  run lib stage0_push prod "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
}

@test "FAILING FIXTURE: the pull command refuses an env on the workstation" {
  run "$REPO_ROOT/scripts/stage0-store.sh" pull staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 2 ]
  assert_output_has "keeps stage 0 on the workstation"
}
