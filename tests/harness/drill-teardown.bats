#!/usr/bin/env bats
#
# drill-teardown.bats — a throwaway environment cannot outlive its run, and a
# permanent one cannot be reaped (ADR-0095).
#
# The owner's condition for building `drill` was being 100% sure the instance
# gets torn down. One mechanism cannot carry that, because every mechanism has a
# failure it cannot see:
#
#   the instance's own ceiling    cannot cover the minute between the API
#                                 returning and cloud-init arming it
#   the workflow teardown         is skipped by a dead runner
#   terraform's own success       says nothing about what is on the bill
#   the reaper                    runs on a schedule, so it is last, not first
#
# These tests assert the mechanisms exist, that they are ordered so a wedged
# bringup still dies, and that none of them can reach staging.
#
# Run:
#   bats tests/harness/drill-teardown.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
EC2_DIR="$REPO_ROOT/bootstrap/ec2/gibson"

@test "the ceiling is armed BEFORE anything that can hang" {
  # A ceiling armed after the k3s install is a ceiling the wedged instance never
  # gets, and a wedged instance is the one that runs unbounded.
  # COMMENTS ARE NOT STEPS. The header names each step, so a plain grep finds a
  # step above the arming and this test fails on its own prose. Compare the
  # first non-comment line of each. A package install and a download can hang
  # too, so the arming comes before each of them.
  init="$EC2_DIR/templates/node-init.sh.tftpl"
  code() { grep -nvE '^[[:space:]]*#' "$init" | grep -iE "$1" | head -1 | cut -d: -f1; }
  arm=$(code 'self-terminate\.service')
  k3s=$(code 'get\.k3s\.io|INSTALL_K3S')
  pkg=$(code 'dnf install')
  dl=$(code 'curl ')
  [ -n "$arm" ] && [ -n "$k3s" ] && [ -n "$pkg" ] && [ -n "$dl" ]
  [ "$arm" -lt "$k3s" ]
  [ "$arm" -lt "$pkg" ]
  [ "$arm" -lt "$dl" ]
}

@test "the second node arms the same ceiling BEFORE its k3s join (hosted#453)" {
  init="$EC2_DIR/templates/agent-init.sh.tftpl"
  code() { grep -nvE '^[[:space:]]*#' "$init" | grep -iE "$1" | head -1 | cut -d: -f1; }
  arm=$(code 'self-terminate\.service')
  k3s=$(code 'get\.k3s\.io|INSTALL_K3S')
  [ -n "$arm" ] && [ -n "$k3s" ]
  [ "$arm" -lt "$k3s" ]
  grep -q 'OnBootSec=' "$init"
  grep -q 'on-active=20min' "$init"
  grep -q 'poweroff --force' "$init"
  # and a poweroff terminates it, like the server
  grep -A40 'resource "aws_instance" "agent"' "$EC2_DIR/main.tf" \
    | grep -q 'instance_initiated_shutdown_behavior = var.self_terminate_after_minutes > 0 ? "terminate" : "stop"'
}

@test "FAILING FIXTURE: an instance that cannot arm its ceiling still cannot run unbounded" {
  init="$EC2_DIR/templates/node-init.sh.tftpl"
  # Fail closed: a node that cannot arm the timer gets a short ceiling anyway.
  grep -q 'could not arm the self-termination timer' "$init"
  grep -q 'on-active=20min' "$init"
  # and if even that cannot be armed, it goes now
  grep -q 'poweroff --force' "$init"
  # BUT NOT IMMEDIATELY ON THE FIRST FAILURE. The first version powered off at
  # once and killed the node before its SSM agent registered, so the one run
  # that most needed diagnosing left nothing but a serial console.
  grep -q 'diagnosable and still cannot run unbounded' "$init"
}

@test "the ceiling re-arms on every boot, by construction rather than by re-running a command" {
  # A timer's OnBootSec IS the re-arm. The first version ran `shutdown -h +N`
  # from a oneshot unit, which a reboot forgets and which needs logind over
  # D-Bus to accept — not reliably up 9 seconds into boot, which is when the
  # first drill node powered itself off (i-0ce55619f367ab87c, 2026-10-01).
  grep -q 'OnBootSec=' "$EC2_DIR/templates/node-init.sh.tftpl"
  grep -q 'WantedBy=timers.target' "$EC2_DIR/templates/node-init.sh.tftpl"
  # CODE LINES ONLY. The comments above the timer explain why `shutdown -h +N`
  # was wrong, so a file-wide grep matches the explanation and fails on prose
  # describing the very thing it is checking has gone. Third time today that
  # distinction has decided a result.
  run bash -c "grep -vE '^[[:space:]]*#' '$EC2_DIR/templates/node-init.sh.tftpl' | grep -c 'shutdown -h +' || true"
  [ "$output" = "0" ]
}

@test "a poweroff terminates only when a ceiling is armed, and merely stops otherwise" {
  grep -q 'instance_initiated_shutdown_behavior = var.self_terminate_after_minutes > 0 ? "terminate" : "stop"' "$EC2_DIR/main.tf"
}

@test "FAILING FIXTURE: staging declares no ceiling, so it cannot terminate itself" {
  # The whole of ADR-0095 is that staging stays up. A ceiling in this file is the
  # estate gone after an afternoon.
  run grep -c 'self_terminate_after_minutes' "$EC2_DIR/envs/staging.tfvars"
  [ "$output" = "0" ]
  # and the default is off, so an env that forgets to say is also safe
  grep -A4 'variable "self_terminate_after_minutes"' "$EC2_DIR/variables.tf" | grep -q 'default     = 0'
}

@test "the teardown's last word is the account, not the state file" {
  # terraform destroy returning 0 and the instance leaving state are both
  # assertions about state. An Elastic IP bills more unassociated than attached
  # and state never mentions it.
  grep -q 'ec2-post-destroy-verify.sh' "$REPO_ROOT/scripts/teardown-ec2.sh"
  grep -q 'describe-addresses' "$EC2_DIR/scripts/ec2-post-destroy-verify.sh"
  grep -q 'resourcegroupstaggingapi' "$EC2_DIR/scripts/ec2-post-destroy-verify.sh"
}

@test "FAILING FIXTURE: the verify is tag-scoped, or every drill teardown would report staging as a survivor" {
  grep -q 'tag:Environment,Values=' "$EC2_DIR/scripts/ec2-post-destroy-verify.sh"
  run grep -c 'Name=instance-state-name,Values=running --query .length(Reservations' "$EC2_DIR/scripts/ec2-post-destroy-verify.sh"
  [ "$output" = "0" ]
}

@test "FAILING FIXTURE: a failed query is UNKNOWN, never a green zero" {
  grep -q 'UNKNOWN' "$EC2_DIR/scripts/ec2-post-destroy-verify.sh"
  grep -q 'An empty answer is not zero' "$EC2_DIR/scripts/ec2-post-destroy-verify.sh"
}

@test "FAILING FIXTURE: the reaper refuses every environment that is not throwaway" {
  run "$REPO_ROOT/scripts/reap-throwaway.sh" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a throwaway environment"* ]]
  run "$REPO_ROOT/scripts/reap-throwaway.sh" prod --apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a throwaway environment"* ]]
}

@test "the reaper is a dry run unless told otherwise" {
  grep -q 'APPLY="\${2:-}"' "$REPO_ROOT/scripts/reap-throwaway.sh"
  grep -q 'mode="DRY RUN"' "$REPO_ROOT/scripts/reap-throwaway.sh"
}

@test "FAILING FIXTURE: the durable bucket follows ENV, which is what keeps a drill teardown off staging's state" {
  # Both EC2 verbs share ONE terraform state key, `tfstate/ec2-gibson`, and that
  # is only safe because the BUCKET is per environment. If the bucket name ever
  # stopped deriving from ENV, `make teardown ENV=drill MODE=wipe` would init
  # against staging's state and destroy the environment the owner asked to keep.
  # Nothing else states this property, so it is stated here.
  grep -q 'zeroroot-ai-${ENV_NAME}-durable-' "$REPO_ROOT/scripts/recreate-ec2.sh"
  grep -q 'zeroroot-ai-%s-durable-%s' "$REPO_ROOT/scripts/teardown-ec2.sh"
  # and the key really is shared, so the bucket is load-bearing rather than
  # belt-and-braces
  grep -q 'tfstate/ec2-gibson/terraform.tfstate' "$REPO_ROOT/scripts/recreate-ec2.sh"
  grep -q 'tfstate/ec2-gibson/terraform.tfstate' "$REPO_ROOT/scripts/teardown-ec2.sh"
}

@test "drill declares a ceiling and staging does not: the two tfvars disagree on purpose" {
  grep -qE '^self_terminate_after_minutes = [1-9]' "$EC2_DIR/envs/drill.tfvars"
  run grep -c 'self_terminate_after_minutes' "$EC2_DIR/envs/staging.tfvars"
  [ "$output" = "0" ]
}

@test "FAILING FIXTURE: the drill workflow proves the ceiling on the live node, not from a template" {
  # A fixture can only assert that the template writes the unit. Whether the node
  # armed it is a different question and only the running instance can answer it.
  wf="$REPO_ROOT/.github/workflows/drill.yml"
  grep -q 'instanceInitiatedShutdownBehavior' "$wf"
  grep -q 'systemctl is-active self-terminate.timer' "$wf"
  grep -q 'list-timers' "$wf"
  # and the teardown cannot be skipped by a failure above it
  grep -q 'if: always()' "$wf"
}

@test "the drill workflow never names staging" {
  run grep -cE '^[^#]*ENV: staging|^[^#]*ENV=staging' "$REPO_ROOT/.github/workflows/drill.yml"
  [ "$output" = "0" ]
}
