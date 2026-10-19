#!/usr/bin/env bats
#
# cluster-probe.bats — proves the live-verification harness FAILS CLOSED.
#
# WHY THIS SUITE EXISTS
# ---------------------
# scripts/verify-saas-surfaces.sh (deploy#1041) and
# scripts/verify-selfhosted-seams.sh (deploy#1039) can only run against a live
# cluster. The danger with a suite like that is not that it fails — it is that
# it *passes* when there is no cluster, or when the cluster is running the other
# deployment profile, and gets read as evidence that the product works.
#
# That failure mode is already present in the tree: scripts/smoke-auth-chain.sh
# :95-99 exits 0 when the workload under test is absent. A cluster with no
# ext-authz at all produces the same green output as a healthy one.
#
# So the harness's fail-closed behaviour is itself tested, here, offline, by
# stubbing `kubectl` on PATH. These tests run with no cluster, no Docker and no
# network — which means the guarantee is checked on every merge rather than
# assumed.
#
# The contract under test:
#   exit 2 = could not run (NOT a pass)
#   exit 1 = ran, found a defect
#   exit 0 = ran, everything passed
#
# Run:
#   bats tests/harness/cluster-probe.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  PATH="$STUB_DIR:$PATH"
  export PATH
}

# write_kubectl_stub <<'SH' ... SH — installs a fake kubectl for one test.
write_kubectl_stub() {
  cat > "$STUB_DIR/kubectl"
  chmod +x "$STUB_DIR/kubectl"
}

# ---------------------------------------------------------------------------
# No cluster at all
# ---------------------------------------------------------------------------

@test "no kubectl on PATH: preflight exits 2, not 0" {
  # kubectl lives in /usr/bin, so "absent kubectl" is built as a PATH containing
  # symlinks to everything the script needs EXCEPT kubectl. dirname is required:
  # the script resolves its own lib/ directory with it before sourcing.
  nokubectl="$BATS_TEST_TMPDIR/nokubectl"
  mkdir -p "$nokubectl"
  for b in bash dirname pwd curl grep sed awk head tr sort cat date; do
    src="$(command -v "$b" 2>/dev/null || true)"
    if [ -n "$src" ] && [ -x "$src" ]; then ln -sf "$src" "$nokubectl/$b"; fi
  done
  [ -x "$nokubectl/bash" ]
  [ -x "$nokubectl/dirname" ]
  [ ! -e "$nokubectl/kubectl" ]

  run env PATH="$nokubectl" "$nokubectl/bash" "$REPO_ROOT/scripts/verify-saas-surfaces.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"kubectl not on PATH"* ]]
  [[ "$output" == *"NOT a pass"* ]]
}

@test "no current context: preflight exits 2, not 0" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  "config current-context") exit 1 ;;
  *) exit 1 ;;
esac
SH
  run bash "$REPO_ROOT/scripts/verify-saas-surfaces.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no current kubectl context"* ]]
}

@test "context set but cluster unreachable: preflight exits 2, not 0" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo "kind-gibson"; exit 0 ;;
  "cluster-info") exit 1 ;;
  *) exit 1 ;;
esac
SH
  run bash "$REPO_ROOT/scripts/verify-selfhosted-seams.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unreachable"* ]]
}

@test "cluster up but namespace absent: preflight exits 2, not 0" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo "kind-gibson"; exit 0 ;;
  "cluster-info") exit 0 ;;
  "get ns gibson") echo 'Error from server (NotFound): namespaces "gibson" not found' >&2; exit 1 ;;
  *) exit 1 ;;
esac
SH
  run bash "$REPO_ROOT/scripts/verify-saas-surfaces.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"namespace 'gibson' does not exist"* ]]
}

# ---------------------------------------------------------------------------
# The customer-cluster guard (memory: feedback_kind_clusters)
# ---------------------------------------------------------------------------

@test "customer cluster context is refused outright" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo "kind-gibson-customer"; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  run bash "$REPO_ROOT/scripts/verify-saas-surfaces.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run against the customer cluster"* ]]
}

# ---------------------------------------------------------------------------
# Profile mismatch — the subtle vacuous-pass this guards against
# ---------------------------------------------------------------------------

@test "SaaS suite refuses to run on a self-hosted cluster" {
  # No entitlements-svc Service => self-hosted. The SaaS suite must NOT report a result:
  # every marketing assertion would fail for the correct reason and read as a
  # product defect.
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo "kind-gibson"; exit 0 ;;
  "cluster-info") exit 0 ;;
  "get ns gibson") exit 0 ;;
  "-n gibson get svc -o name") echo "service/gibson-dashboard"; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  run bash "$REPO_ROOT/scripts/verify-saas-surfaces.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"running the 'self-hosted' profile"* ]]
  [[ "$output" == *"refusing to report a result"* ]]
}

@test "self-hosted suite refuses to run on a SaaS cluster" {
  # entitlements-svc present => saas.
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo "kind-gibson"; exit 0 ;;
  "cluster-info") exit 0 ;;
  "get ns gibson") exit 0 ;;
  "-n gibson get svc -o name") echo "service/gibson-entitlements-svc"; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  run bash "$REPO_ROOT/scripts/verify-selfhosted-seams.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"running the 'saas' profile"* ]]
}

# ---------------------------------------------------------------------------
# Workload absent is exit 2, never a silent skip
# ---------------------------------------------------------------------------

@test "dashboard Deployment absent: exits 2 rather than skipping the suite" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo "kind-gibson"; exit 0 ;;
  "cluster-info") exit 0 ;;
  "get ns gibson") exit 0 ;;
  "-n gibson get svc -o name") echo "service/gibson-entitlements-svc"; exit 0 ;;
  "-n gibson get deploy gibson-dashboard") echo 'Error from server (NotFound): deployments.apps "gibson-dashboard" not found' >&2; exit 1 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  run bash "$REPO_ROOT/scripts/verify-saas-surfaces.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"deploy/gibson-dashboard absent"* ]]
  [[ "$output" == *"cannot verify the dashboard login surface"* ]]
}

@test "no Envoy Service: exits 2 rather than probing a guessed address" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo "kind-gibson"; exit 0 ;;
  "cluster-info") exit 0 ;;
  "get ns gibson") exit 0 ;;
  "-n gibson get svc -o name") echo "service/gibson-entitlements-svc"; exit 0 ;;
  "-n gibson get deploy gibson-dashboard") exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  run bash "$REPO_ROOT/scripts/verify-saas-surfaces.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot determine the edge address"* ]]
}

# ---------------------------------------------------------------------------
# Neither suite can ever exit 0 without a cluster — the headline guarantee
# ---------------------------------------------------------------------------

@test "neither suite exits 0 when nothing is running" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
exit 1
SH
  for s in verify-saas-surfaces verify-selfhosted-seams; do
    run bash "$REPO_ROOT/scripts/${s}.sh"
    if [ "$status" -eq 0 ]; then
      echo "FAIL: ${s}.sh exited 0 with no cluster — this is the vacuous pass the harness exists to prevent."
      echo "$output"
      false
    fi
    [ "$status" -eq 2 ]
  done
}

@test "FAILING FIXTURE: a refused namespace read names the refusal, not an absent namespace" {
  write_kubectl_stub <<'SH'
#!/usr/bin/env bash
case "$*" in
  "config current-context") echo kind-gibson ;;
  "cluster-info") exit 0 ;;
  "get ns gibson") echo 'Error from server (Forbidden): namespaces "gibson" is forbidden' >&2; exit 1 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  run bash "$REPO_ROOT/scripts/verify-saas-surfaces.sh"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"namespace 'gibson' cannot be read on context 'kind-gibson': Error from server (Forbidden)"* ]] || { echo "$output"; false; }
}
