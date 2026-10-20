#!/usr/bin/env bats
#
# stdin-secrets.bats: a secret sent on the stdin of `kubectl exec -i` that
# arrives empty is a lost call, sent again, and never a refusal.
#
# The stdin of `kubectl exec -i` arrived empty with the exec exit 0 (drill
# runs 39171920065 and 39175834377). An empty secret is no credential:
# redis-cli answers NOAUTH and OpenBao answers 403. The refusal checks of the
# rotation drill read those answers as "the old secret is refused", so a lost
# stdin made a check pass on nothing (audit of the restore path, 2026-10-19).
#
# Offline. kubectl is a stub that runs the in-pod command here, with the
# stdin it got, or with an empty stdin for the first STUB_DROP calls.
# redis-cli and bao are stubs that answer by the secret they get.
#
# Run:
#   bats tests/harness/stdin-secrets.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TEST="$REPO_ROOT/test/rotation/exit-test-rotation.sh"

setup() {
  TMP="$(mktemp -d)"; export TMP
  mkdir -p "$TMP/bin"
  python3 - "$TEST" "$TMP/helpers.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
out = []
m = re.search(r"^STDIN_LOST=\d+$", text, re.M)
if not m:
    sys.exit("no STDIN_LOST in the script")
out.append(m.group(0))
m = re.search(r"^SESSION_PROBE_JS='.*?^\}\);'\n", text, re.M | re.S)
if not m:
    sys.exit("no SESSION_PROBE_JS in the script")
out.append(m.group(0))
for name in ("redis_cli", "bao_token_status", "pods_of", "session_probe"):
    m = re.search(r"^%s\(\) \{.*?^\}\n" % name, text, re.M | re.S)
    if not m:
        sys.exit("no function %s in the script" % name)
    out.append(m.group(0))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
# kubectl -n gibson exec -i <pod> -c <container> -- <command...>
case "$*" in
  "-n gibson exec -i gibson-redis-stack-0 -c redis-stack -- sh -c "*|"-n gibson exec -i gibson-openbao-0 -c openbao -- sh -c "*) ;;
  # The dashboard pods. STUB_DASHBOARDS: their names (none by default).
  "-n gibson get pods -l app.kubernetes.io/component=dashboard --field-selector=status.phase=Running -o jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
    printf '%s\n' ${STUB_DASHBOARDS:-}; exit 0 ;;
  # STUB_EXEC_FAIL: the exec into a dashboard pod fails.
  "-n gibson exec -i gibson-dashboard-a -c dashboard -- node -e "*|"-n gibson exec -i gibson-dashboard-b -c dashboard -- node -e "*)
    [ -z "${STUB_EXEC_FAIL:-}" ] || { echo "error: unable to upgrade connection" >&2; exit 1; }
    # STUB_EMPTY_ONCE: the first answer is a dropped stdout frame.
    if [ -n "${STUB_EMPTY_ONCE:-}" ] && [ ! -e "$TMP/emptied" ]; then : > "$TMP/emptied"; cat > /dev/null; exit 0; fi ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
while [ "$1" != "--" ]; do shift; done; shift
n=$(( $(cat "$TMP/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/calls"
if [ "$n" -le "${STUB_DROP:-0}" ]; then cat > /dev/null; exec "$@" < /dev/null; fi
exec "$@"
SH
  # node: the dashboard probe, in short. An empty stdin is "lost", as in the
  # probe script, and the secret "good" makes a session that the dashboard
  # accepts.
  cat > "$TMP/bin/node" <<'SH'
#!/usr/bin/env bash
sec="$(cat)"
case "$sec" in "") printf lost ;; good) printf accepted ;; *) printf refused ;; esac
SH
  cat > "$TMP/bin/redis-cli" <<'SH'
#!/usr/bin/env bash
case "${REDISCLI_AUTH:-}" in
  "") echo "NOAUTH Authentication required." ;;
  good) echo PONG ;;
  *) echo "WRONGPASS invalid username-password pair or user is disabled." ;;
esac
SH
  cat > "$TMP/bin/bao" <<'SH'
#!/usr/bin/env bash
[ "${BAO_TOKEN:-}" = good ] && exit 0
echo "Error looking up token: Code: 403. Errors: * permission denied" >&2; exit 2
SH
  chmod +x "$TMP/bin/"*
}

teardown() { rm -rf "$TMP"; }

run_helper() {
  rm -f "$TMP/calls"
  run env PATH="$TMP/bin:$PATH" STUB_DROP="${STUB_DROP:-0}" STUB_DASHBOARDS="${STUB_DASHBOARDS:-}" STUB_EXEC_FAIL="${STUB_EXEC_FAIL:-}" STUB_EMPTY_ONCE="${STUB_EMPTY_ONCE:-}" bash -c '. "$1"; NS=gibson RELEASE=gibson; shift; "$@"' _ "$TMP/helpers.sh" "$@"
}

@test "redis_cli sends the password, and redis-cli answers PONG to the right one" {
  run_helper redis_cli gibson-redis-stack-0 good PING
  [ "$status" -eq 0 ] && [ "$output" = PONG ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a password lost on stdin is sent again, not answered NOAUTH" {
  STUB_DROP=2 run_helper redis_cli gibson-redis-stack-0 good PING
  [ "$output" = PONG ] || { echo "$output"; false; }
  [ "$(cat "$TMP/calls")" = 3 ]
}

@test "FAILING FIXTURE: a password lost on every try is a failed call, never a refusal" {
  STUB_DROP=9 run_helper redis_cli gibson-redis-stack-0 old PING
  [ "$status" -eq 97 ] || { echo "$output"; false; }
  [[ "$output" != *NOAUTH* && "$output" != *WRONGPASS* ]]
}

@test "bao_token_status says ok for the right token and denied for a wrong one" {
  run_helper bao_token_status good
  [ "$output" = ok ]
  rm -f "$TMP/calls"
  run_helper bao_token_status old
  [ "$output" = denied ]
}

@test "FAILING FIXTURE: a token lost on stdin is sent again, and a token lost on every try is no denial" {
  STUB_DROP=1 run_helper bao_token_status good
  [ "$output" = ok ] || { echo "$output"; false; }
  rm -f "$TMP/calls"
  STUB_DROP=9 run_helper bao_token_status old
  [[ "$output" == "error: the token did not reach bao on stdin"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a session secret lost on stdin is sent again, and the dashboard accepts it" {
  STUB_DASHBOARDS="gibson-dashboard-a" STUB_DROP=1 run_helper session_probe good
  [ "$output" = accepted ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: no dashboard pod, or a probe with no answer, is an error, never a refusal" {
  STUB_DASHBOARDS="" run_helper session_probe other
  [ "$output" = error ] || { echo "$output"; false; }
  STUB_DASHBOARDS="gibson-dashboard-a" STUB_EXEC_FAIL=1 run_helper session_probe other
  [ "$output" = error ] || { echo "$output"; false; }
  # Both pods lose the secret on every try.
  STUB_DASHBOARDS="gibson-dashboard-a gibson-dashboard-b" STUB_DROP=9 run_helper session_probe good
  [ "$output" = error ] || { echo "$output"; false; }
  # Pod a loses it on each of its 4 tries, pod b gets it: no accept.
  STUB_DASHBOARDS="gibson-dashboard-a gibson-dashboard-b" STUB_DROP=4 run_helper session_probe good
  [ "$output" = mixed ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: an exec with an empty answer is sent again, not counted at once (review of hosted#797)" {
  STUB_DASHBOARDS="gibson-dashboard-a" STUB_EMPTY_ONCE=1 run_helper session_probe good
  [ "$output" = accepted ] || { echo "$output"; false; }
}

@test "the probe script prints lost on an empty stdin, before any work" {
  command -v node >/dev/null || skip "no node"
  js="$(sed -n "/^SESSION_PROBE_JS='/,/^});'\$/p" "$TEST" | sed "1s/^SESSION_PROBE_JS='//; \$s/'\$//")"
  run bash -c 'printf "" | "$1" -e "$2"' _ "$(command -v node)" "$js"
  [ "$output" = lost ] || { echo "$output"; false; }
}

# probe_against STATUS BODY: run the real probe script with real node against
# a local server that answers STATUS with BODY on /api/auth/session.
probe_against() {
  command -v node >/dev/null || skip "no node"
  local js port pid
  js="$(sed -n "/^SESSION_PROBE_JS='/,/^});'\$/p" "$TEST" | sed "1s/^SESSION_PROBE_JS='//; \$s/'\$//")"
  port=$(( 20000 + RANDOM % 20000 ))
  node -e 'require("http").createServer((q, r) => { r.writeHead(+process.argv[1], {"content-type": "application/json"}); r.end(process.argv[2]); }).listen(+process.argv[3], "127.0.0.1")' "$1" "$2" "$port" &
  pid=$!
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done
  run bash -c 'printf "%s" some-secret | PORT="$2" node -e "$1"' _ "$js" "$port"
  kill "$pid" 2>/dev/null || true
}

@test "FAILING FIXTURE: the probe script gives error for a 5xx, and refused for the null answer of Auth.js (review of hosted#800)" {
  probe_against 500 '{"message":"Internal Server Error"}'
  [ "$output" = error ] || { echo "$output"; false; }
  probe_against 200 'null'
  [ "$output" = refused ] || { echo "$output"; false; }
  probe_against 200 '<html>oops</html>'
  [ "$output" = error ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: each miss of the session class names the probe result, and no check reads the probe bare (review of hosted#797)" {
  run python3 - "$REPO_ROOT/test/rotation/exit-test-rotation.sh" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
bare = [i + 1 for i, l in enumerate(lines)
        if re.search(r'\[ "\$\(session_probe [^)]*\)+" = (accepted|refused) \]', l)]
assert not bare, "a check reads session_probe bare (the miss cannot name the result), lines %s" % bare
calls = [i for i, l in enumerate(lines)
         if re.search(r'\bprobe(_old)?="\$\(session_probe ', l)]
assert len(calls) >= 6, "the session class makes %d probe calls, want at least 6" % len(calls)
for i in calls:
    window = "\n".join(lines[i:i + 5])
    assert "miss " in window and "probe result" in window, \
        "the miss after line %d does not name the probe result" % (i + 1)
print("ok %d probe calls, each with a miss that names the result" % len(calls))
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
