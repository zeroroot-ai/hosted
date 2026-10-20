#!/usr/bin/env bash
# exit-test-waf.sh — deploy#1196's exit test (zero WAF-protected surfaces →
# the browser edge is protected): A SCANNER-SHAPED REQUEST IS BLOCKED, AND A
# REAL SIGNUP GETS THROUGH. Runs against the edge harness.
#
# Both halves matter. A WAF that blocks everything passes "block" and is an
# outage; a WAF that blocks nothing passes "pass-through" and is decoration.
#
#   1. block: a Core Rule Set payload in a form field (script injection) on
#      POST /signup gets 403 from the edge, never reaching the upstream.
#   2. block: an encoded path traversal in a query argument gets 403.
#   3. block: a scanner's user agent on GET / gets 403.
#   4. pass:  a legitimate signup form POST gets 200 from the upstream.
#   5. pass:  a plain dashboard page load gets 200.
#   6. api. block: a scanner user agent and an encoded traversal on api. get
#      403 — AHEAD of authentication, token or not (deploy#1660).
#   7. api. pass: the discovery document gets 200, and a gRPC-typed call
#      without a token reaches jwt_authn (grpc-status 16, UNAUTHENTICATED —
#      Envoy answers gRPC local replies as HTTP 200 + grpc-status), not the
#      WAF (grpc-status 7) — the content type is allowed and the WAF sits
#      ahead of authn.
#   8. opaque_session_cookie (charts files/coraza/browser.conf 900961/900962):
#      pass: a page load whose first-party session cookies carry a PHP
#      function name inside their base64 gets 200. Measured 2026-09-29 on
#      staging: rule 933150 found "MkDir" inside __Secure-authjs.session-token
#      and the edge answered 403 to every page for that browser (hosted#209).
#      Covers the https and plain-http Auth.js names, a chunked token,
#      Zitadel's user-agent cookie and the login app's session cookie.
#      CONTROLS: the same word in a query argument, and in a cookie the
#      exclusion does not name, still get 403. An exclusion that cannot fail
#      its controls is a hole, not an exclusion.
#   9. grpc_web_on_app: a gRPC-web call to /zitadel.* on the app host gets
#      403. The gRPC services have no public route since charts#398
#      (ADR-0093), and the WAF allows the gRPC-web content type on no public
#      path. CONTROL: an unlisted content type on the app host gets 403 too.
#  10. zitadel_admin_surface (hosted#437): /ui/console, /management/v1/,
#      /admin/v1/ and /zitadel. each get the edge 404 on the public host. The
#      Platform owner opens the console through `make zitadel-console`.
#
# Usage: source <WORK>/env.sh && test/edge/exit-test-waf.sh
set -euo pipefail
: "${NET:?source the harness env.sh first}" "${EDGE_IP:?}" "${EDGE_PORT:?}" "${APP_HOST:?}" "${API_HOST:?}" "${CURL_IMAGE:?}"

C=203.0.113.21

# req <method> <path> [curl args...] — prints the status code (app. host)
# api <method> <path> [curl args...] — the same against the api. host
#
# REQ_COOKIE=<name=value; ...> req ... sends a Cookie header. The value goes to
# the container as a curl config on stdin (-K -), never as an argument of
# docker, where a process list shows it.
_req() {
  local host="$1" method="$2" path="$3"; shift 3
  if [ -n "${REQ_COOKIE:-}" ]; then
    printf 'header = "Cookie: %s"\n' "$REQ_COOKIE" \
      | docker run -i --rm --network "$NET" --ip "$C" "$CURL_IMAGE" -sk -o /dev/null -K - \
          -X "$method" -H "Host: $host" --resolve "$host:$EDGE_PORT:$EDGE_IP" \
          -w '%{http_code}' "$@" "https://$host:$EDGE_PORT$path"
    return
  fi
  docker run --rm --network "$NET" --ip "$C" "$CURL_IMAGE" -sk -o /dev/null \
    -X "$method" -H "Host: $host" --resolve "$host:$EDGE_PORT:$EDGE_IP" \
    -w '%{http_code}' "$@" "https://$host:$EDGE_PORT$path"
}
req() { _req "$APP_HOST" "$@"; }
api() { _req "$API_HOST" "$@"; }

fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✅ $1: $2"; else echo "  ❌ $1: got '$2', want '$3'"; fail=1; fi; }

echo "1. script injection in a signup form field is blocked"
check "POST /signup with <script> in email" \
  "$(req POST /signup -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'email=<script>alert(1)</script>' --data-urlencode 'password=x')" 403

echo "2. path traversal in a query argument is blocked"
check "GET /signup?next=../../etc/passwd" "$(req GET '/signup?next=..%2F..%2Fetc%2Fpasswd')" 403

echo "3. a scanner user agent is blocked"
check "GET / as sqlmap" "$(req GET / -A 'sqlmap/1.8')" 403

echo "4. a legitimate signup form gets through"
check "POST /signup with a real form" \
  "$(req POST /signup -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'email=ada@example.com' --data-urlencode 'password=correct horse battery staple')" 200

echo "5. a dashboard page load gets through"
check "GET /missions" "$(req GET /missions -A 'Mozilla/5.0 (X11; Linux x86_64) Firefox/128.0')" 200

echo "6. api.: a scanner is blocked ahead of authentication (deploy#1660)"
check "GET /.well-known/openid-configuration as sqlmap" "$(api GET /.well-known/openid-configuration -A 'sqlmap/1.8')" 403
check "GET /.well-known/openid-configuration?x=../../etc/passwd" "$(api GET '/.well-known/openid-configuration?x=..%2F..%2Fetc%2Fpasswd')" 403

echo "7. api.: legitimate traffic passes the WAF"
check "GET /.well-known/openid-configuration" "$(api GET /.well-known/openid-configuration)" 200
# A gRPC-typed call without a token must reach jwt_authn, not die in the WAF:
# proves the content type is allowed AND the WAF sits ahead of authn. Envoy
# answers a gRPC request's local reply the gRPC way — HTTP 200 with
# grpc-status 16 (UNAUTHENTICATED) — so that header is the assertion; a WAF
# block would be grpc-status 7 (PERMISSION_DENIED).
grpc_status() {
  docker run --rm --network "$NET" --ip "$C" "$CURL_IMAGE" -sk -o /dev/null -D - \
    -X POST -H "Host: $API_HOST" --resolve "$API_HOST:$EDGE_PORT:$EDGE_IP" \
    -H 'Content-Type: application/grpc' -H 'TE: trailers' --data-binary '' \
    "https://$API_HOST:$EDGE_PORT$1" | awk 'tolower($1)=="grpc-status:"{gsub("\r","",$2); print $2}'
}
check "POST /gibson.daemon.v1.DaemonService/List as application/grpc, no token -> grpc-status 16 from jwt_authn" \
  "$(grpc_status /gibson.daemon.v1.DaemonService/List)" 16

# A JWE-shaped token whose base64 carries PHP function names, the shape rule
# 933150 matched on staging ("MkDir", "RTRiM" inside the session token).
JWE='eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2Q0JDLUhTNTEyIiwia2lkIjoiTDhpbWRRRlR5VGdtS2Z0WVdTMjF3WWNob3h5dWNxNVhuaFo1Z016eGJlbEg4S0o3NGI0WmIyIn0..QmxvY2tNkDirQ0FOWQ.abcRTRiMxyz.sig'
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'

echo "8. opaque_session_cookie: first-party session cookies are not read as attack text"
check "GET /missions with __Secure-authjs.session-token carrying MkDir" \
  "$(REQ_COOKIE="__Secure-authjs.session-token=$JWE; __Host-authjs.csrf-token=ab12%7Ccd34" req GET /missions -A "$UA")" 200
check "GET /missions with a chunked __Secure-authjs.session-token.0/.1" \
  "$(REQ_COOKIE="__Secure-authjs.session-token.0=$JWE; __Secure-authjs.session-token.1=$JWE" req GET /missions -A "$UA")" 200
check "GET /missions with the plain-http authjs.session-token" \
  "$(REQ_COOKIE="authjs.session-token=$JWE" req GET /missions -A "$UA")" 200
check "GET /oauth/v2/keys with __Host-zitadel.useragent carrying MkDir" \
  "$(REQ_COOKIE="__Host-zitadel.useragent=$JWE" req GET /oauth/v2/keys -A "$UA")" 200
check "GET /missions with the login app's sessions cookie carrying MkDir" \
  "$(REQ_COOKIE="sessions=$JWE" req GET /missions -A "$UA")" 200
check "CONTROL: GET /missions?q=mkdir( is still blocked" \
  "$(req GET '/missions?q=mkdir(' -A "$UA")" 403
check "CONTROL: MkDir in a cookie the exclusion does not name is still blocked" \
  "$(REQ_COOKIE="tracking=$JWE" req GET /missions -A "$UA")" 403

echo "9. grpc_web_on_app: a gRPC-web call to Zitadel on the app host is refused"
# A gRPC-web frame: 1-byte flag, 4-byte length, then a protobuf message whose
# string field carries the same PHP word, so a body read as text would deny.
GRPC_BODY="$WORK/grpc-web-body.bin"
printf '\000\000\000\000\023\012\021mkdir(<script>x' > "$GRPC_BODY"
grpc_web() {
  docker run --rm --network "$NET" --ip "$C" -v "$GRPC_BODY:/body.bin:ro" "$CURL_IMAGE" -sk -o /dev/null \
    -X POST -H "Host: $APP_HOST" --resolve "$APP_HOST:$EDGE_PORT:$EDGE_IP" -A "$UA" \
    -H 'Content-Type: application/grpc-web+proto' -H 'X-Grpc-Web: 1' --data-binary @/body.bin \
    -w '%{http_code}' "https://$APP_HOST:$EDGE_PORT$1"
}
# The gRPC services of Zitadel have no public route since charts#398
# (ADR-0093), and no public path takes gRPC-web, so the WAF refuses the
# content type before any route.
check "POST /zitadel.user.v2.UserService/GetUserByID as application/grpc-web+proto is refused" \
  "$(grpc_web /zitadel.user.v2.UserService/GetUserByID)" 403
check "CONTROL: POST /missions as application/x-evil is still blocked" \
  "$(req POST /missions -A "$UA" -H 'Content-Type: application/x-evil' --data-binary 'x')" 403

echo "10. zitadel_admin_surface: the four admin prefixes have no public route (ADR-0093, hosted#437)"
# The Platform owner opens the console through the private path
# (make zitadel-console). On the public host the edge answers 404 for each.
check "GET /ui/console/ is refused on the public host" \
  "$(req GET /ui/console/ -A "$UA")" 404
check "POST /management/v1/orgs/_search is refused on the public host" \
  "$(req POST /management/v1/orgs/_search -A "$UA" -H 'Content-Type: application/json' --data-binary '{}')" 404
check "POST /admin/v1/members/_search is refused on the public host" \
  "$(req POST /admin/v1/members/_search -A "$UA" -H 'Content-Type: application/json' --data-binary '{}')" 404
check "POST /zitadel.admin.v1.AdminService/Healthz is refused on the public host" \
  "$(req POST /zitadel.admin.v1.AdminService/Healthz -A "$UA" -H 'Content-Type: application/json' --data-binary '{}')" 404

if [ "$fail" -ne 0 ]; then
  echo; echo "EXIT TEST FAILED — edge-envoy log tail (Coraza audit lines included):"; docker logs edge-envoy 2>&1 | tail -40
  exit 1
fi
echo; echo "EXIT TEST PASSED: scanner-shaped requests are blocked; a real signup and a session cookie get through; the Zitadel admin surface has no public route."
