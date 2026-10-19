#!/usr/bin/env bash
# exit-test-substrate.sh — the blocker 4 assertion against a REAL cluster
# (deploy#1661, ADR-0079 Substrate proof level): one client hits the rate
# limit while a second keeps working, through the substrate's own load
# balancer, so the Client-IP contract is proven on that provider rather than
# on the Docker harness.
#
# Two clients with DISTINCT source addresses as the edge sees them:
#   kind  two curl containers on the kind Docker network, dialling
#                   the node's NodePort, each on its own FIXED address. No NAT
#                   is between them and the node, so Envoy sees two
#                   addresses. Without --ip, each `docker run --rm` takes the
#                   lowest free address, which the last container just gave
#                   back, so every request came from one address and client B
#                   was counted as client A (hosted#613, run 38201552043:
#                   Hubble shows 172.18.0.5 for all of them).
#   eks             client A is this runner, dialling the load balancer's
#                   public address; client B is a pod inside the cluster
#                   dialling the Envoy Service ClusterIP (a pod dialling the
#                   public LB is the hairpin case the contract avoids), so
#                   Envoy sees the runner's address and a pod address.
#
# The signup submission is quota'd at envoy.rateLimit.perClient.appSignupSubmit
# (5/min by address). Against a real dashboard the first five POSTs answer
# whatever the app answers (a 400 for an empty form is fine); the assertion is
# "not 429" for those, 429 with x-envoy-ratelimited on the sixth, and "not
# 429" for client B at the same moment.
#
# Env:
#   SUBSTRATE     kind | eks (D36: the supported substrates)
#   NS            namespace (default gibson)
#   APP_HOST      the app. hostname the chart claims (default from global.domain in the Service)
#   CURL_IMAGE    (default ghcr.io/zeroroot-ai/mirror/curl:8.10.1)
#   KIND_CLUSTER  kind cluster name (default gibson)
set -euo pipefail
SUBSTRATE="${SUBSTRATE:?kind|eks}"
case "$SUBSTRATE" in kind|eks) ;; *) echo "SUBSTRATE=${SUBSTRATE} is not supported (kind, eks)" >&2; exit 2 ;; esac
NS="${NS:-gibson}"
CURL_IMAGE="${CURL_IMAGE:-ghcr.io/zeroroot-ai/mirror/curl:8.10.1}"
KIND_CLUSTER="${KIND_CLUSTER:-gibson}"
QUOTA="${QUOTA:-5}"

APP_HOST="${APP_HOST:-$(kubectl -n "$NS" get cm gibson-domains -o jsonpath='{.data.appHost}' 2>/dev/null || true)}"
[ -n "$APP_HOST" ] || { echo "APP_HOST unknown: set it, or the gibson-domains ConfigMap must carry data.appHost" >&2; exit 2; }

# --- where the edge is, and how each client reaches it -----------------------
if [ "$SUBSTRATE" = kind ]; then
  NODE_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${KIND_CLUSTER}-control-plane")"
  EDGE_PORT="$(kubectl -n "$NS" get svc gibson-envoy -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')"
  EDGE_ADDR="$NODE_IP"
  # Two addresses near the top of the kind subnet, below the three that
  # stage 0 pins there (bootstrap/kind/substrate/substrate.sh), far above
  # anything Docker hands out on its own.
  KIND_SUBNET="$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep -E '^[0-9]+\.' | head -n1)"
  [ -n "$KIND_SUBNET" ] || { echo "the Docker network kind has no IPv4 subnet" >&2; exit 2; }
  read -r CLIENT_A_IP CLIENT_B_IP < <(python3 -c '
import ipaddress, sys
n = ipaddress.ip_network(sys.argv[1])
print(n[-11], n[-10])' "$KIND_SUBNET")
  echo "client A is ${CLIENT_A_IP}, client B is ${CLIENT_B_IP}"
  client_a() { docker run --rm --network kind --ip "$CLIENT_A_IP" "$CURL_IMAGE" "$@"; }
  client_b() { docker run --rm --network kind --ip "$CLIENT_B_IP" "$CURL_IMAGE" "$@"; }
  edge_for_b="$EDGE_ADDR:$EDGE_PORT"
else
  EDGE_PORT="$(kubectl -n "$NS" get svc gibson-envoy -o jsonpath='{.spec.ports[?(@.name=="https")].port}')"
  EDGE_ADDR="$(kubectl -n "$NS" get svc gibson-envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  [ -n "$EDGE_ADDR" ] || EDGE_ADDR="$(kubectl -n "$NS" get svc gibson-envoy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  [ -n "$EDGE_ADDR" ] || { echo "the gibson-envoy Service has no load-balancer address yet" >&2; exit 2; }
  CLUSTER_IP="$(kubectl -n "$NS" get svc gibson-envoy -o jsonpath='{.spec.clusterIP}')"
  client_a() { curl "$@"; }
  client_b() { kubectl -n "$NS" run "exit-test-b-$RANDOM" --rm -i --restart=Never --image="$CURL_IMAGE" --quiet -- "$@"; }
  edge_for_b="$CLUSTER_IP:$EDGE_PORT"
fi
echo "edge: $EDGE_ADDR:$EDGE_PORT as $APP_HOST (substrate $SUBSTRATE); client B reaches $edge_for_b"

# req <client_fn> <edge host:port> <method> <path> — prints "<status> <x-envoy-ratelimited or ->"
req() {
  local fn="$1" edge="$2" method="$3" path="$4"
  local host="${edge%%:*}" port="${edge##*:}"
  "$fn" -sk -o /dev/null -X "$method" -H "Host: $APP_HOST" --resolve "$APP_HOST:$port:$host" \
    -w '%{http_code} %{header_json}' "https://$APP_HOST:$port$path" \
    | python3 -c 'import sys,json; s=sys.stdin.read(); code,_,h=s.partition(" "); h=json.loads(h or "{}"); print(code, (h.get("x-envoy-ratelimited") or ["-"])[0])' 2>/dev/null \
    || echo "000 -"
}

fail=0
not429() { case "$2" in 429*) echo "  ❌ $1: $2 (429 too early)"; fail=1 ;; *) echo "  ✅ $1: $2" ;; esac; }
is429()  { case "$2" in "429 true") echo "  ✅ $1: $2" ;; *) echo "  ❌ $1: got '$2', want '429 true'"; fail=1 ;; esac; }

# Align to the quota window (fixed windows keyed on the wall-clock minute).
s=$(date +%S); s=$((10#$s)); [ "$s" -ge 35 ] && sleep $((60 - s))

# envoy_counters prints the Prometheus stats of every edge Envoy pod. The
# counters are totals since each pod started, so step 3 asserts on the
# difference between a read before the POSTs and a read after them.
envoy_counters() {
  local ep pods
  pods=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=envoy -o jsonpath='{.items[*].metadata.name}') || return 1
  [ -n "$pods" ] || return 1
  for ep in $pods; do
    kubectl get --raw "/api/v1/namespaces/$NS/pods/${ep}:9901/proxy/stats/prometheus" || return 1
    echo
  done
}
# sum_of <stats> <ERE>: the sum of the values of the lines that match.
sum_of() {
  printf '%s\n' "$1" | awk -v re="$2" '$0 ~ re {s += $NF} END {print s + 0}'
}
envoy_before=$(envoy_counters) || { echo "EXIT TEST FAILED on substrate $SUBSTRATE: the Envoy counters could not be read before the POSTs"; exit 1; }

echo "1. client A submits signup $QUOTA times, then once more"
for i in $(seq 1 "$QUOTA"); do not429 "A POST #$i" "$(req client_a "$EDGE_ADDR:$EDGE_PORT" POST /signup)"; done
is429 "A POST #$((QUOTA+1)) is rate limited" "$(req client_a "$EDGE_ADDR:$EDGE_PORT" POST /signup)"

echo "2. client B submits signup at the same moment, from another address"
not429 "B POST" "$(req client_b "$edge_for_b" POST /signup)"

echo "3. the limiter answered each call: no fail-open and no error (D92)"
# The per-client rate limit filter fails open on a timeout or an error
# (failure_mode_deny false), and then a POST over the quota gets 200 (C50).
# The Envoy counters are live, so they are read at once. The filter counts
# under the cluster of the route, gibson_dashboard, as
# envoy_cluster_ratelimit_public_per_client_<stat>, the name the alert rule
# of the chart reads (charts: helm/gibson-workloads/templates/ratelimit/alertrule.yaml).
# The upstream latency of ratelimit_grpc is printed on each run: it sizes
# the filter timeout (D92 (c)).
envoy_stats=$(envoy_counters) || { echo "EXIT TEST FAILED on substrate $SUBSTRATE: the Envoy counters could not be read after the POSTs"; exit 1; }
# Match the string, never `printf | grep -q`: under pipefail grep -q exits on
# the first match, printf dies of SIGPIPE, and the pipeline reads as failed.
if [[ $'\n'"$envoy_stats" != *$'\n'envoy_* ]]; then
  echo "  ❌ no Envoy counter was read"; fail=1
else
  # Every per-client filter: public_per_client and api_per_client (stage 0,
  # fail-open) and public_signup (stage 1, fail-closed, D92). Each counts
  # under the cluster of its route as envoy_cluster_ratelimit_<prefix>_<stat>.
  # Each number below is after minus before. Envoy makes a counter at its
  # first increment, so a counter absent before is 0, and an error or
  # failure_mode_allowed counter absent after is 0 too. The ok and over_limit
  # deltas must show the signup calls, or the read is blind and fails.
  pc='^envoy_cluster_ratelimit_(public_per_client|api_per_client|public_signup)_'
  sg='^envoy_cluster_ratelimit_(public_per_client|public_signup)_'
  dash='[{]envoy_cluster_name="gibson_dashboard"[}]'
  delta() { echo $(( $(sum_of "$envoy_stats" "$1") - $(sum_of "$envoy_before" "$1") )); }
  ok=$(delta "${sg}ok${dash}")
  over=$(delta "${sg}over_limit${dash}")
  serrs=$(delta "${sg}error${dash}")
  errs=$(delta "${pc}error[{]")
  open=$(delta "${pc}failure_mode_allowed[{]")
  echo "    this run, signup calls on gibson_dashboard: ok $ok, over_limit $over"
  echo "    this run, all per-client filters: error $errs, failure_mode_allowed $open"
  # A counter that went down means an Envoy pod restarted between the two
  # reads and lost its totals, so no difference of this run is known.
  if [ "$ok" -lt 0 ] || [ "$over" -lt 0 ] || [ "$errs" -lt 0 ] || [ "$open" -lt 0 ]; then
    echo "  ❌ a counter went down between the two reads: an edge Envoy pod restarted, so this run's counts are unknown"; fail=1
  elif [ "$((ok + over + serrs))" -lt "$((QUOTA + 2))" ] || [ "$over" -lt 1 ]; then
    echo "  ❌ the limiter saw $((ok + over + serrs)) signup calls with $over over the limit, want at least $((QUOTA + 2)) and 1: the counter read is blind"; fail=1
    echo "  the rate limit counters Envoy serves:"
    printf '%s\n' "$envoy_stats" | grep -E '^envoy_[a-z_]*ratelimit' | grep -v ' 0$' | head -30 | sed 's/^/    /' || true
  elif [ "$errs" -ne 0 ] || [ "$open" -ne 0 ]; then
    echo "  ❌ $errs call(s) got no answer (error) and $open went through unchecked (failure_mode_allowed), want 0 and 0"; fail=1
  else
    echo "  ✅ the limiter judged all $((ok + over)) signup calls, $over over the limit; 0 errors and 0 unchecked on every per-client filter"
  fi
  # The filter calls the limiter through the gRPC async client, so Envoy
  # counts the latency as internal_upstream_rq_time. A call that timed out
  # is not in that histogram: upstream_rq_timeout counts it. The cold cost
  # of a new connection shows as upstream_cx_connect_ms (TCP) plus one
  # ssl_handshake per connection. D92 sizes the 250 ms stage 0 timeout from
  # these numbers.
  echo "  ratelimit_grpc: latency (ms buckets), timeouts and connections:"
  printf '%s\n' "$envoy_stats" \
    | grep -E '^envoy_cluster_(internal_)?upstream_rq_time_(bucket|count|sum)\{|^envoy_cluster_upstream_(rq_timeout|rq_pending_total|cx_total|cx_connect_fail|cx_connect_timeout)\{|^envoy_cluster_upstream_cx_connect_ms_(bucket|count|sum)\{|^envoy_cluster_ssl_(handshake|connection_error|fail_verify_[a-z_]+)\{' \
    | grep 'envoy_cluster_name="ratelimit_grpc"' | sed 's/^/    /' || true
fi

if [ "$fail" -ne 0 ]; then
  # Diagnostics (pod list, Envoy and ratelimit logs) are the workflow's
  # failure step's job, so no probe here has its exit code swallowed.
  echo; echo "EXIT TEST FAILED on substrate $SUBSTRATE"
  exit 1
fi
echo; echo "EXIT TEST PASSED on substrate $SUBSTRATE: one client hit the limit while a second kept working."
