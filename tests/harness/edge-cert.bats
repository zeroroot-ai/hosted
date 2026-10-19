#!/usr/bin/env bats
#
# edge-cert.bats — the edge TLS certificate survives a recreate (row 9 of the
# drill path audit): the teardown stores it, the bringup restores it, and the
# bringup skips a certificate that expires soon or names other hosts.
#
# Offline. kubectl and aws are stubs that answer only the names this suite
# declares (hosted#654); every other call fails, as a real API does.
#
# Run:
#   bats tests/harness/edge-cert.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/edge-cert.sh"

setup() {
  BIN="$BATS_TEST_TMPDIR/bin"; ST="$BATS_TEST_TMPDIR/state"; mkdir -p "$BIN" "$ST"
  export ST
  # A real certificate for the drill names, valid for DAYS days.
  mkcert() {
    openssl req -x509 -newkey rsa:2048 -nodes -days "$1" -subj "/CN=app.drill.example.test" \
      -addext "subjectAltName=$2" -keyout "$ST/key.pem" -out "$ST/crt.pem" >/dev/null 2>&1
  }
  export -f mkcert 2>/dev/null || true
  cat > "$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n gibson get secret gibson-envoy-tls -o json")
    [ ! -f "$ST/unreachable" ] || { echo 'Unable to connect to the server: dial tcp 127.0.0.1:6443: connect: connection refused' >&2; exit 1; }
    [ -f "$ST/live-secret.json" ] || { echo 'Error from server (NotFound): secrets "gibson-envoy-tls" not found' >&2; exit 1; }
    cat "$ST/live-secret.json"; exit 0 ;;
  "apply -f "*) cat "${*: -1}" > "$ST/applied.json"; exit 0 ;;
esac
echo "kubectl stub: undeclared call: $*" >&2; exit 1
SH
  cat > "$BIN/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "secretsmanager put-secret-value --secret-id zeroroot-ai/drill/edge-tls --secret-string file://"*)
    f="${*: -1}"; cat "${f#file://}" > "$ST/stored.json"; exit 0 ;;
  "secretsmanager get-secret-value --secret-id zeroroot-ai/drill/edge-tls --query SecretString --output text")
    if [ -f "$ST/stored.json" ]; then cat "$ST/stored.json"; exit 0; fi
    echo "An error occurred (ResourceNotFoundException) when calling the GetSecretValue operation: Secrets Manager can't find the specified secret value for staging label: AWSCURRENT" >&2; exit 254 ;;
esac
echo "aws stub: undeclared call: $*" >&2; exit 1
SH
  chmod +x "$BIN/kubectl" "$BIN/aws"
  export PATH="$BIN:$PATH"
  cat > "$BATS_TEST_TMPDIR/run.sh" <<SH
set -euo pipefail
log() { printf 'LOG: %s\n' "\$*"; }
die() { printf 'DIE: %s\n' "\$*" >&2; exit 1; }
NS=gibson
EDGE_CERT_SECRET=\${EDGE_CERT_SECRET-zeroroot-ai/drill/edge-tls}
. "$LIB"
"\$@"
SH
}

live_secret() {
  python3 - "$ST/crt.pem" "$ST/key.pem" > "$ST/live-secret.json" <<'PY'
import base64, json, sys
b = lambda p: base64.b64encode(open(p, "rb").read()).decode()
print(json.dumps({"metadata": {"name": "gibson-envoy-tls", "annotations": {
  "cert-manager.io/certificate-name": "gibson-envoy-edge", "cert-manager.io/issuer-name": "letsencrypt-prod",
  "kubectl.kubernetes.io/last-applied-configuration": "x"}},
  "data": {"tls.crt": b(sys.argv[1]), "tls.key": b(sys.argv[2])}}))
PY
}

WANT="app.drill.example.test api.drill.example.test docs.drill.example.test drill.example.test"
SAN="DNS:app.drill.example.test,DNS:api.drill.example.test,DNS:docs.drill.example.test,DNS:drill.example.test"

@test "the teardown stores the edge Secret, its key and its cert-manager annotations only" {
  mkcert 90 "$SAN"; live_secret
  run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_store
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  python3 -c '
import json, sys
v = json.load(open(sys.argv[1]))
assert set(v) == {"tls.crt", "tls.key", "annotations"}, v.keys()
assert v["annotations"] == {"cert-manager.io/certificate-name": "gibson-envoy-edge", "cert-manager.io/issuer-name": "letsencrypt-prod"}, v["annotations"]
' "$ST/stored.json"
  [[ "$output" != *"BEGIN"* ]]
}

@test "a cluster with no edge Secret stores nothing and goes on" {
  run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_store
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist, nothing to keep"* ]]
  [ ! -f "$ST/stored.json" ]
}

@test "FAILING FIXTURE: a cluster that does not answer stops the teardown, and stores nothing" {
  mkcert 90 "$SAN"; live_secret
  : > "$ST/unreachable"
  run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_store
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read gibson/gibson-envoy-tls, so the edge certificate is not kept"* ]]
  [[ "$output" != *"nothing to keep"* ]]
  [ ! -f "$ST/stored.json" ]
}

@test "the bringup restores a stored certificate that is valid and names the hosts the Certificate asks for" {
  mkcert 90 "$SAN"; live_secret
  bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_store >/dev/null
  EDGE_CERT_WANT_NAMES="$WANT" run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_restore
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"restored gibson/gibson-envoy-tls"* ]]
  python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
assert s["kind"] == "Secret" and s["type"] == "kubernetes.io/tls", s
assert s["metadata"] == {"name": "gibson-envoy-tls", "namespace": "gibson", "annotations": {"cert-manager.io/certificate-name": "gibson-envoy-edge", "cert-manager.io/issuer-name": "letsencrypt-prod"}}, s["metadata"]
assert s["data"]["tls.key"]
' "$ST/applied.json"
}

@test "FAILING FIXTURE: a certificate that expires within 30 days is not restored" {
  mkcert 10 "$SAN"; live_secret
  bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_store >/dev/null
  EDGE_CERT_WANT_NAMES="$WANT" run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"expires within 30 days"* ]]
  [ ! -f "$ST/applied.json" ]
}

@test "FAILING FIXTURE: a certificate for other hosts is not restored" {
  mkcert 90 "DNS:app.drill.example.test,DNS:www.drill.example.test"; live_secret
  bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_store >/dev/null
  EDGE_CERT_WANT_NAMES="$WANT" run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"and the Certificate asks for"* ]]
  [ ! -f "$ST/applied.json" ]
}

@test "FAILING FIXTURE: unknown wanted names restore nothing" {
  mkcert 90 "$SAN"; live_secret
  bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_store >/dev/null
  EDGE_CERT_WANT_NAMES= run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_restore
  [ "$status" -eq 0 ]
  [ ! -f "$ST/applied.json" ]
}

@test "a secret with no value yet restores nothing and goes on" {
  EDGE_CERT_WANT_NAMES="$WANT" run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_restore
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"holds nothing yet"* ]]
}

@test "FAILING FIXTURE: another env's secret name is an undeclared call and fails" {
  mkcert 90 "$SAN"; live_secret
  EDGE_CERT_SECRET=zeroroot-ai/staging/edge-tls run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_store
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not store the edge certificate"* ]]
}

@test "FAILING FIXTURE: a secret that stage 0 never made stops the bringup and names the fix" {
  sed -i 's|"secretsmanager get-secret-value --secret-id zeroroot-ai/drill/edge-tls|"secretsmanager get-secret-value --secret-id zeroroot-ai/none/edge-tls|' "$BIN/aws"
  cat >> "$BIN/aws" <<'SH'
SH
  python3 - "$BIN/aws" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('echo "aws stub: undeclared call: $*" >&2; exit 1',
  'case "$*" in "secretsmanager get-secret-value --secret-id zeroroot-ai/drill/edge-tls"*) echo "An error occurred (ResourceNotFoundException) when calling the GetSecretValue operation: Secrets Manager can\'t find the specified secret." >&2; exit 254 ;; esac\necho "aws stub: undeclared call: $*" >&2; exit 1')
open(p, "w").write(s)
PY
  EDGE_CERT_WANT_NAMES="$WANT" run bash "$BATS_TEST_TMPDIR/run.sh" edge_cert_restore
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist. Run make substrate"* ]]
}
