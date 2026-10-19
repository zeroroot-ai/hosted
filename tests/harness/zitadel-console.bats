#!/usr/bin/env bats
#
# zitadel-console.bats: the private path to the Zitadel console (hosted#437).
# Offline: two fake upstreams on 127.0.0.1 stand in for the port-forwards of
# Zitadel core and the Zitadel login. Each fake answers with its own name and
# the headers it received, so a test reads where a path went and what the
# proxy claimed.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOST=app.console-bats.test

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

setup() {
  cat > "$BATS_TEST_TMPDIR/fake.py" <<'PY'
import http.server, json, sys
name, port = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def _any(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        out = json.dumps({"upstream": name, "path": self.path, "method": self.command, "body": body,
                          "headers": {k.lower(): v for k, v in self.headers.items()}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", "a=1"); self.send_header("Set-Cookie", "b=2")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    do_GET = do_POST = do_PUT = _any
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  ZPORT="$(free_port)"; LPORT="$(free_port)"; LISTEN="$(free_port)"
  python3 "$BATS_TEST_TMPDIR/fake.py" zitadel "$ZPORT" & ZPID=$!
  python3 "$BATS_TEST_TMPDIR/fake.py" login "$LPORT" & LPID=$!
  # shellcheck source=../../scripts/lib/zitadel-console.sh
  . "$REPO_ROOT/scripts/lib/zitadel-console.sh"
  console_path_start "$HOST" "$ZPORT" "$LPORT" "$LISTEN" "$BATS_TEST_TMPDIR"
}

teardown() {
  console_path_stop
  kill "$ZPID" "$LPID" 2>/dev/null || true
}

call() { # <method> <path> [curl args...]
  local method="$1" path="$2"; shift 2
  curl -sS --cacert "$BATS_TEST_TMPDIR/console.crt" --resolve "${HOST}:${LISTEN}:127.0.0.1" \
    -X "$method" "$@" "https://${HOST}:${LISTEN}${path}"
}

@test "the console and the admin APIs go to Zitadel core, the login pages to the login" {
  [ "$(call GET /ui/console/ | jq -r .upstream)" = zitadel ]
  [ "$(call POST /management/v1/orgs/_search -d '{}' | jq -r .upstream)" = zitadel ]
  [ "$(call POST /admin/v1/members/_search -d '{}' | jq -r .upstream)" = zitadel ]
  [ "$(call POST /zitadel.admin.v1.AdminService/Healthz -d '' | jq -r .upstream)" = zitadel ]
  [ "$(call GET /oauth/v2/authorize | jq -r .upstream)" = zitadel ]
  [ "$(call GET /ui/v2/login/loginname | jq -r .upstream)" = login ]
}

@test "the proxy claims the instance host, and a client cannot claim another one" {
  out="$(call GET /ui/console/ -H 'X-Zitadel-INSTANCE-host: evil.test' -H 'X-Forwarded-Host: evil.test')"
  [ "$(jq -r '.headers["x-zitadel-instance-host"]' <<<"$out")" = "$HOST" ]
  [ "$(jq -r '.headers["x-zitadel-public-host"]' <<<"$out")" = "$HOST" ]
  [ "$(jq -r '.headers.host' <<<"$out")" = "$HOST" ]
  [ "$(jq -r '.headers["x-forwarded-proto"]' <<<"$out")" = https ]
  [ "$(jq -r '.headers["x-forwarded-host"]' <<<"$out")" = null ]
}

@test "a request body and each Set-Cookie header pass through" {
  out="$(call POST /management/v1/orgs/_search -d '{"query":1}' -D "$BATS_TEST_TMPDIR/h.txt")"
  [ "$(jq -r .body <<<"$out")" = '{"query":1}' ]
  [ "$(grep -ci '^set-cookie:' "$BATS_TEST_TMPDIR/h.txt")" -eq 2 ]
}

@test "the proxy listens on 127.0.0.1 only" {
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$ip" ] || skip "no other address on this host"
  run curl -sk --max-time 3 "https://${ip}:${LISTEN}/"
  [ "$status" -ne 0 ]
}

@test "the browser arguments map the host to the proxy and trust its one key" {
  args="$(console_browser_args "$HOST" "$LISTEN")"
  [[ "$args" == *"--host-resolver-rules=MAP ${HOST} 127.0.0.1:${LISTEN}"* ]]
  want="$(openssl x509 -in "$BATS_TEST_TMPDIR/console.crt" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"
  [[ "$args" == *"--ignore-certificate-errors-spki-list=${want}"* ]]
}

@test "FAILING FIXTURE: a proxy that cannot start makes console_path_start fail" {
  console_path_stop
  run console_path_start "$HOST" "$ZPORT" "$LPORT" "$LISTEN" /nonexistent-dir
  [ "$status" -ne 0 ]
}
