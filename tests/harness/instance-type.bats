#!/usr/bin/env bats
#
# instance-type.bats: the drill environment accepts an instance type from one
# list, and no other environment accepts one (hosted#448).
#
# Offline. Each refusal fires before preflight and before Terraform.
#
# Run:
#   bats tests/harness/instance-type.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
EC2_DIR="$REPO_ROOT/bootstrap/ec2/gibson"
CHECK="$REPO_ROOT/scripts/check-instance-type.sh"

@test "FAILING FIXTURE: a type that is not on the list is refused" {
  run "$CHECK" drill m7i.48xlarge
  [ "$status" -eq 2 ]
  [[ "$output" == *"INSTANCE_TYPE=m7i.48xlarge is not permitted for ENV=drill"* ]]
}

@test "a prefix of a listed type is refused: the match is the whole name" {
  run "$CHECK" drill m8i
  [ "$status" -eq 2 ]
  run "$CHECK" drill m8i.2xlarge.evil
  [ "$status" -eq 2 ]
}

@test "each listed type is accepted" {
  count=0
  while IFS= read -r t; do
    run "$CHECK" drill "$t"
    [ "$status" -eq 0 ]
    count=$((count + 1))
  done < <(grep -vE '^[[:space:]]*(#|$)' "$EC2_DIR/envs/drill.instance-types")
  # The loop must have looked at something.
  [ "$count" -ge 2 ]
}

@test "the default type of drill.tfvars is on the list" {
  default="$(sed -n 's/^instance_type *= *"\(.*\)"/\1/p' "$EC2_DIR/envs/drill.tfvars")"
  [ -n "$default" ]
  run "$CHECK" drill "$default"
  [ "$status" -eq 0 ]
}

@test "the list holds a type with nested virtualization, for the setec proofs" {
  grep -qE '^m8i\.' "$EC2_DIR/envs/drill.instance-types"
}

@test "a permanent environment accepts no instance type" {
  [ ! -e "$EC2_DIR/envs/staging.instance-types" ]
  run "$CHECK" staging m8i.2xlarge
  [ "$status" -eq 2 ]
  [[ "$output" == *"ENV=staging accepts no INSTANCE_TYPE"* ]]
}

@test "an empty list is refused, not read as permission" {
  mkdir -p "$BATS_TEST_TMPDIR/envs"
  printf '# nothing\n\n' > "$BATS_TEST_TMPDIR/envs/drill.instance-types"
  INSTANCE_TYPES_DIR="$BATS_TEST_TMPDIR/envs" run "$CHECK" drill m6a.2xlarge
  [ "$status" -eq 2 ]
  [[ "$output" == *"lists no instance type"* ]]
}

@test "make recreate refuses a type that is not on the list, before preflight" {
  run make -C "$REPO_ROOT" recreate ENV=drill INSTANCE_TYPE=m7i.48xlarge
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not permitted for ENV=drill"* ]]
  [[ "$output" != *"preflight"* ]]
}

@test "make recreate refuses a type for staging, before preflight" {
  run make -C "$REPO_ROOT" recreate ENV=staging INSTANCE_TYPE=m8i.2xlarge
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENV=staging accepts no INSTANCE_TYPE"* ]]
}

@test "the recreate script checks the type before it starts Terraform" {
  s="$REPO_ROOT/scripts/recreate-ec2.sh"
  code() { grep -nvE '^[[:space:]]*#' "$s" | grep -E "$1" | head -1 | cut -d: -f1; }
  check=$(code 'check-instance-type\.sh')
  tf=$(code 'terraform -chdir')
  [ -n "$check" ] && [ -n "$tf" ]
  [ "$check" -lt "$tf" ]
  # The type is in TF_ARGS, which each apply of the run passes.
  grep -q 'TF_ARGS+=( -var="instance_type=${INSTANCE_TYPE}" )' "$s"
}

@test "the drill workflow passes the dispatch input to each recreate, and checks it first" {
  w="$REPO_ROOT/.github/workflows/drill.yml"
  run python3 - "$w" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get("on") or w.get(True)
inp = on["workflow_dispatch"]["inputs"]["instance_type"]
assert inp["default"] == "", "the default must be empty, so the tfvars type applies"
job = w["jobs"]["up"]
for name in ("up", "restore"):
    assert w["jobs"][name]["env"]["INSTANCE_TYPE"] == "${{ inputs.instance_type }}", name
steps = job["steps"]
runs = [s.get("run", "") for s in steps]
check = next(i for i, r in enumerate(runs) if "check-instance-type.sh" in r)
creds = next(i for i, s in enumerate(steps) if s.get("uses") == "./.github/actions/stage0-setup")
assert check < creds, "the type check must run before the AWS credential"
allruns = [s.get("run", "") for j in ("up", "restore") for s in w["jobs"][j]["steps"]]
recreates = [l for r in allruns for l in r.splitlines() if "make recreate" in l]
assert len(recreates) == 2, recreates
for l in recreates:
    assert 'INSTANCE_TYPE="${INSTANCE_TYPE}"' in l, l
PY
  [ "$status" -eq 0 ]
}

@test "nested virtualization follows the instance family, and the node is checked for /dev/kvm" {
  grep -q 'nested_virtualization = "enabled"' "$EC2_DIR/main.tf"
  grep -q 'output "nested_virtualization"' "$EC2_DIR/outputs.tf"
  grep -q 'test -c /dev/kvm' "$REPO_ROOT/scripts/recreate-ec2.sh"
}

@test "FAILING FIXTURE: the nested_virtualization output reads the instance, so a targeted apply writes it" {
  # A targeted apply writes no output that depends on no targeted resource. The
  # output read the local and was "not found" after phase 1 (2026-10-06).
  body=$(awk '/^output "nested_virtualization"/,/^}/' "$EC2_DIR/outputs.tf" | grep -vE '^[[:space:]]*#')
  [[ "$body" == *"aws_instance.node"* ]]
  run grep -E '^[[:space:]]*value[[:space:]]*=[[:space:]]*local\.nested_virtualization[[:space:]]*$' "$EC2_DIR/outputs.tf"
  [ "$status" -eq 1 ]
}

@test "FAILING FIXTURE: an unreadable nested_virtualization output stops the recreate" {
  grep -q 'reported no nested_virtualization output' "$REPO_ROOT/scripts/recreate-ec2.sh"
  run grep -E 'if \[ "\$\(terraform -chdir="\$EC2_DIR" output -raw nested_virtualization\)"' "$REPO_ROOT/scripts/recreate-ec2.sh"
  [ "$status" -eq 1 ]
}

@test "the reaper selects by the Environment tag, never by instance type" {
  r="$REPO_ROOT/scripts/reap-throwaway.sh"
  grep -q 'Name=tag:Environment,Values=${ENV_NAME}' "$r"
  run grep -nE 'instance-type|InstanceType' "$r"
  [ "$status" -ne 0 ]
}
