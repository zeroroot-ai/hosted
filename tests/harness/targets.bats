#!/usr/bin/env bats
#
# targets.bats — the roots under targets/ go before the stage 1 network they
# join (scripts/lib/targets.sh).
#
# Measured 2026-10-06: the staging teardown could not delete the subnet, the
# gateway and the node security group, because the goat target was still in
# them and no verb knew that it existed.
#
# Run:
#   bats tests/harness/targets.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  WORK="$(mktemp -d)"
  export REPO="$WORK/repo" AWS_REGION=us-east-1 CALLS="$WORK/calls"
  mkdir -p "$REPO/targets/goat/envs" "$REPO/targets/other/envs" "$WORK/bin"
  : > "$REPO/targets/goat/envs/staging.tfvars"
  : > "$REPO/targets/other/envs/drill.tfvars"
  : > "$CALLS"
  # A terraform that records each call. `state list` prints STATE_LIST, and
  # `destroy` exits DESTROY_RC.
  cat > "$WORK/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  *"state list"*) printf '%b' "${STATE_LIST:-}" ;;
  *" destroy "*) exit "${DESTROY_RC:-0}" ;;
esac
exit 0
EOF
  chmod +x "$WORK/bin/terraform"
  export PATH="$WORK/bin:$PATH"
  log() { echo "$*"; }
  # shellcheck source=../../scripts/lib/targets.sh
  . "$REPO_ROOT/scripts/lib/targets.sh"
}

teardown() { rm -rf "$WORK"; }

@test "a target of the environment with resources in state is destroyed from its own state key" {
  STATE_LIST='data.aws_vpc.platform\naws_instance.goat\naws_security_group.goat\n' \
    run targets_destroy staging zeroroot-ai-staging-durable-1
  [ "$status" -eq 0 ]
  grep -q -- '-chdir=.*/targets/goat/ init .*key=tfstate/targets/goat/terraform.tfstate.*bucket=zeroroot-ai-staging-durable-1' "$CALLS"
  grep -q -- '-chdir=.*/targets/goat/ destroy -auto-approve -input=false -var-file=envs/staging.tfvars' "$CALLS"
  [[ "$output" == *"destroying 2 resources"* ]]
}

@test "a target of another environment is not touched" {
  STATE_LIST='aws_instance.x\n' run targets_destroy staging bucket
  [ "$status" -eq 0 ]
  # `! cmd` is inert in bats, so each negative assertion reads a status.
  run grep -q 'targets/other' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "an empty state is skipped, so a second teardown run is quiet" {
  STATE_LIST='data.aws_vpc.platform\n' run targets_destroy staging bucket
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing in state"* ]]
  run grep -q ' destroy ' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "FAILING FIXTURE: a destroy that fails stops the teardown before stage 1" {
  STATE_LIST='aws_instance.goat\n' DESTROY_RC=1 run targets_destroy staging bucket
  [ "$status" -ne 0 ]
  [[ "$output" == *"target goat: terraform destroy failed"* ]]
}

@test "the EC2 teardown destroys the targets before it destroys stage 1" {
  # Compare code lines only. A comment that names a step is not the step.
  script="$REPO_ROOT/scripts/teardown-ec2.sh"
  code() { grep -nvE '^[[:space:]]*#' "$script" | grep -E "$1" | head -1 | cut -d: -f1; }
  t=$(code '^[0-9]+:targets_destroy ')
  d=$(code 'terraform -chdir="\$EC2_DIR" destroy')
  [ -n "$t" ]
  [ -n "$d" ]
  [ "$t" -lt "$d" ]
}

@test "no target root pins a network id of stage 1" {
  # A recreate makes new ids. A pinned id names a network that no longer exists.
  run grep -rnE '^[[:space:]]*(vpc_id|subnet_id|platform_node_security_group_id)[[:space:]]*=' \
      "$REPO_ROOT"/targets/*/envs/
  [ "$status" -eq 1 ]
}
