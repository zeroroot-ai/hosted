#!/usr/bin/env bash
# exit-test-rate-limit.sh — launch blocker 4's exit test (deploy#1241,
# zeroroot-ai/.github#284): ONE CLIENT HITS THE LIMIT WHILE A SECOND KEEPS
# WORKING. Runs against the edge harness (test/edge/harness.sh up).
#
# Two client containers with distinct source addresses on the harness subnet
# POST /signup on the app host. The quota is envoy.rateLimit.perClient
# .appSignupSubmit (5 per minute per address). Assertions:
#
#   1. client A: the first 5 POSTs pass (200 from the stub upstream), the 6th
#      is 429 with x-envoy-ratelimited: true.
#   2. client B, at the same moment, from a different address: 200.
#   3. the action is scoped: a GET /signup from the over-quota client A is
#      not quota'd (it is not the signup submission).
#   5. api.: POST /capabilitygrant/v1/register is quota'd by address too —
#      client A's 11th registration in a minute is 429, client B's passes.
#      (The authenticated /gibson.* quota keys on the identity ext-authz
#      asserts; ext-authz is a live dependency the harness does not run, so
#      that key is pinned by tests/ratelimit-service.bats and proven at
#      bringup, not here.)
#   4. FAIL-OPEN under the fuse: with the ratelimit container stopped, the
#      over-quota client A gets 200 again, and Envoy's
#      cluster.*.ratelimit.public_per_client.failure_mode_allowed counter is > 0 —
#      the degradation is observable, not silent.
#
# Usage: source <WORK>/env.sh && test/edge/exit-test-rate-limit.sh
set -euo pipefail
: "${NET:?source the harness env.sh first}" "${EDGE_IP:?}" "${EDGE_PORT:?}" "${ADMIN:?}" "${APP_HOST:?}" "${API_HOST:?}" "${CURL_IMAGE:?}"

A=203.0.113.11
B=203.0.113.12
QUOTA="${QUOTA:-5}"

# req <client-ip> <method> <path> [host] — prints "<status> <x-envoy-ratelimited or ->"
req() {
  local host="${4:-$APP_HOST}"
  docker run --rm --network "$NET" --ip "$1" "$CURL_IMAGE" -sk -o /dev/null \
    -X "$2" -H "Host: $host" --resolve "$host:$EDGE_PORT:$EDGE_IP" \
    -w '%{http_code} %{header_json}' "https://$host:$EDGE_PORT$3" \
    | python3 -c 'import sys,json; s=sys.stdin.read(); code,_,h=s.partition(" "); h=json.loads(h or "{}"); print(code, (h.get("x-envoy-ratelimited") or ["-"])[0])'
}

# The quota is a FIXED window keyed on the wall-clock minute (envoyproxy/ratelimit
# semantics). A burst that straddles :00 lands in two windows and never trips —
# observed on main at 00:32:59.9 → 00:33:00.2, where #5 and #6 opened a fresh
# window and passed. Start every burst early in a minute so it cannot straddle.
align_window() {
  local s; s=$(date +%S); s=$((10#$s))
  if [ "$s" -ge 35 ]; then
    echo "  (at :$s — waiting $((60 - s))s for the next quota window)"
    sleep $((60 - s))
  fi
}

fail=0
check() { # check <label> <got> <want>
  if [ "$2" = "$3" ]; then echo "  ✅ $1: $2"; else echo "  ❌ $1: got '$2', want '$3'"; fail=1; fi
}

echo "1. client A ($A) submits signup $QUOTA times, then once more"
align_window
for i in $(seq 1 "$QUOTA"); do
  check "A POST #$i passes" "$(req $A POST /signup)" "200 -"
done
check "A POST #$((QUOTA+1)) is rate limited" "$(req $A POST /signup)" "429 true"

echo "2. client B ($B) submits signup at the same moment"
check "B POST passes" "$(req $B POST /signup)" "200 -"

echo "3. the quota is scoped to the signup submission"
check "A GET /signup is not quota'd" "$(req $A GET /signup)" "200 -"

echo "5. api.: the registration route is quota'd by address too (deploy#1659)"
REG="${REG_QUOTA:-10}"
align_window
for i in $(seq 1 "$REG"); do
  r="$(req $A POST /capabilitygrant/v1/register "$API_HOST")"
  [ "$r" = "200 -" ] || { check "A register #$i passes" "$r" "200 -"; break; }
done
check "A register #$((REG+1)) is rate limited" "$(req $A POST /capabilitygrant/v1/register "$API_HOST")" "429 true"
check "B register passes" "$(req $B POST /capabilitygrant/v1/register "$API_HOST")" "200 -"

echo "4. fail-open under the fuse when the quota service is gone"
docker stop gibson-ratelimit >/dev/null
sleep 2
check "A POST passes with the service down (fail-open)" "$(req $A POST /signup)" "200 -"
# Envoy files the filter's counters under the ROUTE'S upstream cluster:
# cluster.<upstream>.ratelimit.<stat_prefix>.failure_mode_allowed. Sum them.
# Read through /stats/prometheus: since charts#139 the admin interface binds
# loopback and the pod-IP admin_probe listener forwards only /ready and
# /stats/prometheus, so plain /stats answers nothing from here. The metric
# carries the cluster and the stat prefix as labels when Envoy's tag
# extraction applies, and as name segments when it does not; the match
# accepts both shapes and sums the last field.
allowed="$(docker run --rm --network "$NET" "$CURL_IMAGE" -fs "http://$ADMIN/stats/prometheus" \
  | awk '/^envoy_cluster.*failure_mode_allowed/ && /public_per_client/ {s+=$NF} END{print s+0}')"
if [ "${allowed:-0}" -gt 0 ] 2>/dev/null; then
  echo "  ✅ failure_mode_allowed=$allowed — the degradation is counted"
else
  echo "  ❌ failure_mode_allowed='${allowed:-unset}' — fail-open left no trace"; fail=1
fi
docker start gibson-ratelimit >/dev/null

if [ "$fail" -ne 0 ]; then
  echo; echo "EXIT TEST FAILED — edge-envoy log tail:"; docker logs edge-envoy 2>&1 | tail -30
  echo "gibson-ratelimit log tail:"; docker logs gibson-ratelimit 2>&1 | tail -30
  exit 1
fi
echo; echo "EXIT TEST PASSED: one client hit the limit while a second kept working."
