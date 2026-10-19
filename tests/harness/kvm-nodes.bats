#!/usr/bin/env bats
#
# kvm-nodes.bats: a sandbox fleet node with no /dev/kvm fails the EKS bringup
# (hosted#446). Offline: kubectl is a stub.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$REPO_ROOT/bootstrap/eks/gibson/scripts/verify-kvm-nodes.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/bin"; mkdir -p "$STUBS"
  cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get nodes -l"*) printf '%s' "${STUB_NODES-node-a}"; exit 0 ;;
  *"jsonpath={.status.phase}"*) printf '%s' "${STUB_PHASE:-Succeeded}"; exit 0 ;;
  *" logs "*) printf '%s' "${STUB_LOG-kvm-present}"; exit 0 ;;
  *"apply -f -"*) cat >/dev/null; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
exit 0
STUB
  chmod +x "$STUBS/kubectl"
  export PATH="$STUBS:$PATH" KVM_TIMEOUT=3
}

@test "FAILING FIXTURE: a fleet node with no /dev/kvm fails the check" {
  STUB_PHASE=Failed STUB_LOG="" run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"node node-a has no /dev/kvm"* ]]
}

@test "a cluster with no fleet node fails the check" {
  STUB_NODES="" run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no node carries setec.zeroroot.ai/sandbox-host=true"* ]]
}

@test "a fleet node with /dev/kvm passes" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"node node-a exposes /dev/kvm"* ]]
}

@test "the EKS recreate runs the check, and the EC2 recreate keeps its own" {
  grep -q 'verify-kvm-nodes.sh' "$REPO_ROOT/scripts/recreate-aws.sh"
  grep -q 'test -c /dev/kvm' "$REPO_ROOT/scripts/recreate-ec2.sh"
}

@test "the workload launch template turns nested virtualization on, and the system template does not" {
  tf="$REPO_ROOT/bootstrap/eks/gibson/modules/cluster/main.tf"
  sys=$(grep -n 'resource "aws_launch_template" "system"' "$tf" | cut -d: -f1)
  wl=$(grep -n 'resource "aws_launch_template" "workload"' "$tf" | cut -d: -f1)
  nv=$(grep -n 'nested_virtualization = "enabled"' "$tf" | cut -d: -f1)
  [ "$(printf '%s\n' "$nv" | wc -l)" -eq 1 ]
  [ "$nv" -gt "$wl" ]
  [ "$wl" -gt "$sys" ]
}

# gibson#991, charts#413, charts#414: the kind node of every exit test runs the
# setec launcher, so it mounts /dev/kvm from the host. The config is the
# heredoc in scripts/recreate-kind.sh, parsed as YAML here.
kind_config() {
  awk '/--config=- <<.KIND.$/{f=1;next} /^KIND$/{f=0} f' "$1"
}

@test "the kind node mounts /dev/kvm from the host" {
  run python3 -c '
import sys, yaml
cfg = yaml.safe_load(sys.stdin.read())
mounts = [m for n in cfg["nodes"] for m in n.get("extraMounts", [])]
ok = any(m.get("hostPath") == "/dev/kvm" and m.get("containerPath") == "/dev/kvm" for m in mounts)
sys.exit(0 if ok else 1)' < <(kind_config "$REPO_ROOT/scripts/recreate-kind.sh")
  [ "$status" -eq 0 ]
}

@test "FAILING FIXTURE: a kind config with no /dev/kvm mount fails the same check" {
  sed '/extraMounts:/,/containerPath: \/dev\/kvm/d' "$REPO_ROOT/scripts/recreate-kind.sh" > "$BATS_TEST_TMPDIR/recreate-kind.sh"
  run python3 -c '
import sys, yaml
cfg = yaml.safe_load(sys.stdin.read())
mounts = [m for n in cfg["nodes"] for m in n.get("extraMounts", [])]
sys.exit(0 if any(m.get("hostPath") == "/dev/kvm" for m in mounts) else 1)' < <(kind_config "$BATS_TEST_TMPDIR/recreate-kind.sh")
  [ "$status" -eq 1 ]
}

@test "the kind recreate stops on a host with no /dev/kvm, before it creates the cluster" {
  local check create
  check="$(grep -n '\[ -c /dev/kvm \]' "$REPO_ROOT/scripts/recreate-kind.sh" | head -1 | cut -d: -f1)"
  create="$(grep -n '^kind create cluster' "$REPO_ROOT/scripts/recreate-kind.sh" | head -1 | cut -d: -f1)"
  [ -n "$check" ] && [ -n "$create" ]
  [ "$check" -lt "$create" ]
}
