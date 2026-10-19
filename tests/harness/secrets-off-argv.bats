#!/usr/bin/env bats
#
# secrets-off-argv.bats: the smoke sends its credentials through a pipe, never
# on a command line (drill sweep row 28), and the repo guard
# scripts/check-secrets-off-argv.py fails on the unsafe forms.
#
# Offline. curl and kubectl are stubs that record their argv, the headers
# they read from an @file, and their stdin. Each test then asserts that the
# credential is in the pipe and not in the argv.
#
# Run:
#   bats tests/harness/secrets-off-argv.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SMOKE="$REPO_ROOT/scripts/smoke-signup.sh"
LIB="$REPO_ROOT/scripts/lib/smoke-probe.sh"

setup() {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export REC="$BATS_TEST_TMPDIR/rec"; mkdir -p "$REC"
  cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/curl.argv"
: > "$REC/curl.headers"
prev=""
for a in "$@"; do
  if [ "$prev" = "-H" ] && [ "${a#@}" != "$a" ]; then cat "${a#@}" >> "$REC/curl.headers"; fi
  prev="$a"
done
case " $* " in *" --data-binary @- "*) cat > "$REC/curl.stdin" ;; esac
printf 'grpc-status: 7\r\n'
SH
  cat > "$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/kubectl.argv"
case "$*" in
  "-n gibson exec -i openbao-0 -c openbao -- sh -c "*" sh tenant-x secret/infra")
    cat > "$REC/kubectl.stdin"; echo '["neo4j"]'; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$BIN/curl" "$BIN/kubectl"
  export PATH="$BIN:$PATH"
  EDGE_CA="$BATS_TEST_TMPDIR/ca.crt"; echo ca > "$EDGE_CA"
  # The functions of the smoke and of its probe library, without running the
  # smoke.
  FUNCS="$BATS_TEST_TMPDIR/funcs.sh"
  for f in urlenc client_credentials_token grpc_status; do
    sed -n "/^${f}() {/,/^}/p" "$SMOKE"
  done > "$FUNCS"
  sed -n "/^capture() {/,/^}/p" "$REPO_ROOT/scripts/lib/cluster-probe.sh" >> "$FUNCS"
  sed -n "/^bao_kv_list() {/,/^}/p" "$LIB" >> "$FUNCS"
  [ "$(grep -c '^[a-z_]*() {' "$FUNCS")" = 5 ]
}

# in_smoke <bash code>: run code with the smoke's functions loaded.
in_smoke() {
  bash -c 'fail() { echo "FAIL: $*" >&2; }; NAMESPACE=gibson; EDGE_CA="$1"; MISSION_RPC=https://api.example.test/x; . "$2"; eval "$3"' \
    _ "$EDGE_CA" "$FUNCS" "$1"
}

@test "grpc_status sends the bearer token in a header from a pipe, with the edge CA pinned" {
  run in_smoke 'grpc_status tok-SECRET-1; echo "$GRPC_STATUS"'
  [ "$status" -eq 0 ]
  [ "$output" = 7 ] || { echo "$output"; false; }
  [ "$(grep -c 'tok-SECRET-1' "$REC/curl.argv")" = 0 ]
  grep -qx 'authorization: Bearer tok-SECRET-1' "$REC/curl.headers"
  grep -qx -- '--cacert' "$REC/curl.argv"
  [ "$(grep -cx -- '-k' "$REC/curl.argv")" = 0 ]
}

@test "grpc_status with no token sends no authorization header" {
  run in_smoke 'grpc_status'
  [ "$status" -eq 0 ]
  [ ! -s "$REC/curl.headers" ]
}

@test "the client_credentials grant sends the client secret in the body on stdin" {
  run in_smoke 'client_credentials_token https://app.example.test/oauth/v2/token my-id "s3c+r/et&x"'
  [ "$status" -eq 0 ]
  [ "$(grep -c 's3c' "$REC/curl.argv")" = 0 ]
  grep -q 'client_secret=s3c%2Br%2Fet%26x' "$REC/curl.stdin"
  grep -q 'client_id=my-id' "$REC/curl.stdin"
}

@test "bao_kv_list sends the OpenBao token on the stdin of the exec" {
  run in_smoke 'bao_kv_list openbao-0 hvs.SECRET-2 tenant-x secret/infra'
  [ "$status" -eq 0 ]
  [ "$(grep -c 'hvs.SECRET-2' "$REC/kubectl.argv")" = 0 ]
  [ "$(cat "$REC/kubectl.stdin")" = "hvs.SECRET-2" ]
  grep -qx 'tenant-x' "$REC/kubectl.argv"
  grep -qx -- '-i' "$REC/kubectl.argv"
}

@test "FAILING FIXTURE: the old header form puts the token on the argv, and the recording sees it" {
  run in_smoke 'curl -sS --cacert "$EDGE_CA" -H "authorization: Bearer tok-SECRET-3" https://x'
  grep -q 'tok-SECRET-3' "$REC/curl.argv"
}

@test "the repo guard proves it can fail, and the repo passes it" {
  run python3 "$REPO_ROOT/scripts/check-secrets-off-argv.py" --selftest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run python3 "$REPO_ROOT/scripts/check-secrets-off-argv.py"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
