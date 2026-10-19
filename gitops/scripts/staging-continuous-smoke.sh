#!/usr/bin/env bash
# Continuous staging smoke (Epic: cicd-efficiency, board #44, slice S8,
# gibson#1131). Runs after every staging continuous-deploy bump (see gibson
# .github/workflows/gibson-images.yml bump-staging job) and on a 6h schedule
# as a safety net. HTTPS-only against staging's PUBLIC endpoints — no
# cluster/kubectl/argocd API access from this script or its caller workflow.
#
# Deliberately separate from scripts/smoke.sh (the post-PROMOTION smoke):
# that one needs argocd creds to `app wait --health` first.
# This one is the fast per-merge signal for the staging continuous-deploy
# loop and never touches the cluster API — it only proves the edge is up.
#
# Checks:
#   1. https://app.<domain>/                       -> dashboard root (2xx/3xx)
#   2. https://app.<domain>/ui/v2/login            -> Zitadel Login V2 UI
#      (200 after redirects, non-trivial HTML body, not a not-found page)
#   3. https://app.<domain>/.well-known/openid-configuration
#                                                   -> 200 + valid JSON with
#      an `issuer` key (Zitadel OIDC discovery, routed on the app vhost)
#
# WHY THE LOGIN CHECK IS /ui/v2/login AND NOT /ui/ (gitops#347)
#
# Envoy routes the `/ui/` prefix on the app vhost to the Zitadel v4 Login V2
# container, but that container is a Next.js app mounted under a base path —
# the chart sets NEXT_PUBLIC_BASE_PATH=/ui/v2/login and the pod's own
# liveness/readiness probes hit /ui/v2/login/{healthy,ready}. Bare /ui/ is not
# a page there. Verified by running the exact image the chart pins
# (ghcr.io/zeroroot-ai/zitadel-login:v4.14.0@sha256:f4b97af6…) and probing it:
#
#   /ui/                   -> 308 to /ui   (3-byte redirect body)
#   /ui                    -> 404          (8 KB Next.js not-found page)
#   /ui/v2/login           -> 200          (32 KB login page)
#   /ui/v2/login/loginname -> 200          (33 KB)
#
# The old check asked for 2xx/3xx AND a >200-byte body against bare /ui/, so it
# scored the 308's 3-byte stub as a failure and staging-smoke was red on the
# login check alone on every run since the check was written — it never matched
# the live app. Two changes beyond the path: follow redirects and require a
# final 200, so a "3xx with a big body" can never read as a rendered page; and
# reject a not-found body, so a future base-path change that soft-404s cannot
# pass on size alone.
#
# NOTE on healthz: there is no publicly-routed healthz/readyz surface at the
# edge. The api.<domain> vhost's only routes are /gibson.* (gRPC),
# /.well-known/*, and /capabilitygrant/*; everything else hits the documented
# default 404 (see envoy.yaml's "unknown route" catch-all) — kubelet
# liveness/readiness probes hit the pod directly, never through Envoy. So
# there is nothing to check here for "healthz exposed via ingress" — there
# isn't one, by design.
#
# Fails loud: prints the failing URL + status/detail and exits non-zero.
#
# Usage:
#   scripts/staging-continuous-smoke.sh
#   scripts/staging-continuous-smoke.sh --selftest   # prove the login check
#                                                    # rejects a broken login
#                                                    # page (needs python3)
set -euo pipefail

# The path the Zitadel Login V2 app actually serves — NEXT_PUBLIC_BASE_PATH in
# the chart, and what the pod's own probes hit. Bare /ui/ is an Envoy route
# prefix, not a page (gitops#347); keep this under the base path.
LOGIN_PATH="/ui/v2/login"

fail=0

check_status() {
  local name="$1" url="$2"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --retry 3 --retry-delay 5 "$url" || echo 000)"
  if [[ "$code" =~ ^[23] ]]; then
    echo "✓ ${name}: ${url} -> ${code}"
    return 0
  fi
  echo "✗ ${name}: ${url} -> ${code}"
  fail=1
  return 1
}

# ---------------------------------------------------------------------------
# check_login_page <url> — the Login V2 UI must actually render.
#
# Three independent ways this fails, each of which has a real cause:
#   - final status is not 200      : route gone, app down, edge 5xx
#   - body <= 200 bytes            : a redirect stub or an empty shell
#   - body is a not-found page     : base path moved and the app soft-404s
# Redirects are followed (-L) so a future trailing-slash or base-path redirect
# does not re-red this check the way the bare /ui/ 308 did; the effective URL
# is printed so a silent redirect somewhere else is visible in the log.
# ---------------------------------------------------------------------------
check_login_page() {
  local url="$1" body code effective
  body="$(curl -sSL --max-time 20 --retry 3 --retry-delay 5 "$url" || true)"
  read -r code effective <<<"$(curl -sSL -o /dev/null -w '%{http_code} %{url_effective}' \
    --max-time 20 --retry 3 --retry-delay 5 "$url" || echo "000 -")"

  local why=""
  [ "$code" = "200" ] || why="final status ${code}, want 200"
  if [ -z "$why" ] && [ "${#body}" -le 200 ]; then
    why="body ${#body} bytes, want >200 (a redirect stub, not a page)"
  fi
  if [ -z "$why" ] && grep -qF 'This page could not be found' <<<"$body"; then
    why="served a not-found page — the login app's base path moved"
  fi

  if [ -z "$why" ]; then
    echo "✓ login-page: ${url} -> ${code} (${#body} bytes, effective ${effective})"
    return 0
  fi
  echo "✗ login-page: ${url} -> ${why} (effective ${effective})"
  fail=1
  return 1
}

# ---------------------------------------------------------------------------
# selftest — serve the shapes the login endpoint is actually observed to return
# and assert check_login_page's verdict on each. The point is that this check
# can still go red: a login smoke that passes on a 404 is worse than none.
# ---------------------------------------------------------------------------
selftest() {
  command -v python3 >/dev/null || { echo "::error::--selftest needs python3"; exit 2; }

  local dir port pid rc=0 pass=0
  dir="$(mktemp -d)"
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

  # Shapes taken from probing the pinned zitadel-login image directly.
  cat >"${dir}/server.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PAGE = b"<html><head><title>Login with Zitadel</title></head><body>" + b"x" * 4000 + b"</body></html>"
NOT_FOUND = (b"<html><head><title>404: This page could not be found.</title></head><body>"
             + b"y" * 4000 + b"</body></html>")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        # The real shape today: bare /ui/ 308s to /ui, which 404s with a fat body.
        if self.path == "/ui/":
            self.send_response(308)
            self.send_header("Location", "/ui")
            self.end_headers()
            self.wfile.write(b"/ui")
        elif self.path == "/ui":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(NOT_FOUND)
        # The fixed target: a real login page.
        elif self.path == "/ui/v2/login":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(PAGE)
        # A trailing-slash variant that redirects to the real page — the -L case.
        elif self.path == "/ui/v2/login/":
            self.send_response(308)
            self.send_header("Location", "/ui/v2/login")
            self.end_headers()
            self.wfile.write(b"/ui/v2/login")
        # 200 but the not-found body: a base-path move that soft-404s.
        elif self.path == "/soft-404":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(NOT_FOUND)
        # 200 with nothing in it: the app is up but rendering an empty shell.
        elif self.path == "/empty":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"<html></html>")
        else:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"boom")


HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

  python3 "${dir}/server.py" "$port" &
  pid=$!
  # shellcheck disable=SC2064  # expand $pid/$dir now, not at trap time
  trap "kill $pid 2>/dev/null || true; rm -rf $dir" RETURN

  local _
  for _ in $(seq 1 40); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${port}/ui/v2/login" && break
    sleep 0.25
  done

  # NOT a command substitution: check_login_page reports through the shared
  # `fail`, and a subshell would swallow it — every case would look accepted.
  want() { # want <accept|reject> <path> <why>
    local expect="$1" path="$2" why="$3"
    fail=0
    check_login_page "http://127.0.0.1:${port}${path}" >"${dir}/last.out" 2>&1 || true
    if { [ "$expect" = accept ] && [ "$fail" -eq 0 ]; } ||
       { [ "$expect" = reject ] && [ "$fail" -ne 0 ]; }; then
      printf '  [PASS] %s\n' "$why"
      pass=$((pass + 1))
    else
      printf '  [FAIL] %s\n    got: %s\n' "$why" "$(cat "${dir}/last.out")"
      rc=1
    fi
  }

  echo "=== staging-continuous-smoke selftest ==="
  want reject /ui        'the shape live today (bare /ui/ -> 308 -> 404) is rejected'
  want reject /ui/       'following the 308 to a 404 does not launder it into a pass'
  want accept /ui/v2/login  'the real login page (200, full HTML body) passes'
  want accept /ui/v2/login/ 'a trailing-slash redirect to the login page still passes'
  want reject /soft-404  'a 200 carrying a not-found body is rejected on content, not size'
  want reject /empty     'a 200 with a trivial body is rejected'
  want reject /boom      'a 5xx is rejected'

  # The path is half the fix: a revert to bare /ui/ would leave every check
  # above passing while the live smoke stayed permanently red, which is exactly
  # the state gitops#347 describes.
  case "$LOGIN_PATH" in
    /ui/v2/login*)
      printf '  [PASS] %s\n' "the live check targets ${LOGIN_PATH}, under the app's base path"
      pass=$((pass + 1)) ;;
    *)
      printf '  [FAIL] %s\n' "LOGIN_PATH=${LOGIN_PATH} is outside the login app's /ui/v2/login base path"
      rc=1 ;;
  esac

  fail=0
  printf '%s checks passed\n' "$pass"
  return $rc
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

values="envs/staging/values.yaml"
[ -f "$values" ] || { echo "::error::missing $values"; exit 1; }

# global.domain is the last top-level `domain:` under the `global:` block
# (same extraction the existing scripts/smoke.sh uses, kept consistent).
domain="$(awk '/^global:/{g=1;next} g&&/^[^[:space:]]/{g=0} g&&/^[[:space:]]+domain:/{print $2; exit}' "$values" | tr -d '"')"
[ -n "$domain" ] || { echo "::error::could not read global.domain from $values"; exit 1; }
app="app.${domain}"
echo "env=staging domain=${domain} app-host=${app}"

# 1. Dashboard root.
check_status "dashboard-root" "https://${app}/" || true

# 2. Login page renders (Zitadel Login V2 UI — /ui/v2/login, see the header).
check_login_page "https://${app}${LOGIN_PATH}" || true

# 3. Zitadel OIDC discovery — 200 + a JSON body with an `issuer` key.
oidc_url="https://${app}/.well-known/openid-configuration"
oidc_code="$(curl -sS -o /tmp/oidc.json -w '%{http_code}' --max-time 20 --retry 3 --retry-delay 5 "$oidc_url" || echo 000)"
if [[ "$oidc_code" =~ ^2 ]] && jq -e '.issuer | length > 0' /tmp/oidc.json >/dev/null 2>&1; then
  echo "✓ oidc-discovery: ${oidc_url} -> ${oidc_code} (issuer=$(jq -r .issuer /tmp/oidc.json))"
else
  echo "✗ oidc-discovery: ${oidc_url} -> ${oidc_code}"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "::error::staging continuous-smoke FAILED — see the failing check(s) above (URL + status)."
  exit 1
fi
echo "✓ staging continuous-smoke passed"
