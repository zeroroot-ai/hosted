#!/usr/bin/env bash
# Runtime proof: a response held open past the OLD 60s cap
# survives, using the values the chart actually renders.
#
# WHY A RUNTIME PROOF AND NOT ONLY A RENDER ASSERTION
#
# The failure this guards is SILENT. Envoy sends response headers as soon as the
# upstream does, so a stream cut by the route timeout still reports HTTP 200 to
# the client — it simply stops early. Measured on the old config, a backend that
# would have emitted at 90s produced:
#
#     http=200 elapsed=61s        <- cut, and indistinguishable from success
#
# and on the new config:
#
#     http=200 elapsed=90s        <- ran to completion
#
# A render assertion can tell you the number changed. Only this can tell you the
# stream lives, and only this would have caught the original defect, because the
# original defect looked like a successful mission.
#
# It reads the timeout values OUT of the rendered chart rather than restating
# them, so it cannot drift from what ships.
#
# Usage: test/edge/prove-stream-survives.sh [hold-seconds]

set -euo pipefail

HOLD="${1:-75}"                 # comfortably past the old 60s cap
PORT="${PROOF_PORT:-10000}"
BACKEND_PORT=9999
ENVOY_IMAGE="envoyproxy/envoy:v1.34.0"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
CONTAINER="adr0063-proof-$$"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [ -n "${BACKEND_PID:-}" ] && kill "$BACKEND_PID" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

command -v docker >/dev/null || { echo "SKIP: docker unavailable"; exit 0; }
docker info >/dev/null 2>&1 || { echo "SKIP: docker daemon unreachable"; exit 0; }

echo "==> rendering the chart and lifting the real timeout values out of it"
CHARTS_ROOT="${CHARTS_ROOT:-$REPO_ROOT/../charts}"
helm template gibson "$CHARTS_ROOT/helm/gibson" \
  -f "$CHARTS_ROOT/helm/gibson/values-baseline.yaml" \
  --set platformPostgres.backup.destinationPath=s3://edge-harness/backups/postgres/ \
  --set gibson-workloads.setec.launcher.diskRepo=edge-harness.invalid/setec-disks \
  --set 'gibson-workloads.setec.launcher.diskBuilder.publicKeys[0]=fXleDoHDAcpJhUjK9Hl64f2bMSOdJBeHHbuP6td75vs=' \
  --set gibson-workloads.gibson.auditExport.bucket=edge-harness \
  --set gibson-workloads.gibson.auditExport.lockMode=GOVERNANCE \
  --namespace gibson > "$WORK/all.yaml"

python3 - "$WORK/all.yaml" "$WORK/proof-envoy.yaml" "$BACKEND_PORT" "$PORT" <<'PY'
import sys, yaml

docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs
          if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "gibson-envoy")
e = yaml.safe_load(cm["data"]["envoy.yaml"])

api = None
for l in e["static_resources"]["listeners"]:
    for fc in l["filter_chains"]:
        for f in fc.get("filters", []):
            if f["name"].endswith("http_connection_manager") and \
               f["typed_config"].get("stat_prefix") == "api_ingress":
                api = f["typed_config"]
assert api, "api_ingress HCM not found in the rendered chart"

route = None
for vh in api["route_config"]["virtual_hosts"]:
    for r in vh.get("routes", []):
        ra = r.get("route") or {}
        if ra.get("cluster") == "gibson_daemon_grpc":
            route = ra
            break
    if route:
        break
assert route, "no route to gibson_daemon_grpc in the rendered chart"

print(f"    route.timeout={route.get('timeout')} "
      f"route.idle_timeout={route.get('idle_timeout')} "
      f"stream_idle_timeout={api.get('stream_idle_timeout')}")

hcm = {
    "@type": "type.googleapis.com/envoy.extensions.filters.network."
             "http_connection_manager.v3.HttpConnectionManager",
    "stat_prefix": "proof",
    "codec_type": "AUTO",
    "stream_idle_timeout": api.get("stream_idle_timeout"),
    "http2_protocol_options": api.get("http2_protocol_options"),
    "route_config": {"name": "r", "virtual_hosts": [{
        "name": "v", "domains": ["*"],
        "routes": [{"match": {"prefix": "/gibson."},
                    "route": {"cluster": "be",
                              "timeout": route.get("timeout"),
                              "idle_timeout": route.get("idle_timeout")}}]}]},
    "http_filters": [{"name": "envoy.filters.http.router", "typed_config": {
        "@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"}}],
}
cfg = {"static_resources": {
    "listeners": [{"name": "proof",
        "address": {"socket_address": {"address": "0.0.0.0", "port_value": int(sys.argv[4])}},
        "filter_chains": [{"filters": [
            {"name": "envoy.filters.network.http_connection_manager", "typed_config": hcm}]}]}],
    "clusters": [{"name": "be", "type": "STATIC", "load_assignment": {
        "cluster_name": "be", "endpoints": [{"lb_endpoints": [{"endpoint": {"address": {
            "socket_address": {"address": "127.0.0.1", "port_value": int(sys.argv[3])}}}}]}]}}]}}
open(sys.argv[2], "w").write(yaml.safe_dump(cfg))
PY

# Refuse to run against a port something else already owns. Twice while this
# was being written a stale backend or a still-running envoy answered instead,
# and the run "passed" while measuring the wrong thing entirely. A proof that
# can be satisfied by a process it did not start is not a proof.
for p in "$BACKEND_PORT" "$PORT"; do
  if ! python3 -c "
import socket,sys
s=socket.socket()
try: s.bind(('127.0.0.1', $p))
except OSError: sys.exit(1)
finally: s.close()
"; then
    echo "FAIL: port $p is already in use. Something else would answer this proof." >&2
    exit 1
  fi
done

echo "==> starting a backend that holds its response open for ${HOLD}s"
python3 "$REPO_ROOT/test/edge/slow-backend.py" "$HOLD" &
BACKEND_PID=$!
sleep 2
kill -0 "$BACKEND_PID" 2>/dev/null || { echo "FAIL: backend did not start" >&2; exit 1; }

echo "==> starting envoy on the rendered values"
docker run -d --name "$CONTAINER" --network host \
  -v "$WORK/proof-envoy.yaml:/cfg.yaml:ro" \
  "$ENVOY_IMAGE" -c /cfg.yaml --log-level warn >/dev/null
sleep 4
docker ps --filter "name=$CONTAINER" --format '{{.Status}}' | grep -q Up \
  || { docker logs "$CONTAINER" >&2; echo "FAIL: envoy did not start" >&2; exit 1; }

echo "==> holding a response open through it"
start=$(date +%s)
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time $((HOLD * 3)) \
  -X POST "http://127.0.0.1:${PORT}/gibson.daemon.v1.DaemonService/RunMission")
elapsed=$(( $(date +%s) - start ))

echo "    http=${code} elapsed=${elapsed}s (backend held for ${HOLD}s)"

# The assertion is on ELAPSED, not on the status code. A cut stream still
# reports 200 — that is the whole point.
if [ "$elapsed" -lt $((HOLD - 5)) ]; then
  echo "FAIL: the stream was cut at ${elapsed}s, short of the backend ${HOLD}s hold." >&2
  echo "      Something in the rendered chart is still capping mission streams." >&2
  echo "      Note the status code was ${code}: a cut stream is NOT an error at the" >&2
  echo "      client, which is why this asserts on elapsed time and not on status." >&2
  exit 1
fi
if [ "$elapsed" -gt $((HOLD + 15)) ]; then
  echo "FAIL: the response ran ${elapsed}s against a ${HOLD}s hold." >&2
  echo "      That is too long to be the backend this script started, so the" >&2
  echo "      measurement is of something else. Treat this as a failed run, not" >&2
  echo "      a very healthy one." >&2
  exit 1
fi

printf '\033[1;32mPASS — a response held open for %ss survived the rendered edge config.\033[0m\n' "$HOLD"
