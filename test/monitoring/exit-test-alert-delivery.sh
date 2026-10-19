#!/usr/bin/env bash
# exit-test-alert-delivery.sh: a test alert leaves Alertmanager by email, and
# the monitoring stack runs inside its memory limits (hosted#509, ADR-0083).
#
# Run it on a running env through the SSM forward:
#   make with-cluster ENV=<staging|drill|prod> CMD='test/monitoring/exit-test-alert-delivery.sh'
# exit-test-monitoring.yml does that on main each day.
#
# What it proves, in order:
#   1. Alertmanager takes a test alert, AlertDeliveryProbe, with a unique id.
#   2. The email integration counts one more notification and no failure.
#      That proves the relay accepted the message. The mailbox itself is
#      Google Workspace, which no CI credential reads: the owner confirms the
#      message in alerts@zeroroot.ai in the final session (release/final-session.md).
#   3. Each container in the monitoring namespace uses less memory than its
#      limit. The numbers are printed, so the measurement is on record. A
#      container over its limit fails the test: then the VictoriaMetrics
#      fallback of ADR-0083 applies.
#
# Env:
#   MON_NS          the monitoring namespace (default monitoring)
#   PROBE_ID        a unique id for the alert (default: the time)
#   DELIVERY_WAIT   seconds to wait for the notification (default 240)
# Exit: 0 proved · 1 a step failed · 2 could not run
set -euo pipefail
MON_NS="${MON_NS:-monitoring}"
PROBE_ID="${PROBE_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
DELIVERY_WAIT="${DELIVERY_WAIT:-240}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
cannot() { printf 'could not run: %s\n' "$*" >&2; exit 2; }

command -v kubectl >/dev/null 2>&1 || cannot "kubectl is not on PATH"

am_pod="$(kubectl -n "$MON_NS" get pods -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || am_pod=""
[ -n "$am_pod" ] || fail "no Alertmanager pod in namespace ${MON_NS}"

am() { kubectl -n "$MON_NS" exec "$am_pod" -c alertmanager -- "$@"; }

# metric NAME: the value of NAME{integration="email"}, 0 when absent.
metric() {
  local out
  out="$(am wget -qO- http://localhost:9093/metrics)" || cannot "could not read the Alertmanager metrics"
  printf '%s\n' "$out" | awk -v m="$1" '$1 ~ "^"m"\\{.*integration=\"email\"" {v=$2} END {print (v=="" ? 0 : v)}'
}

# --- 1 and 2: the alert leaves by email ------------------------------------
sent_before="$(metric alertmanager_notifications_total)"
failed_before="$(metric alertmanager_notifications_failed_total)"
alert="[{\"labels\":{\"alertname\":\"AlertDeliveryProbe\",\"severity\":\"info\",\"probe_id\":\"${PROBE_ID}\"},\"annotations\":{\"summary\":\"Test alert ${PROBE_ID} of exit-test-alert-delivery (hosted#509)\"}}]"
am wget -qO- --header 'Content-Type: application/json' --post-data "$alert" \
  http://localhost:9093/api/v2/alerts >/dev/null || fail "Alertmanager refused the test alert"
printf '  ✓ Alertmanager took AlertDeliveryProbe %s\n' "$PROBE_ID"

deadline=$(( $(date +%s) + DELIVERY_WAIT ))
while :; do
  sent="$(metric alertmanager_notifications_total)"
  failed="$(metric alertmanager_notifications_failed_total)"
  if awk -v a="$failed" -v b="$failed_before" 'BEGIN {exit !(a > b)}'; then
    fail "the email integration failed $(awk -v a="$failed" -v b="$failed_before" 'BEGIN {print a-b}') time(s). Read: kubectl -n ${MON_NS} logs ${am_pod} -c alertmanager"
  fi
  if awk -v a="$sent" -v b="$sent_before" 'BEGIN {exit !(a > b)}'; then
    printf '  ✓ the relay accepted the email (notifications %s -> %s, failures %s)\n' "$sent_before" "$sent" "$failed"
    break
  fi
  [ "$(date +%s)" -lt "$deadline" ] || fail "no email notification within ${DELIVERY_WAIT}s"
  sleep 10
done
printf '  owner: confirm the subject with %s in alerts@zeroroot.ai\n' "$PROBE_ID"

# --- 3: memory inside the limits -------------------------------------------
usage="$(kubectl top pods -n "$MON_NS" --containers --no-headers 2>/dev/null)" \
  || cannot "kubectl top failed: the cluster has no metrics-server answer"
[ -n "$usage" ] || cannot "kubectl top returned no container"
# The pod JSON goes in a file: on staging it is larger than the argument
# limit of the kernel, and python3 failed with "Argument list too long"
# (hosted#675).
limits_file="$(mktemp)"
trap 'rm -f "$limits_file"' EXIT
kubectl -n "$MON_NS" get pods -o json > "$limits_file" || cannot "could not read the pod specs"
over="$(python3 - "$usage" "$limits_file" <<'PY'
import json, re, sys
def mib(q):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(Ki|Mi|Gi)?", q or "")
    if not m:
        return None
    n = float(m.group(1)); u = m.group(2) or ""
    return n / 1024 / 1024 if u == "" else {"Ki": n / 1024, "Mi": n, "Gi": n * 1024}[u]
limits = {}
with open(sys.argv[2]) as f:
    pods = json.load(f)
for p in pods["items"]:
    for c in p["spec"]["containers"]:
        limits[(p["metadata"]["name"], c["name"])] = mib(((c.get("resources") or {}).get("limits") or {}).get("memory"))
total = 0.0
bad = []
for line in sys.argv[1].splitlines():
    pod, container, _cpu, mem = line.split()[:4]
    used = mib(mem) or 0.0
    total += used
    lim = limits.get((pod, container))
    print(f"  {pod}/{container}: {used:.0f}Mi of {'no limit' if lim is None else f'{lim:.0f}Mi'}", file=sys.stderr)
    if lim is not None and used >= lim:
        bad.append(f"{pod}/{container} {used:.0f}Mi >= {lim:.0f}Mi")
print(f"  monitoring total: {total:.0f}Mi", file=sys.stderr)
print("\n".join(bad))
PY
)"
[ -z "$over" ] || fail "a monitoring container is at its memory limit, so the fallback of ADR-0083 applies: ${over}"
printf '  ✓ each monitoring container is inside its memory limit\n'
printf 'PASS: AlertDeliveryProbe %s left by email, and the stack fits its limits\n' "$PROBE_ID"
