#!/usr/bin/env bats
#
# smoke-probe.bats: the probes of the signup smoke report a refusal as a
# refusal, never as an empty answer (scripts/lib/smoke-probe.sh, THE RULE).
#
# Staging run 38465547479 failed step 6 with "secret/infra/* missing". The
# secrets were there: OpenBao refused the token the probe used, the error went
# to /dev/null, and the fallback "[]" read as "missing".
#
# Offline. kubectl is a stub. STUB_LIST names the answer of `bao kv list`:
#   keys     the four infra keys
#   refused  a 403, the way OpenBao refuses a token without the path
#   empty    "No value found", the way OpenBao answers a path with no keys
# The stub serves the token only from gibson-tenant-operator-vault, the Secret
# of the writer of these paths, and records the stdin of the exec.
#
# Run:
#   bats tests/harness/smoke-probe.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/smoke-probe.sh"

setup() {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export REC="$BATS_TEST_TMPDIR/rec"; mkdir -p "$REC"
  cat > "$BIN/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n gibson get pod -l app.kubernetes.io/component=openbao -o jsonpath={.items[0].metadata.name}")
    printf 'gibson-openbao-0' ;;
  "-n gibson get secret gibson-tenant-operator-vault -o jsonpath={.data.VAULT_ADMIN_TOKEN}")
    printf '%s' "$(printf 'tok-operator' | base64)" ;;
  "-n gibson get secret "*)
    echo "Error from server (NotFound): secrets \"${5}\" not found" >&2; exit 1 ;;
  "-n gibson exec -i gibson-openbao-0 -c openbao -- sh -c "*" sh tenant-acme secret/infra")
    cat > "$REC/exec.stdin"
    case "$STUB_LIST" in
      keys)    echo '["neo4j","postgres","redis","vector"]' ;;
      refused) echo 'Error listing secret/metadata/infra: Error making API request.' >&2
               echo 'Code: 403. Errors: * 1 error occurred: * permission denied' >&2; exit 2 ;;
      empty)   echo 'No value found at secret/metadata/infra' >&2; exit 2 ;;
      # lost: the token does not arrive on stdin. The stub runs the in-pod
      # shell here with an empty stdin, and bao must not run.
      lost)    while [ "$1" != "--" ]; do shift; done; shift
               PATH="$REC/podbin:$PATH" "$@" < /dev/null; exit $? ;;
    esac ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$BIN/kubectl"
  export PATH="$BIN:$PATH"
}

# step6: run assert_tenant_infra for tenant acme, and print FAILED at the end.
step6() {
  bash -c 'NAMESPACE=gibson; . "$1"; assert_tenant_infra acme; echo "FAILED=$FAILED"' _ "$LIB" 2>&1
}

@test "the four infra keys pass, and the token reaches bao on stdin" {
  export STUB_LIST=keys
  run step6
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"secret/infra/vector present in tenant-acme"* ]] || { echo "$output"; false; }
  [[ "$output" == *"FAILED=0"* ]] || { echo "$output"; false; }
  grep -qx 'tok-operator' "$REC/exec.stdin"
}

@test "FAILING FIXTURE: a refused list is reported with its error, not as missing secrets" {
  export STUB_LIST=refused
  run step6
  [[ "$output" == *"OpenBao refused the list of secret/infra in tenant-acme: Error listing secret/metadata/infra"* ]] || { echo "$output"; false; }
  # The code and the reason sit on the second line of the OpenBao error.
  [[ "$output" == *"Code: 403"*"permission denied"* ]] || { echo "$output"; false; }
  [[ "$output" != *"missing in tenant-acme"* ]] || { echo "$output"; false; }
  [[ "$output" == *"FAILED=1"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a path with no keys fails as four missing secrets" {
  export STUB_LIST=empty
  run step6
  [[ "$output" == *"secret/infra/{neo4j postgres redis vector} missing in tenant-acme"* ]] || { echo "$output"; false; }
  [[ "$output" == *"FAILED=1"* ]] || { echo "$output"; false; }
}

@test "capture keeps the stdout and the first three error lines of a failed command" {
  run bash -c '. "$1"; capture out sh -c "echo 000; echo first error >&2; echo second >&2; exit 7"; rc=$?; echo "rc=$rc out=$out err=$PROBE_ERR"' _ "$LIB"
  [ "$output" = "rc=7 out=000 err=first error | second" ] || { echo "$output"; false; }
}

@test "capture joins the error lines with \" | \" and keeps a pipe inside a line as it is" {
  run bash -c '. "$1"; capture out sh -c "echo \"a|b\" >&2; echo c >&2; exit 1"; echo "err=$PROBE_ERR"' _ "$LIB"
  [ "$output" = "err=a|b | c" ] || { echo "$output"; false; }
}

@test "the guard proves it can fail, and the promotion proof passes it" {
  run "$REPO_ROOT/scripts/check-smoke-probes-loud.sh" --selftest
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$REPO_ROOT/scripts/check-smoke-probes-loud.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a token that does not arrive on stdin is named, and bao does not run" {
  mkdir -p "$REC/podbin"
  printf '#!/usr/bin/env bash\necho BAO-RAN\n' > "$REC/podbin/bao"; chmod +x "$REC/podbin/bao"
  export STUB_LIST=lost
  run step6
  [[ "$output" == *"the token did not arrive on stdin"* ]] || { echo "$output"; false; }
  [[ "$output" != *BAO-RAN* ]] || { echo "$output"; false; }
  [[ "$output" == *"FAILED=1"* ]] || { echo "$output"; false; }
}
