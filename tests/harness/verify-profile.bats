#!/usr/bin/env bats
#
# verify-profile.bats — scripts/verify-profile.sh refuses a daemon that still
# has the entitlements seam (gibson#1525).
#
# No environment enforces a plan limit, and the entitlements service is
# deleted. The script runs against a live cluster, so these tests stub kubectl
# and curl. They run with no cluster and no network.
#
# Run:
#   bats tests/harness/verify-profile.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  PATH="$STUB_DIR:$PATH"
  export PATH
  # The edge address comes from here, so resolve_edge reads no Service.
  export EDGE_ADDR="192.0.2.10:443"
  export DAEMON_ENV="$BATS_TEST_TMPDIR/daemon-env.json"
  export DASHBOARD_ENV="$BATS_TEST_TMPDIR/dashboard-env.json"
  export POD_IMAGES="$BATS_TEST_TMPDIR/images.txt"

  echo '[{"name":"SIGNUP_SELF_SERVE","value":"true"}]' > "$DAEMON_ENV"
  echo '[{"name":"SIGNUP_SELF_SERVE","value":"true"},{"name":"WWW_URL","value":"https://www.example.test"}]' > "$DASHBOARD_ENV"
  echo 'ghcr.io/zeroroot-ai/billing:sha-1' > "$POD_IMAGES"

  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n gibson get configmap gibson-domains -o jsonpath={.data.externalOrigin}") echo "https://app.example.test" ;;
  "-n gibson get ns gibson") exit 0 ;;
  "config current-context") echo "kind-gibson" ;;
  "-n gibson get pods -o jsonpath="*) cat "$POD_IMAGES" ;;
  "-n gibson get deploy,statefulset -o json")
    printf '{"items":[{"metadata":{"name":"gibson-gibson-workloads"},"spec":{"template":{"spec":{"containers":[{"env":%s}]}}}},' "$(cat "$DAEMON_ENV")"
    printf '{"metadata":{"name":"gibson-dashboard"},"spec":{"template":{"spec":{"containers":[{"env":%s}]}}}}]}\n' "$(cat "$DASHBOARD_ENV")"
    ;;
  "-n gibson logs statefulset/gibson-gibson-workloads -c gibson --tail=2000") echo "daemon started" ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  cat > "$STUB_DIR/curl" <<'SH'
#!/usr/bin/env bash
printf '200'
SH
  chmod +x "$STUB_DIR/kubectl" "$STUB_DIR/curl"
}

@test "a SaaS cluster with no entitlements seam passes" {
  run bash "$REPO_ROOT/scripts/verify-profile.sh" saas
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ENTITLEMENTS_ENDPOINT absent"* ]] || { echo "$output"; false; }
  [[ "$output" == *"cluster runs a coherent saas profile"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a daemon that still dials the entitlements service fails" {
  echo '[{"name":"SIGNUP_SELF_SERVE","value":"true"},{"name":"ENTITLEMENTS_ENDPOINT","value":"gibson-entitlements-svc:9091"}]' > "$DAEMON_ENV"
  run bash "$REPO_ROOT/scripts/verify-profile.sh" saas
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"ENTITLEMENTS_ENDPOINT=gibson-entitlements-svc:9091 set on the daemon"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a daemon that enforces plan limits fails" {
  echo '[{"name":"SIGNUP_SELF_SERVE","value":"true"},{"name":"GIBSON_ENTITLEMENTS_REQUIRED","value":"true"}]' > "$DAEMON_ENV"
  run bash "$REPO_ROOT/scripts/verify-profile.sh" saas
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"GIBSON_ENTITLEMENTS_REQUIRED=true on the daemon"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a self-hosted cluster that runs the billing image fails" {
  echo '[{"name":"SIGNUP_SELF_SERVE","value":"true"}]' > "$DASHBOARD_ENV"
  run bash "$REPO_ROOT/scripts/verify-profile.sh" self-hosted
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"closed billing image is running in a self-hosted cluster"* ]] || { echo "$output"; false; }
  [[ "$output" != *"WWW_URL="* ]] || { echo "$output"; false; }
}
