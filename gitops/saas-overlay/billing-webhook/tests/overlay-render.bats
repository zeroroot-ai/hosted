#!/usr/bin/env bats
# SaaS overlay: billing-webhook render assertions (ADR-0074, gibson#798/#800).
#
# Asserts:
#   - The overlay chart renders cleanly with the CI fixture values.
#   - The closed billing image IS present (this is the SaaS overlay — it must
#     carry the closed image reference).
#   - Each env wires the billing service end to end (env_wiring.py): the
#     envoy.extraRoutes entries dial Service `gibson-billing-webhook` on port
#     8090 with the stated auth mode, the dashboard carries the approved texts
#     byte for byte, the daemon accepts the billing SPIFFE ID as the one
#     signup step completer, and the OIDC client matches the pod.
#   - The receiver runs the billing-webhook binary, not entitlements-svc.
#   - Each environment value the binary requires is wired.
#   - The overlay owns the Stripe ExternalSecret, the SPIFFE identity and its
#     admission policies.
#
# This is the overlay-side complement to helm/gibson/tests/no-closed-refs.bats,
# which asserts the core umbrella has ZERO closed refs.
#
# Run from the chart root:
#   bats tests/overlay-render.bats

CHART_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
REPO_ROOT="$(cd "$CHART_DIR/../../.." && pwd)"
# The core umbrella lives in zeroroot-ai/charts since the split (ADR-0086).
# CHARTS_ROOT names its checkout, as the Makefile does; the default is the
# sibling clone.
TMP="$BATS_TEST_TMPDIR"

render_saas() {
  helm template gibson-billing-webhook "$CHART_DIR" \
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

@test "saas overlay: container runs the billing-webhook binary" {
  render_saas
  run grep -c '/usr/local/bin/billing-webhook' "$TMP/saas.yaml"
  [ "$output" -gt 0 ]
}

@test "saas overlay: Deployment renders with billing-webhook component label" {
  render_saas
  run grep -c 'app.kubernetes.io/component: billing-webhook' "$TMP/saas.yaml"
  [ "$output" -gt 0 ]
}

@test "saas overlay: Service name matches the Envoy cluster contract" {
  render_saas
  run grep -c 'name: gibson-billing-webhook' "$TMP/saas.yaml"
  [ "$output" -gt 0 ]
}

@test "saas overlay: Service port matches the Envoy cluster contract (8090)" {
  render_saas
  # The port of the Service object, read as YAML. A grep for `port: 8090`
  # matched another object too, so a broken Service port passed (hosted#413).
  run python3 - "$TMP/saas.yaml" <<'PY'
import sys, yaml
svcs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Service"]
assert len(svcs) == 1, f"want one Service, got {len(svcs)}"
ports = [p.get("port") for p in svcs[0]["spec"]["ports"]]
assert ports == [8090], f"the Service ports are {ports}, and the Envoy cluster dials 8090"
PY
  [ "$status" -eq 0 ]
}

# The billing service crosses two charts: the core chart renders the edge
# routes, the daemon config, the dashboard texts and the OIDC client from each
# env's values.yaml, and this chart renders the pod. env_wiring.py renders both
# from the env files (the core chart from CHARTS_ROOT) and compares them
# (hosted#440). The approved texts are compared byte for byte.
@test "saas overlay: each env wires the billing routes, texts, daemon and sign-in client" {
  run python3 "$CHART_DIR/tests/env_wiring.py" "$REPO_ROOT/gitops/envs"
  if [ "$status" -ne 0 ]; then echo "$output"; fi
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK billing wiring"* ]]
}

# Planted failures: each one must turn the wiring check red, or it checks
# nothing. One env copy for each case, one mutation each.
plant() {
  local case="$1" script="$2"
  rm -rf "$TMP/$case" && mkdir -p "$TMP/$case"
  cp -r "$REPO_ROOT/gitops/envs/staging" "$TMP/$case/staging"
  python3 - "$TMP/$case/staging/values.yaml" "$script" <<'PY'
import sys
path, script = sys.argv[1], sys.argv[2]
s = open(path).read()
old, new = script.split("=>", 1)
assert s.count(old) >= 1, f"the fixture text {old!r} is not in {path}"
open(path, "w").write(s.replace(old, new, 1))
PY
}

@test "saas overlay: the wiring check fails on a changed approved text" {
  plant text 'retryLabel: "Try again"=>retryLabel: "Try again."'
  run python3 "$CHART_DIR/tests/env_wiring.py" "$TMP/text"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DASHBOARD_SIGNUP_STEP_RETRY_LABEL"* ]]
}

@test "saas overlay: the wiring check fails on a route with the wrong auth mode" {
  plant auth $'path: /account\n        service: gibson-billing-webhook\n        port: 8090\n        rateLimitClass: login\n        auth: own-sign-in=>path: /account\n        service: gibson-billing-webhook\n        port: 8090\n        rateLimitClass: login\n        auth: signed-request'
  run python3 "$CHART_DIR/tests/env_wiring.py" "$TMP/auth"
  [ "$status" -eq 1 ]
  [[ "$output" == *"/account states auth"* ]]
}

@test "saas overlay: the wiring check fails on a Stripe value in the dashboard" {
  plant stripe $'    accountLink:\n=>    billing:\n      stripeExpectedMode: test\n    accountLink:\n'
  run python3 "$CHART_DIR/tests/env_wiring.py" "$TMP/stripe"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dashboard.billing is set"* ]]
}

@test "saas overlay: the wiring check fails when another identity can end the signup step" {
  plant svid 'signupStepCompleterPath: "platform/billing"=>signupStepCompleterPath: "platform/dashboard"'
  run python3 "$CHART_DIR/tests/env_wiring.py" "$TMP/svid"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GIBSON_SIGNUP_STEP_COMPLETER_SVID"* ]]
}

@test "saas overlay: the wiring check fails when the egress group leaves out the payment provider" {
  plant egress '- "https://api.stripe.com"=>- "https://api.example.com"'
  run python3 "$CHART_DIR/tests/env_wiring.py" "$TMP/egress"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not open api.stripe.com:443"* ]]
}

@test "saas overlay: the wiring check fails when the env names no billing egress group" {
  plant nogroup '    egressHostGroups:=>    unusedHostGroups:'
  run python3 "$CHART_DIR/tests/env_wiring.py" "$TMP/nogroup"
  [ "$status" -eq 1 ]
  [[ "$output" == *"policies for the egress group 'billing'"* ]]
}

@test "saas overlay: the wiring check fails when the sign-in client redirects elsewhere" {
  plant oidc '/account/callback"=>/callback"'
  run python3 "$CHART_DIR/tests/env_wiring.py" "$TMP/oidc"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gibson-billing redirects to"* ]]
}

# The binary exits 1 at boot when one of these is empty (billing
# cmd/billing-webhook/main.go, loadConfig). Each must be wired.
@test "saas overlay: the pod sets each environment value the binary requires" {
  render_saas
  run python3 - "$TMP/saas.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
dep = [d for d in docs if d.get("kind") == "Deployment"][0]
c = dep["spec"]["template"]["spec"]["containers"][0]
names = {e["name"] for e in c["env"]}
required = {
    "STRIPE_WEBHOOK_SECRET", "STRIPE_SECRET_KEY", "GIBSON_CONNECTION_ADDR",
    "GIBSON_DAEMON_SVID", "GIBSON_API_ADDR", "BILLING_SIGNUP_RETURN_URL",
    "BILLING_ACCOUNT_RETURN_URL", "OIDC_ISSUER", "OIDC_CLIENT_ID",
    "OIDC_CLIENT_SECRET", "BILLING_ACCOUNT_CALLBACK_URL",
    "SPIFFE_ENDPOINT_SOCKET", "PLANS_FILE",
}
missing = sorted(required - names)
assert not missing, f"the pod does not set {missing}"
mounts = {m["mountPath"] for m in c["volumeMounts"]}
assert {"/run/spire/sockets", "/etc/gibson/plans"} <= mounts, mounts
spec = dep["spec"]["template"]["spec"]
assert spec.get("serviceAccountName") == "gibson-billing-webhook", spec.get("serviceAccountName")
print("OK env")
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# The overlay owns the one ExternalSecret of the Stripe account. It reads the
# key the charts secret contract declares for gitops:billing, and it writes a
# Secret name that no core chart renders, so the Secret has one writer.
@test "saas overlay: the Stripe ExternalSecret reads gibson-stripe-credentials into its own Secret" {
  render_saas
  run python3 - "$TMP/saas.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
es = [d for d in docs if d.get("kind") == "ExternalSecret"]
assert len(es) == 1, f"want one ExternalSecret, got {len(es)}"
spec = es[0]["spec"]
assert spec["target"]["name"] == "gibson-billing-stripe", spec["target"]
assert spec["target"]["name"] != "gibson-stripe-credentials", "a core chart before 0.140.0 writes that Secret"
assert spec["secretStoreRef"] == {"name": "gibson-secrets", "kind": "ClusterSecretStore"}, spec["secretStoreRef"]
refs = {(d["remoteRef"]["key"], d["remoteRef"]["property"]) for d in spec["data"]}
assert refs == {("gibson-stripe-credentials", "secret_key"), ("gibson-stripe-credentials", "webhook_secret")}, refs
keys = set(spec["target"]["template"]["data"])
assert keys == {"STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"}, keys
dep = [d for d in docs if d.get("kind") == "Deployment"][0]
env = {e["name"]: e for e in dep["spec"]["template"]["spec"]["containers"][0]["env"]}
for k in ("STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"):
    assert env[k]["valueFrom"]["secretKeyRef"] == {"name": "gibson-billing-stripe", "key": k}, env[k]
print("OK stripe")
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# The SPIFFE ID of billing can end a signup step. Only the built-in
# controllers and the named workload creators may create a pod that claims it.
@test "saas overlay: the billing identity has a ClusterSPIFFEID and its own admission policies" {
  render_saas
  run python3 - "$TMP/saas.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
ids = [d for d in docs if d.get("kind") == "ClusterSPIFFEID"]
assert len(ids) == 1, ids
spec = ids[0]["spec"]
assert spec["spiffeIDTemplate"] == "spiffe://fixture.example/platform/billing", spec["spiffeIDTemplate"]
assert spec["workloadSelectorTemplates"] == ["k8s:ns:gibson", "k8s:sa:gibson-billing-webhook"], spec
vaps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "ValidatingAdmissionPolicy"}
assert set(vaps) == {"gibson-saas-billing-identity-pods", "gibson-saas-billing-identity-workloads"}, set(vaps)
for v in vaps.values():
    text = yaml.safe_dump(v)
    assert "'billing-webhook'" in text and "gibson-billing-webhook" in text, v["metadata"]["name"]
binds = [d for d in docs if d.get("kind") == "ValidatingAdmissionPolicyBinding"]
assert all(b["spec"]["validationActions"] == ["Deny"] for b in binds) and len(binds) == 2, binds
print("OK identity")
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "saas overlay: STRIPE_WEBHOOK_SECRET is wired from a Secret" {
  render_saas
  run grep -c 'name: STRIPE_WEBHOOK_SECRET' "$TMP/saas.yaml"
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
assert "gibson.zeroroot.ai/egress-internet" not in labels, "billing reaches named hosts only (D76, hosted#525): %s" % labels
assert labels.get("gibson.zeroroot.ai/egress-fqdn") == "billing", "billing reaches its egress host group: %s" % labels
assert "gibson.zeroroot.ai/platform-postgres-client" not in labels, labels
print("OK: D76 labels, and no policy")
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"OK: D76 labels, and no policy"* ]]
}

