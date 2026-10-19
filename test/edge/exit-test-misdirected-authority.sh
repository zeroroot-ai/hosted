#!/usr/bin/env bash
# exit-test-misdirected-authority.sh — A COALESCED HTTP/2 REQUEST GETS 421,
# AND A REQUEST ON THE RIGHT CONNECTION STILL GETS THROUGH. Runs against the
# edge harness.
#
# Every public hostname on the edge (api., app., docs., the apex) shares one
# certificate and one address, so a browser reuses the HTTP/2 connection it
# opened to one host for a request to another (RFC 9113 section 9.1.1). Envoy
# picks the filter chain by the connection's SNI, not by the request's
# :authority, so that request lands on a chain with no virtual host for it.
# Measured 2026-09-29 on staging: the GitLab connector's OAuth redirect to
# api.<domain>/connectors/oauth/callback rode the browser's app.<domain>
# connection and got the public chain's 404, so the connector never enabled.
#
# The rule (RFC 9113 section 9.1.2): the edge answers 421 Misdirected Request
# and the browser retries on a new connection with the right SNI. Both halves
# matter. An edge that answers 421 to everything passes "misdirected" and is
# an outage; an edge that never answers 421 passes "control" and leaves the
# bug in place.
#
#   1. misdirected: SNI app., :authority api. -> 421 on the OAuth callback
#      path, and on a daemon RPC path (no 401 from jwt_authn ahead of the 421).
#   2. misdirected: SNI api., :authority app. -> 421 on a dashboard page.
#   3. control: SNI api., :authority api. -> the discovery document gets 200.
#   4. control: SNI app., :authority app. -> a dashboard page gets 200.
#   5. control: the OAuth callback path on the right connection reaches the
#      daemon's route and its upstream (the harness stub answers 200), never
#      the 421 and never a 404.
#
# curl takes the SNI from the URL host and the :authority from the Host
# header, so one request can carry a different value in each, the way a
# coalesced browser request does.
#
# Usage: source <WORK>/env.sh && test/edge/exit-test-misdirected-authority.sh
set -euo pipefail
: "${NET:?source the harness env.sh first}" "${EDGE_IP:?}" "${EDGE_PORT:?}" "${APP_HOST:?}" "${API_HOST:?}" "${CURL_IMAGE:?}"

C=203.0.113.23
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'

# via <sni host> <authority host> <path> [curl args...] — prints the status code
via() {
  local sni="$1" authority="$2" path="$3"; shift 3
  docker run --rm --network "$NET" --ip "$C" "$CURL_IMAGE" -sk -o /dev/null --http2 \
    -H "Host: $authority" --resolve "$sni:$EDGE_PORT:$EDGE_IP" -A "$UA" \
    -w '%{http_code}' "$@" "https://$sni:$EDGE_PORT$path"
}

fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✅ $1: $2"; else echo "  ❌ $1: got '$2', want '$3'"; fail=1; fi; }

CALLBACK='/connectors/oauth/callback?code=x&state=y'

echo "1. SNI app., :authority api. -> 421 (the staging OAuth callback shape)"
check "GET $CALLBACK" "$(via "$APP_HOST" "$API_HOST" "$CALLBACK")" 421
# A Connect-protocol call (JSON, not application/grpc: Envoy answers a
# gRPC-typed request's local reply as HTTP 200 + grpc-status, which would hide
# the status this test is about) on a path jwt_authn guards, with no token.
check "POST /gibson.daemon.v1.DaemonService/List as application/json, no token" \
  "$(via "$APP_HOST" "$API_HOST" /gibson.daemon.v1.DaemonService/List -X POST -H 'Content-Type: application/json' --data-binary '{}')" 421

echo "2. SNI api., :authority app. -> 421 (no 401 from jwt_authn ahead of it)"
check "GET /missions" "$(via "$API_HOST" "$APP_HOST" /missions)" 421
check "GET /login" "$(via "$API_HOST" "$APP_HOST" /login)" 421

echo "3. CONTROL: SNI api., :authority api. -> the discovery document gets 200"
check "GET /.well-known/openid-configuration" "$(via "$API_HOST" "$API_HOST" /.well-known/openid-configuration)" 200

echo "4. CONTROL: SNI app., :authority app. -> a dashboard page gets 200"
check "GET /missions" "$(via "$APP_HOST" "$APP_HOST" /missions)" 200

echo "5. CONTROL: the OAuth callback on the right connection reaches the daemon's route"
# The harness runs no daemon; its stub upstream answers every cluster with
# 200. What matters: not 421 (the request is on the right connection) and not
# 404 (the route exists and reaches an upstream).
check "GET $CALLBACK" "$(via "$API_HOST" "$API_HOST" "$CALLBACK")" 200

if [ "$fail" -ne 0 ]; then
  echo; echo "EXIT TEST FAILED — edge-envoy log tail:"; docker logs edge-envoy 2>&1 | tail -40
  exit 1
fi
echo; echo "EXIT TEST PASSED: a coalesced request gets 421 on both chains; requests on the right connection get through."
