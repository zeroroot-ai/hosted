#!/usr/bin/env bats
#
# cilium.bats: each bringup fails when Cilium is absent or not ready
# (hosted#436, ADR-0083).
#
# Offline. kubectl and helm are stubs, so the suite measures the library and
# not a cluster.
#
# Run:
#   bats tests/harness/cilium.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  STUBS="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUBS"
  # kubectl answers from three variables: whether the CRD exists, whether the
  # rollout is done, and the two counters of the DaemonSet.
  cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get crd ciliumnetworkpolicies.cilium.io"*) [ "${STUB_CRD:-yes}" = yes ]; exit $? ;;
  *"rollout status daemonset/cilium"*)         [ "${STUB_ROLLOUT:-yes}" = yes ]; exit $? ;;
  *"desiredNumberScheduled"*)                  printf '%s' "${STUB_DESIRED-1}"; exit 0 ;;
  *"numberReady"*)
    # STUB_READY_AFTER=n: the first n reads answer 0, as an agent that is not
    # ready yet right after a finished rollout (signup run 38347993006).
    n=$(cat "$BATS_TEST_TMPDIR/ready.reads" 2>/dev/null || echo 0); echo $((n+1)) > "$BATS_TEST_TMPDIR/ready.reads"
    if [ "$n" -lt "${STUB_READY_AFTER:-0}" ]; then printf '0'; else printf '%s' "${STUB_READY-1}"; fi
    exit 0 ;;
  *"tofqdns-dns-reject-response-code"*)        printf '%s' "${STUB_REJECT-nameError}"; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
exit 0
STUB
  cat > "$STUBS/helm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HELM_ARGS_FILE"
exit "${STUB_HELM_RC:-0}"
STUB
  chmod +x "$STUBS/kubectl" "$STUBS/helm"
  export HELM_ARGS_FILE="$BATS_TEST_TMPDIR/helm.args"
  # The agent count is polled; a fixture must not wait the real 300 s.
  export CILIUM_AGENTS_READY_SECONDS=2 CILIUM_AGENTS_POLL_SECONDS=0
  export PATH="$STUBS:$PATH"
  # shellcheck source=../../scripts/lib/cilium.sh
  . "$REPO_ROOT/scripts/lib/cilium.sh"
}

@test "FAILING FIXTURE: a cluster with no CiliumNetworkPolicy CRD is refused" {
  STUB_CRD=no run cilium_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"the CiliumNetworkPolicy CRD is absent"* ]]
}

@test "FAILING FIXTURE: an agent that is not ready is refused" {
  STUB_ROLLOUT=no run cilium_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"the agent DaemonSet kube-system/cilium is not ready"* ]]
}

@test "FAILING FIXTURE: a DaemonSet that selects no node is not a ready agent" {
  STUB_DESIRED=0 STUB_READY=0 run cilium_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"0 of 0 agents are ready"* ]]
}

@test "FAILING FIXTURE: a DNS proxy that answers a denied lookup with REFUSED is refused" {
  STUB_REJECT=refused run cilium_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"answers a denied lookup with 'refused', not nameError"* ]]
}

@test "FAILING FIXTURE: a DNS proxy with the default answer is refused" {
  STUB_REJECT= run cilium_verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"with 'refused', not nameError"* ]]
}

@test "the shared values make a denied lookup answer NXDOMAIN" {
  run python3 -c 'import sys,yaml; v=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if v["dnsProxy"]["dnsRejectResponseCode"]=="nameError" else 1)' "$REPO_ROOT/bootstrap/cilium/values.yaml"
  [ "$status" -eq 0 ]
}

@test "a cluster with the CRD and each agent ready passes" {
  STUB_DESIRED=2 STUB_READY=2 run cilium_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 of 2 agents are ready"* ]]
}

@test "the install uses the one pin and the shared values" {
  run cilium_install kind
  [ "$status" -eq 0 ]
  pin="$(tr -d '[:space:]' < "$REPO_ROOT/bootstrap/cilium/VERSION")"
  [ -n "$pin" ]
  args="$(cat "$HELM_ARGS_FILE")"
  [[ "$args" == *"--version $pin "* ]]
  [[ "$args" == *"-f $REPO_ROOT/bootstrap/cilium/values.yaml"* ]]
  [[ "$args" == *"--namespace kube-system"* ]]
}

@test "the install passes the extra arguments of the caller" {
  run cilium_install kind --set k8sServiceHost=gibson-control-plane
  [ "$status" -eq 0 ]
  [[ "$(cat "$HELM_ARGS_FILE")" == *"--set k8sServiceHost=gibson-control-plane"* ]]
}

@test "a flavor with a values file adds that file" {
  run cilium_install k3d
  [ "$status" -eq 0 ]
  [[ "$(cat "$HELM_ARGS_FILE")" == *"-f $REPO_ROOT/bootstrap/cilium/values-k3d.yaml"* ]]
}

@test "a failed chart install is a failure of the install" {
  STUB_HELM_RC=1 run cilium_install kind
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not install"* ]]
}

@test "FAILING FIXTURE: a pin file with no version stops the install" {
  mkdir -p "$BATS_TEST_TMPDIR/cilium"
  printf 'latest\n' > "$BATS_TEST_TMPDIR/cilium/VERSION"
  CILIUM_DIR="$BATS_TEST_TMPDIR/cilium" run cilium_install kind
  [ "$status" -ne 0 ]
  [[ "$output" == *"holds no version"* ]]
}

@test "the kind cluster starts with no default plugin, and the verb installs, verifies and proves Cilium" {
  s="$REPO_ROOT/scripts/recreate-kind.sh"
  grep -q '^  disableDefaultCNI: true$' "$s"
  code() { grep -nvE '^[[:space:]]*#' "$s" | grep -E "$1" | head -1 | cut -d: -f1; }
  create=$(code 'kind create cluster')
  install=$(code ':cilium_install kind')
  verify=$(code ':cilium_verify')
  prove=$(code ':cilium_prove_fqdn_policy')
  terraform=$(code ':terraform ')
  # One test for each line. A chain with && hides a failure in bats.
  [ -n "$create" ]
  [ -n "$install" ]
  [ -n "$verify" ]
  [ -n "$prove" ]
  [ -n "$terraform" ]
  [ "$create" -lt "$install" ]
  [ "$install" -lt "$verify" ]
  [ "$verify" -lt "$prove" ]
  # Argo CD arrives through Terraform. No pod can start before the plugin.
  [ "$prove" -lt "$terraform" ]
}

@test "the k3d cluster starts with flannel off, and its verify proves Cilium" {
  s="$REPO_ROOT/scripts/cluster-k3d.sh"
  grep -q -- '--flannel-backend=none@server:\*' "$s"
  grep -q -- '--disable-network-policy@server:\*' "$s"
  grep -q '^  cilium_install k3d' "$s"
  grep -q '^  cilium_verify ' "$s"
  grep -q '^  cilium_prove_fqdn_policy ' "$s"
}

@test "the k3s instance starts with flannel off, and the verb installs Cilium before CoreDNS and Argo CD" {
  init="$REPO_ROOT/bootstrap/ec2/gibson/templates/node-init.sh.tftpl"
  grep -q '^    --flannel-backend=none \\$' "$init"
  grep -q '^    --disable-network-policy \\$' "$init"
  s="$REPO_ROOT/scripts/recreate-ec2.sh"
  code() { grep -nvE '^[[:space:]]*#' "$s" | grep -E "$1" | head -1 | cut -d: -f1; }
  connect=$(code ':ec2_cluster_connect ')
  install=$(code ':cilium_install k3s')
  verify=$(code ':cilium_verify')
  prove=$(code ':cilium_prove_fqdn_policy')
  coredns=$(code ':coredns_publish_platform_hosts ')
  argo=$(code 'stage 1: phase 2')
  [ -n "$connect" ]
  [ -n "$install" ]
  [ -n "$verify" ]
  [ -n "$prove" ]
  [ -n "$coredns" ]
  [ -n "$argo" ]
  [ "$connect" -lt "$install" ]
  [ "$install" -lt "$verify" ]
  [ "$verify" -lt "$prove" ]
  [ "$prove" -lt "$coredns" ]
  [ "$coredns" -lt "$argo" ]
}

@test "EKS installs Cilium before the node groups, with no vpc-cni add-on and no version literal" {
  tf="$REPO_ROOT/bootstrap/eks/gibson/modules/cluster/main.tf"
  code="$(grep -vE '^[[:space:]]*#' "$tf")"
  # No add-on entry of the VPC CNI.
  run grep -E '^[[:space:]]*vpc-cni[[:space:]]*=' <<<"$code"
  [ "$status" -eq 1 ]
  grep -q 'resource "helm_release" "cilium"' <<<"$code"
  grep -q 'version    = local.cilium_version' <<<"$code"
  grep -q 'cilium_version = trimspace(file("${local.cilium_dir}/VERSION"))' <<<"$code"
  # The pin file that the release reads is the one pin.
  [ -s "$REPO_ROOT/bootstrap/eks/gibson/modules/cluster/../../../../cilium/VERSION" ]
  # Each node group waits for the release.
  [ "$(grep -c 'depends_on = \[helm_release.cilium, aws_iam_role_policy.node_cilium_eni\]' <<<"$code")" -eq 2 ]
  # The release must not wait for a node.
  grep -A8 'resource "helm_release" "cilium"' <<<"$code" | grep -q 'wait       = false'
  s="$REPO_ROOT/scripts/recreate-aws.sh"
  grep -q '^cilium_verify ' "$s"
  grep -q '^cilium_prove_fqdn_policy ' "$s"
}

@test "each substrate runs with no kube-proxy, and Cilium replaces it (hosted#446, setec#182)" {
  grep -q '^kubeProxyReplacement: true$' "$REPO_ROOT/bootstrap/cilium/values.yaml"
  grep -q '^  hostNamespaceOnly: true$' "$REPO_ROOT/bootstrap/cilium/values.yaml"
  grep -q '^  kubeProxyMode: none$' "$REPO_ROOT/scripts/recreate-kind.sh"
  grep -q -- '--disable-kube-proxy@server:\*' "$REPO_ROOT/scripts/cluster-k3d.sh"
  grep -q '^    --disable-kube-proxy \\$' "$REPO_ROOT/bootstrap/ec2/gibson/templates/node-init.sh.tftpl"
  run grep -nE '^[[:space:]]*kube-proxy[[:space:]]*=' "$REPO_ROOT/bootstrap/eks/gibson/modules/cluster/main.tf"
  [ "$status" -eq 1 ]
  # Each flavor names the API server, because no kubernetes Service answers
  # before Cilium does.
  grep -q 'k8sServiceHost=${CLUSTER}-control-plane' "$REPO_ROOT/scripts/recreate-kind.sh"
  grep -q 'k8sServiceHost=k3d-${CLUSTER}-server-0' "$REPO_ROOT/scripts/cluster-k3d.sh"
  grep -q '^k8sServiceHost: 127.0.0.1$' "$REPO_ROOT/bootstrap/cilium/values-k3s.yaml"
  # The k3s edge NodePort 443 is in the range Cilium serves.
  grep -q 'range: "80,32767"' "$REPO_ROOT/bootstrap/cilium/values-k3s.yaml"
}

@test "the proof asserts a refused connection by its exit code, not by any failure" {
  # Exit 28 is a connection with no answer. A DNS failure is exit 6, and it
  # must not read as a refused connection.
  grep -q 'if \[ "\$rc" -ne 28 \]' "$REPO_ROOT/scripts/lib/cilium.sh"
}

@test "an agent that is ready only on the second read passes (signup run 38347993006)" {
  STUB_READY_AFTER=1 run cilium_verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 of 1 agents are ready"* ]]
}
