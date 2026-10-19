#!/usr/bin/env bats
#
# ec2-node-labels.bats: each k3s node of an EC2 env registers with its EC2
# instance type in node.kubernetes.io/instance-type (hosted#676). The k3s
# cloud controller keeps that label and writes "k3s" only when it is absent.
# setec places a restore by this label, and the CPU template exit test reads
# it. Offline: it reads the templates and main.tf.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
EC2="$REPO_ROOT/bootstrap/ec2/gibson"

# labels_type <template>: the template starts k3s with the instance-type label
# from the template variable instance_type.
labels_type() {
  grep -qE '^    --node-label "node\.kubernetes\.io/instance-type=\$\{instance_type\}"' "$1"
}

@test "the server and the agent register with their EC2 instance type" {
  labels_type "$EC2/templates/node-init.sh.tftpl"
  labels_type "$EC2/templates/agent-init.sh.tftpl"
}

@test "main.tf hands var.instance_type to both templates" {
  [ "$(grep -cE '^    instance_type += var\.instance_type$' "$EC2/main.tf")" -eq 2 ]
}

@test "FAILING FIXTURE: a template with no instance-type label fails the check" {
  fixture="$BATS_TEST_TMPDIR/node-init.sh.tftpl"
  grep -v 'node.kubernetes.io/instance-type' "$EC2/templates/node-init.sh.tftpl" > "$fixture"
  run labels_type "$fixture"
  [ "$status" -ne 0 ]
}
