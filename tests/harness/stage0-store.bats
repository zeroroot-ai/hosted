#!/usr/bin/env bats
#
# stage0-store.bats: the stage 0 state, key slots and rotation record of every
# environment live in the durable bucket under tfstate/stage0/, and its keyring
# in Secrets Manager (ADR-0083 amendments of 2026-10-21 and 2026-10-22,
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
# A migrate writes $REC/remote.tfstate (what terraform writes, a new lineage
# and serial 1) to the state key of the bucket that its backend names.
case " $* " in *" -migrate-state "*)
  b=""; for a in "$@"; do case "$a" in -backend-config=bucket=*) b="${a#-backend-config=bucket=}" ;; esac; done
  if [ -n "$b" ] && [ -s "$REC/remote.tfstate" ]; then
    mkdir -p "$REC/obj/$b/tfstate/stage0"; cp "$REC/remote.tfstate" "$REC/obj/$b/tfstate/stage0/terraform.tfstate"
  fi ;;
esac
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
  # The keyring secret of any environment: $REC/sm.json is its value.
  "secretsmanager get-secret-value --secret-id zeroroot-ai/"*"/keyring "*)
    [ -s "$REC/sm.json" ] || { echo "An error occurred (ResourceNotFoundException): Secrets Manager can't find the specified secret." >&2; exit 254; }
    cat "$REC/sm.json"; exit 0 ;;
  "secretsmanager put-secret-value --secret-id zeroroot-ai/"*"/keyring --secret-string file://"*)
    f="${*: -1}"; cp "${f#file://}" "$REC/sm.json"; echo "$4" > "$REC/sm.id"; exit 0 ;;
  "s3 cp --only-show-errors "*)
    # A copy down from the old drill key, or a copy up of a slot file.
    # A copy down takes the content of $REC/obj/<bucket>/<key> when it has one.
    case "$4" in
      s3://*) mkdir -p "$(dirname "$5")"; src="$REC/obj/${4#s3://}"
              if [ -s "$src" ]; then cp "$src" "$5"; else echo '{}' > "$5"; fi ;;
      *) echo "up $5" >> "$REC/uploads" ;;
    esac
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

@test "every env keeps its keyring in its Secrets Manager secret: a pull reads it, a push writes it" {
  for e in staging prod drill; do
    rm -rf "$REC/sm.json" "$BATS_TEST_TMPDIR/s"
    mkdir -p "$BATS_TEST_TMPDIR/s"
    printf 'OPENBAO_SEAL_KEY=abc\n' > "$BATS_TEST_TMPDIR/s/keyring.env"
    printf 'KEYRING_FILE=/x\nBUCKET_NAME=b\n' > "$BATS_TEST_TMPDIR/s/substrate.env"
    run lib stage0_push_keyring "$e" "$BATS_TEST_TMPDIR/s"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [ "$(cat "$REC/sm.id")" = "zeroroot-ai/$e/keyring" ]
    rm -f "$BATS_TEST_TMPDIR/s/keyring.env" "$BATS_TEST_TMPDIR/s/substrate.env" "$BATS_TEST_TMPDIR/s/.keyring.sha256"
    run "$REPO_ROOT/scripts/stage0-store.sh" pull-keyring "$e" "$BATS_TEST_TMPDIR/s"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -qx 'OPENBAO_SEAL_KEY=abc' "$BATS_TEST_TMPDIR/s/keyring.env"
    grep -qx "KEYRING_FILE=$BATS_TEST_TMPDIR/s/keyring.env" "$BATS_TEST_TMPDIR/s/substrate.env"
  done
}

@test "pull-keyring reads no slot file from the state bucket, so a role without tfstate/stage0/ can use it" {
  remote_state staging
  printf '{"keyring":"OPENBAO_SEAL_KEY=abc\\n","substrate_env":"KEYRING_FILE=/x\\n"}' > "$REC/sm.json"
  run "$REPO_ROOT/scripts/stage0-store.sh" pull-keyring staging "$BATS_TEST_TMPDIR/s"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$BATS_TEST_TMPDIR/s/key-slots.tfvars.json" ]
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
  remote_state staging
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ]
  [ ! -e "$TF/backend_override.tf" ]
  [ ! -e "$BATS_TEST_TMPDIR/state/.stage0-bootstrap" ]
}

@test "FAILING FIXTURE: an empty state key is refused on any machine, with or without a local state, and the migrate command is named" {
  # No local state at all: a runner, a second workstation.
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -ne 0 ]
  [[ "$output" == *"start from nothing"* ]]
  [[ "$output" == *"scripts/stage0-store.sh migrate staging $BATS_TEST_TMPDIR/state"* ]]
  [ ! -e "$REC/terraform.args" ]
  # A local state does not change the answer.
  mkdir -p "$BATS_TEST_TMPDIR/state"; echo '{"version":4}' > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -ne 0 ]
  [ ! -e "$REC/terraform.args" ]
}

@test "FAILING FIXTURE: an unreadable state key is refused, not read as empty" {
  cat > "$BIN/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "sts get-caller-identity --query Account --output text") echo 447184491447; exit 0 ;;
  "s3api head-bucket --bucket "*) exit 0 ;;
  "s3api head-object --bucket "*) echo "An error occurred (403) when calling the HeadObject operation: Forbidden" >&2; exit 254 ;;
esac
exit 1
SH
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot tell an empty state"* ]]
}

@test "a state at the new key inits even when a local file exists" {
  remote_state staging
  mkdir -p "$BATS_TEST_TMPDIR/state"; echo '{"version":4}' > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
  run lib stage0_init "$TF" staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

RES='"resources":[{"type":"aws_s3_bucket","name":"durable","instances":[{"attributes":{"id":"b"}}]}]'
OUT='"outputs":{"bucket_name":{"value":"b","type":"string"}}'
# The local state, and the copy that terraform init -migrate-state writes: a new
# lineage and serial 1, with the same resources and outputs.
STATE_JSON="{\"version\":4,\"lineage\":\"lin-1\",\"serial\":7,${RES},${OUT}}"
MIGRATED_JSON="{\"version\":4,\"lineage\":\"lin-new\",\"serial\":1,${OUT},${RES}}"

# old_drill_state: the old key of drill in the prod state bucket holds a state.
old_drill_state() {
  ob=zeroroot-ai-prod-tfstate-447184491447-us-east-1
  mkdir -p "$REC/obj/$ob/substrate/drill"
  printf '%s\n' "$STATE_JSON" > "$REC/obj/$ob/substrate/drill/terraform.tfstate"
  printf '%s\n' "$MIGRATED_JSON" > "$REC/remote.tfstate"
}

@test "the migrate command of drill also copies the key slots and the rotation record from substrate/drill/" {
  old_drill_state
  for f in key-slots.tfvars.json key-rotation.json; do : > "$REC/obj/$ob/substrate/drill/$f"; done
  run "$REPO_ROOT/scripts/stage0-store.sh" migrate drill "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx -- '-migrate-state' "$REC/terraform.args"
  grep -q "key-slots.tfvars.json" "$REC/uploads"
  grep -q "key-rotation.json" "$REC/uploads"
}

@test "FAILING FIXTURE: the migrate command of drill with no old slot files uploads none" {
  old_drill_state
  run "$REPO_ROOT/scripts/stage0-store.sh" migrate drill "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$REC/uploads" ]
}

@test "FAILING FIXTURE: the migrate command of drill refuses a local state, key slot or rotation file, which may be older than the old key" {
  for f in terraform.tfstate key-slots.tfvars.json key-rotation.json; do
    rm -rf "$BATS_TEST_TMPDIR/state" "$REC/terraform.args"; old_drill_state
    mkdir -p "$BATS_TEST_TMPDIR/state"; echo '{}' > "$BATS_TEST_TMPDIR/state/$f"
    run "$REPO_ROOT/scripts/stage0-store.sh" migrate drill "$BATS_TEST_TMPDIR/state"
    [ "$status" -eq 2 ] || { echo "$f: $output"; false; }
    [[ "$output" == *"empty state directory"* ]]
    [ ! -e "$REC/terraform.args" ]
  done
}

@test "the migrate command moves a local state to the new key, the slot files with it, and keeps no local copy, though the copy has a new lineage and serial" {
  mkdir -p "$BATS_TEST_TMPDIR/state"; printf '%s\n' "$STATE_JSON" > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
  echo '{}' > "$BATS_TEST_TMPDIR/state/terraform.tfstate.backup"
  echo '{}' > "$BATS_TEST_TMPDIR/state/key-slots.tfvars.json"
  printf '%s\n' "$MIGRATED_JSON" > "$REC/remote.tfstate"
  run "$REPO_ROOT/scripts/stage0-store.sh" migrate staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -qx -- '-migrate-state' "$REC/terraform.args"
  grep -q "key-slots.tfvars.json" "$REC/uploads"
  [ ! -e "$BATS_TEST_TMPDIR/state/terraform.tfstate" ]
  [ ! -e "$BATS_TEST_TMPDIR/state/terraform.tfstate.backup" ]
  [ -e "$BATS_TEST_TMPDIR/state/key-slots.tfvars.json" ]
}

@test "FAILING FIXTURE: the migrate command keeps the local state when the copy in the bucket holds other resources or outputs" {
  for remote in \
      "{\"version\":4,\"lineage\":\"lin-new\",\"serial\":1,${OUT},\"resources\":[{\"type\":\"aws_s3_bucket\",\"name\":\"durable\",\"instances\":[{\"attributes\":{\"id\":\"other\"}}]}]}" \
      "{\"version\":4,\"lineage\":\"lin-new\",\"serial\":1,${RES},\"outputs\":{}}" \
      ''; do
    rm -rf "$BATS_TEST_TMPDIR/state" "$REC/remote.tfstate" "$REC/obj"
    mkdir -p "$BATS_TEST_TMPDIR/state"; printf '%s\n' "$STATE_JSON" > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
    [ -z "$remote" ] || printf '%s\n' "$remote" > "$REC/remote.tfstate"
    run "$REPO_ROOT/scripts/stage0-store.sh" migrate prod "$BATS_TEST_TMPDIR/state"
    [ "$status" -eq 2 ] || { echo "$remote: $output"; false; }
    [[ "$output" == *"The local state stays"* ]]
    [ -s "$BATS_TEST_TMPDIR/state/terraform.tfstate" ]
  done
}

@test "a second migrate after a move moves nothing, checks the copy, and deletes the local state" {
  mkdir -p "$REC/obj/zeroroot-ai-staging-durable-447184491447/tfstate/stage0"
  printf '%s\n' "$MIGRATED_JSON" > "$REC/obj/zeroroot-ai-staging-durable-447184491447/tfstate/stage0/terraform.tfstate"
  mkdir -p "$BATS_TEST_TMPDIR/state"; printf '%s\n' "$STATE_JSON" > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
  echo '{}' > "$BATS_TEST_TMPDIR/state/key-slots.tfvars.json"
  run "$REPO_ROOT/scripts/stage0-store.sh" migrate staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$REC/terraform.args" ]
  grep -q "key-slots.tfvars.json" "$REC/uploads"
  [ ! -e "$BATS_TEST_TMPDIR/state/terraform.tfstate" ]
}

@test "FAILING FIXTURE: the migrate command refuses when the new key already holds another state" {
  remote_state staging
  printf '%s\n' '{"version":4,"lineage":"x","serial":3,"resources":[],"outputs":{}}' \
    > "$REC/obj/zeroroot-ai-staging-durable-447184491447/tfstate/stage0/terraform.tfstate"
  mkdir -p "$BATS_TEST_TMPDIR/state"; printf '%s\n' "$STATE_JSON" > "$BATS_TEST_TMPDIR/state/terraform.tfstate"
  run "$REPO_ROOT/scripts/stage0-store.sh" migrate staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 2 ]
  [[ "$output" == *"The local state stays"* ]]
  [ ! -e "$REC/terraform.args" ]
  [ -s "$BATS_TEST_TMPDIR/state/terraform.tfstate" ]
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

@test "FAILING FIXTURE: the pull command refuses an env whose keyring secret holds no value yet" {
  run "$REPO_ROOT/scripts/stage0-store.sh" pull staging "$BATS_TEST_TMPDIR/state"
  [ "$status" -eq 2 ]
  [[ "$output" == *"holds no keyring yet"* ]]
}

@test "the bucket policy denies tfstate/stage0/ to every principal but the rotation role and the operator roles" {
  f="$REPO_ROOT/substrate/gibson-bootstrap/bucket.tf"
  grep -q 'DenyStage0StateToEveryoneElse' "$f"
  grep -q 'aws_iam_role.rotation\[0\].arn' "$f"
  grep -q 'stage0_state_principal_role_names' "$f"
}

@test "the rotation role reads and writes the keyring secret of its environment and no other secret value" {
  f="$REPO_ROOT/substrate/gibson-bootstrap/rotation-role.tf"
  grep -q 'ReadAndWriteTheKeyring' "$f"
  grep -q 'aws_secretsmanager_secret.keyring.arn' "$f"
  # No statement grants GetSecretValue or PutSecretValue on a wildcard resource.
  run grep -nE 'secretsmanager:(Get|Put)SecretValue' "$f"
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "the keyring reader role reads one secret, and the secret policy lets both roles in" {
  r="$REPO_ROOT/substrate/gibson-bootstrap/keyring-reader-role.tf"
  grep -q 'secretsmanager:GetSecretValue' "$r"
  run grep -c 'PutSecretValue' "$r"
  [ "$output" = 0 ]
  s="$REPO_ROOT/substrate/gibson-bootstrap/keyring-secret.tf"
  grep -q 'aws_iam_role.rotation\[0\].arn' "$s"
  grep -q 'aws_iam_role.keyring_reader\[0\].arn' "$s"
  run grep -rn 'keyring_in_aws' "$REPO_ROOT/substrate" "$REPO_ROOT/scripts"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
}
