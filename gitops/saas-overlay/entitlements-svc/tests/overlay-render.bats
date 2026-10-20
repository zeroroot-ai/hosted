#!/usr/bin/env bats
# SaaS overlay: entitlements-svc render assertions (ADR-0074 / deploy#1032).
#
# Asserts:
#   - The overlay chart renders cleanly with the CI fixture values.
#   - The closed billing image IS present (this is the SaaS overlay — it must
#     carry the closed image reference).
#   - The SPIFFE registration, Service and Deployment all render.
#   - The wait-for-spire-socket init container is present.
#
# This is the overlay-side complement to helm/gibson/tests/no-closed-refs.bats,
# which asserts the core umbrella has ZERO closed refs.
#
# Run from the chart root:
#   bats tests/overlay-render.bats

CHART_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TMP="$BATS_TEST_TMPDIR"

render_saas() {
  helm template gibson-entitlements-svc "$CHART_DIR" \
    -f "$CHART_DIR/ci/values-saas-render-test.yaml" \
    --namespace gibson \
    > "$TMP/saas.yaml" 2> "$TMP/saas.err"
}

@test "saas overlay: render succeeds with CI fixture" {
  run render_saas
  if [ "$status" -ne 0 ]; then cat "$TMP/saas.err"; fi
  [ "$status" -eq 0 ]
}

@test "saas overlay: ghcr.io/zeroroot-ai/billing image IS present (closed image belongs here)" {
  render_saas
  run grep -c 'ghcr\.io/zeroroot-ai/billing' "$TMP/saas.yaml"
  [ "$output" -gt 0 ]
}

@test "saas overlay: Deployment renders with entitlements-svc component label" {
  render_saas
  run grep -c 'app.kubernetes.io/component: entitlements-svc' "$TMP/saas.yaml"
  [ "$output" -gt 0 ]
}

@test "saas overlay: ClusterSPIFFEID registers entitlements-svc identity" {
  render_saas
  run grep -c 'gibson-platform-entitlements-svc' "$TMP/saas.yaml"
  [ "$output" -gt 0 ]
}

@test "saas overlay: Service exposes gRPC port 9091" {
  render_saas
  run grep -c 'port: 9091' "$TMP/saas.yaml"
  [ "$output" -gt 0 ]
}

@test "saas overlay: Deployment has wait-for-spire-socket init container" {
  render_saas
  run grep -c 'name: wait-for-spire-socket' "$TMP/saas.yaml"
  [ "$output" -gt 0 ]
}

@test "saas overlay: BILLING_SVID env var is wired to the daemon SPIFFE ID" {
  render_saas
  run grep -c 'name: BILLING_SVID' "$TMP/saas.yaml"
  [ "$output" -gt 0 ]
}

# The gibson namespace denies both directions by default (the core umbrella's
# gibson-namespace-default-deny). An Ingress-only policy left this pod with no
# DNS and no Postgres on EKS (staging 2026-09-11). The policy must open exactly
# two egress destinations: the cluster resolver and the platform Postgres.
# The Postgres pods accept a fixed list of core components (the umbrella's
# cnpg-instances policy). The overlay adds its own pods to that list with an
# additive policy on the Postgres pods, and grants nothing else.
# D76 (hosted#522): the core Cilium policies select pods by label. A pod
# gets labels, not a policy, so this chart ships no network policy of its own.
@test "saas overlay: the pods carry the D76 network labels, and the chart writes no network policy" {
  render_saas
  run python3 - "$TMP/saas.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
pols = [d for d in docs if d.get("kind") in ("NetworkPolicy", "CiliumNetworkPolicy", "CiliumClusterwideNetworkPolicy")]
assert not pols, "a pod gets labels, not a policy (D76): %s" % [p["metadata"]["name"] for p in pols]
dep = [d for d in docs if d.get("kind") == "Deployment"][0]
labels = dep["spec"]["template"]["metadata"]["labels"]
assert labels.get("gibson.zeroroot.ai/net-role") == "platform", labels
assert labels.get("gibson.zeroroot.ai/client-postgres") == "true", labels
assert "gibson.zeroroot.ai/platform-postgres-client" not in labels, labels
print("OK: D76 labels, and no policy")
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"OK: D76 labels, and no policy"* ]]
}

# ADR-0164, hosted#435: the daemon ID and the entitlements-svc ID are built
# from global.spire.trustDomain. No domain is held in the chart.
@test "saas overlay: both SPIFFE IDs are built from global.spire.trustDomain" {
  render_saas
  grep -q 'value: "spiffe://fixture.example/platform/daemon"' "$TMP/saas.yaml"
  grep -q 'spiffeIDTemplate: "spiffe://fixture.example/platform/entitlements-svc"' "$TMP/saas.yaml"
  run grep -c 'spiffe://zeroroot\.ai' "$TMP/saas.yaml"
  [ "$output" -eq 0 ]
}

@test "FAILING FIXTURE: a render with no trust domain fails, it never falls back" {
  run helm template gibson-entitlements-svc "$CHART_DIR" \
    -f "$CHART_DIR/ci/values-saas-render-test.yaml" \
    --set global.spire.trustDomain= --namespace gibson
  [ "$status" -ne 0 ]
  [[ "$output" == *"global.spire.trustDomain is required"* ]]
}

# Each SaaS env renders with its own values.yaml loaded first, the way its
# Application loads it.
@test "saas overlay: each env renders with the trust domain of its values.yaml" {
  local root="$CHART_DIR/../../.."
  local td
  for env in staging drill prod; do
    td="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["global"]["spire"]["trustDomain"])' \
      "$root/gitops/envs/$env/values.yaml")"
    [ -n "$td" ]
    run helm template gibson-entitlements-svc "$CHART_DIR" \
      -f "$root/gitops/envs/$env/values.yaml" \
      -f "$root/gitops/envs/$env/saas-overlay-entitlements-values.yaml" \
      --namespace gibson
    [ "$status" -eq 0 ] || { echo "$env: $output"; return 1; }
    [[ "$output" == *"value: \"spiffe://${td}/platform/daemon\""* ]] || { echo "$env has no daemon ID in ${td}"; return 1; }
  done
}

@test "saas overlay: the SPIFFE CSI volume stays out of the Velero backup (drill run 39448187284, hosted#83)" {
  render_saas
  # The exact count: this chart renders one pod with one such volume. A render
  # that loses it fails, and so does a new one that needs a decision.
  run python3 "$CHART_DIR/../check-csi-excludes.py" "$TMP/saas.yaml" --expect 1
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ok 1 SPIFFE CSI volume"* ]]
}

@test "saas overlay: FAILING FIXTURE: a pod that mounts the SPIFFE CSI volume and does not exclude it fails the check" {
  run python3 "$CHART_DIR/../check-csi-excludes.py" "$CHART_DIR/../testdata/csi-no-exclude.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"volume spire-agent-socket is not in backup.velero.io/backup-volumes-excludes"* ]]
}

@test "saas overlay: FAILING FIXTURE: a wrong count of SPIFFE CSI volumes fails the check" {
  render_saas
  run python3 "$CHART_DIR/../check-csi-excludes.py" "$TMP/saas.yaml" --expect 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 SPIFFE CSI volume(s) found, 2 expected"* ]]
}

@test "saas overlay: FAILING FIXTURE: a Job, a CronJob and a Pod with the SPIFFE CSI volume and no exclude each fail the check" {
  for kind in job cronjob pod; do
    run python3 "$CHART_DIR/../check-csi-excludes.py" "$CHART_DIR/../testdata/csi-${kind}-no-exclude.yaml"
    [ "$status" -eq 1 ] || { echo "$kind: status ${status}: $output"; false; }
    [[ "$output" == *"volume spire-agent-socket is not in backup.velero.io/backup-volumes-excludes"* ]]
  done
}

@test "saas overlay: FAILING FIXTURE: a missing input is exit 2 with a named error, never a finding" {
  run python3 "$CHART_DIR/../check-csi-excludes.py" "$TMP/does-not-exist.yaml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"check-csi-excludes: cannot read"* ]]
}
