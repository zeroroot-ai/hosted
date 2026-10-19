#!/usr/bin/env bats
#
# alert-delivery.bats: test/monitoring/exit-test-alert-delivery.sh fails when
# the email integration fails, when no email leaves, and when a container is
# at its memory limit (hosted#509). Offline: kubectl is a stub. The metrics
# counter moves from "before" to "after" on the second read.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CHECK="$REPO_ROOT/test/monitoring/exit-test-alert-delivery.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/bin"; STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUBS" "$STATE"
  export STATE
  cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"get pods -l app.kubernetes.io/name=alertmanager"*) printf 'alertmanager-monitoring-0' ;;
  *"wget -qO- http://localhost:9093/metrics"*)
    n=$(cat "$STATE/reads" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STATE/reads"
    if [ "$n" -le 2 ]; then sent=3; failed=1; else sent="${STUB_SENT_AFTER:-4}"; failed="${STUB_FAILED_AFTER:-1}"; fi
    printf 'alertmanager_notifications_total{integration="email"} %s\n' "$sent"
    printf 'alertmanager_notifications_failed_total{integration="email",reason="other"} %s\n' "$failed"
    printf 'alertmanager_notifications_total{integration="webhook"} 99\n' ;;
  *"--post-data"*) echo "$args" > "$STATE/posted" ;;
  *"top pods"*) printf 'prometheus-0 prometheus 30m %s\nalertmanager-monitoring-0 alertmanager 2m 20Mi\n' "${STUB_PROM_MEM:-900Mi}" ;;
  *"get pods -o json"*)
    # STUB_PAD bytes of annotation make the JSON larger than one command-line
    # argument may be (128 KiB), as the pod list of staging is (hosted#675).
    pad="$(head -c "${STUB_PAD:-0}" /dev/zero | tr '\0' a)"
    printf '{"items":[{"metadata":{"name":"prometheus-0","annotations":{"pad":"%s"}},' "$pad"
    printf '"spec":{"containers":[{"name":"prometheus","resources":{"limits":{"memory":"1536Mi"}}}]}},{"metadata":{"name":"alertmanager-monitoring-0"},"spec":{"containers":[{"name":"alertmanager","resources":{"limits":{"memory":"128Mi"}}}]}}]}' ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
exit 0
STUB
  chmod +x "$STUBS/kubectl"
  export PATH="$STUBS:$PATH" DELIVERY_WAIT=1 PROBE_ID=bats-probe
}

@test "an email that leaves and a stack inside its limits pass, with the numbers printed" {
  run bash "$CHECK"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the relay accepted the email (notifications 3 -> 4"* ]]
  [[ "$output" == *"prometheus-0/prometheus: 900Mi of 1536Mi"* ]]
  [[ "$output" == *"monitoring total: 920Mi"* ]]
  grep -q 'AlertDeliveryProbe' "$STATE/posted"
  grep -q 'bats-probe' "$STATE/posted"
}

@test "FAILING FIXTURE: a failed email notification fails the test" {
  STUB_SENT_AFTER=3 STUB_FAILED_AFTER=2 run bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the email integration failed 1 time(s)"* ]]
}

@test "FAILING FIXTURE: no email within the wait fails the test" {
  STUB_SENT_AFTER=3 run bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no email notification within 1s"* ]]
}

@test "FAILING FIXTURE: a container at its memory limit fails, and names the fallback" {
  STUB_PROM_MEM=1536Mi run bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"prometheus-0/prometheus 1536Mi >= 1536Mi"* ]]
  [[ "$output" == *"fallback of ADR-0083"* ]]
}

@test "a pod list larger than one command-line argument passes (hosted#675)" {
  STUB_PAD=300000 run bash "$CHECK"
  echo "${output:0:2000}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"prometheus-0/prometheus: 900Mi of 1536Mi"* ]]
}
