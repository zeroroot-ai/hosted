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

# --- targets_apply -----------------------------------------------------------
# The recreate brings up each target of the environment after the network it
# joins, from the same durable bucket the teardown reads (hosted, gibson#496).
# An aws that answers for the SSM parameter: AWS_SSM_RC is its exit code.
apply_setup() {
  cat > "$WORK/bin/aws" <<'EOF2'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
exit "${AWS_SSM_RC:-0}"
EOF2
  chmod +x "$WORK/bin/aws"
  cat > "$WORK/bin/terraform" <<'EOF2'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  *" apply "*) exit "${APPLY_RC:-0}" ;;
  *"output -raw instance_id"*) [ -z "${NO_OUTPUT:-}" ] || exit 1; echo i-0abc ;;
esac
exit 0
EOF2
  chmod +x "$WORK/bin/terraform"
  printf 'deploy_token_parameter_name = "/zeroroot-ai/staging/goat/gitlab-deploy-token"\n' > "$REPO/targets/goat/envs/staging.tfvars"
}

@test "a target of the environment is applied from its own state key, with its own var file" {
  apply_setup
  run targets_apply staging zeroroot-ai-staging-durable-1
  [ "$status" -eq 0 ]
  grep -q -- '-chdir=.*/targets/goat/ init .*key=tfstate/targets/goat/terraform.tfstate.*bucket=zeroroot-ai-staging-durable-1' "$CALLS"
  grep -q -- '-chdir=.*/targets/goat/ apply -auto-approve -input=false -var-file=envs/staging.tfvars' "$CALLS"
  [[ "$output" == *"instance i-0abc"* ]]
}

@test "a target of another environment is not applied" {
  apply_setup
  run targets_apply staging bucket
  [ "$status" -eq 0 ]
  run grep -q 'targets/other' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "FAILING FIXTURE: a missing deploy token parameter stops the apply before terraform runs" {
  apply_setup
  AWS_SSM_RC=254 run targets_apply staging bucket
  [ "$status" -ne 0 ]
  [[ "$output" == *"the SSM parameter /zeroroot-ai/staging/goat/gitlab-deploy-token does not exist"* ]]
  run grep -q 'targets/goat' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "FAILING FIXTURE: an apply that fails stops the recreate" {
  apply_setup
  APPLY_RC=1 run targets_apply staging bucket
  [ "$status" -ne 0 ]
  [[ "$output" == *"target goat: terraform apply failed"* ]]
}

@test "FAILING FIXTURE: an applied root that reports no instance id fails" {
  apply_setup
  NO_OUTPUT=1 run targets_apply staging bucket
  [ "$status" -ne 0 ]
  [[ "$output" == *"the root reports no instance_id"* ]]
}

@test "the EC2 recreate applies the targets after stage 1 phase 1 and before Argo CD" {
  # Compare code lines only. A comment that names a step is not the step.
  script="$REPO_ROOT/scripts/recreate-ec2.sh"
  code() { grep -nvE '^[[:space:]]*#' "$script" | grep -E "$1" | head -1 | cut -d: -f1; }
  p1=$(code 'apply -auto-approve "\$\{TF_ARGS\[@\]\}" "\$\{TF_TARGETS\[@\]\}"')
  t=$(code '^[0-9]+:targets_apply ')
  p2=$(code 'kubeconfig_path=.*KUBECONFIG_PATH.*\\$|-var="kubeconfig_path=')
  [ -n "$p1" ]
  [ -n "$t" ]
  [ -n "$p2" ]
  [ "$p1" -lt "$t" ]
  [ "$t" -lt "$p2" ]
}

# The role of a target node holds only what the node needs. A break-out reaches
# it, so no target attaches the managed SSM policy, grants a KMS action, or
# reads a parameter by a wildcard.
role_too_wide() { # <main.tf>: prints each line that makes the role wider than it may be
  grep -nE '^[^#]*(AmazonSSMManagedInstanceCore|"kms:|ssm:GetParameter"|ssm:GetParametersByPath|parameter/?\*|parameter\$\{[^}]*\}\*)' "$1"
}

@test "no target role attaches the managed SSM policy, grants KMS, or reads a parameter by wildcard" {
  for f in "$REPO_ROOT"/targets/*/main.tf; do
    run role_too_wide "$f"
    [ "$status" -eq 1 ] || { echo "$f: $output"; false; }
  done
}

@test "FAILING FIXTURE: a role that attaches the managed policy or grants a wide read is refused" {
  printf 'policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"\n' > "$WORK/bad1.tf"
  printf 'actions = ["kms:Decrypt"]\n' > "$WORK/bad2.tf"
  printf 'resources = ["arn:aws:ssm:us-east-1:1:parameter/*"]\n' > "$WORK/bad3.tf"
  printf 'actions = ["ssm:GetParameter"]\n' > "$WORK/bad4.tf"
  for f in "$WORK"/bad*.tf; do
    run role_too_wide "$f"
    [ "$status" -eq 0 ] || { echo "$f was accepted"; false; }
  done
}
