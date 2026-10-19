#!/usr/bin/env bats
#
# node-count.bats: the drill environment accepts a node count of 1 or 2 from
# one list, and no other environment accepts one (hosted#453).
#
# Offline. Each refusal fires before preflight and before Terraform.
#
# Run:
#   bats tests/harness/node-count.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
EC2_DIR="$REPO_ROOT/bootstrap/ec2/gibson"
CHECK="$REPO_ROOT/scripts/check-node-count.sh"

@test "FAILING FIXTURE: a count that is not on the list is refused" {
  run "$CHECK" drill 3
  [ "$status" -eq 2 ]
  [[ "$output" == *"NODE_COUNT=3 is not permitted for ENV=drill"* ]]
  run "$CHECK" drill 0
  [ "$status" -eq 2 ]
}

@test "FAILING FIXTURE: a value that is not a whole count is refused" {
  run "$CHECK" drill 2x
  [ "$status" -eq 2 ]
  run "$CHECK" drill " 2"
  [ "$status" -eq 2 ]
}

@test "the list of drill holds exactly 1 and 2" {
  run bash -c "grep -vE '^[[:space:]]*(#|$)' '$EC2_DIR/envs/drill.node-counts' | tr -d '[:blank:]' | sort | tr '\n' ' '"
  [ "$output" = "1 2 " ]
  run "$CHECK" drill 1
  [ "$status" -eq 0 ]
  run "$CHECK" drill 2
  [ "$status" -eq 0 ]
}

@test "FAILING FIXTURE: a permanent environment accepts no node count" {
  [ ! -e "$EC2_DIR/envs/staging.node-counts" ]
  run "$CHECK" staging 2
  [ "$status" -eq 2 ]
  [[ "$output" == *"ENV=staging accepts no NODE_COUNT"* ]]
}

@test "an empty list is refused, not read as permission" {
  mkdir -p "$BATS_TEST_TMPDIR/envs"
  printf '# nothing\n\n' > "$BATS_TEST_TMPDIR/envs/drill.node-counts"
  NODE_COUNTS_DIR="$BATS_TEST_TMPDIR/envs" run "$CHECK" drill 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"lists no node count"* ]]
}

@test "the Terraform variable refuses the same values, and defaults to one node" {
  grep -A8 'variable "node_count"' "$EC2_DIR/variables.tf" | grep -q 'default     = 1'
  grep -A8 'variable "node_count"' "$EC2_DIR/variables.tf" | grep -q 'contains(\[1, 2\], var.node_count)'
}

@test "the second node exists only when the count is 2, and it is the same type" {
  grep -A3 'resource "aws_instance" "agent"' "$EC2_DIR/main.tf" | grep -q 'count = var.node_count - 1'
  grep -A6 'resource "aws_instance" "agent"' "$EC2_DIR/main.tf" | grep -q 'instance_type          = var.instance_type'
}

@test "a one-node cluster renders no join token, so the user data of staging does not change" {
  grep -q 'agent_token = var.node_count > 1 ? random_password.agent_token\[0\].result : ""' "$EC2_DIR/main.tf"
  grep -q '^%{ if agent_token != "" ~}' "$EC2_DIR/templates/node-init.sh.tftpl"
}

@test "the second node joins with an agent-only token, and the server token never leaves the server" {
  # The server takes the minted value as K3S_AGENT_TOKEN, which admits an
  # agent and nothing else. A K3S_TOKEN from Terraform would hand the server
  # token, which can join a server and read the datastore, to the agent.
  grep -q 'K3S_AGENT_TOKEN="${agent_token}" sh /tmp/k3s-install.sh' "$EC2_DIR/templates/node-init.sh.tftpl"
  run grep -n 'K3S_TOKEN=' "$EC2_DIR/templates/node-init.sh.tftpl"
  [ "$status" -eq 1 ]
  grep -q 'K3S_TOKEN="${agent_token}" sh /tmp/k3s-install.sh agent' "$EC2_DIR/templates/agent-init.sh.tftpl"
}

@test "the recreate verb and the drill workflow check the count before Terraform" {
  grep -q 'check-node-count.sh" "$ENV_NAME" "$NODE_COUNT"' "$REPO_ROOT/scripts/recreate-ec2.sh"
  grep -q '\-var="node_count=' "$REPO_ROOT/scripts/recreate-ec2.sh"
  grep -q 'scripts/check-node-count.sh "${ENV}" "${NODE_COUNT}"' "$REPO_ROOT/.github/workflows/drill.yml"
  grep -q 'node_count:' "$REPO_ROOT/.github/workflows/drill.yml"
}

@test "a drill dispatch with no count keeps one node" {
  # The input has a default of 1, so a dispatch that names no count keeps
  # one node.
  grep -A6 '      node_count:' "$REPO_ROOT/.github/workflows/drill.yml" | grep -q 'default: "1"'
  grep -q 'NODE_COUNT: ${{ inputs.node_count }}' "$REPO_ROOT/.github/workflows/drill.yml"
}
