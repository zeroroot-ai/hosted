#!/usr/bin/env bats
#
# rotation-helpers.bats: the certificate helpers of the rotation drill read
# the right fields (ADR-0171, hosted#444).
#
# Offline. The test makes a real CA and leaf with openssl and runs the real
# helper functions of test/rotation/exit-test-rotation.sh, taken out of the
# script text. The spire-svid check compares the authority key id of a served
# SVID with the authority id that SPIRE reports, so a helper that reads the
# wrong field makes that check pass or fail on nothing.
#
# Run:
#   bats tests/harness/rotation-helpers.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TEST="$REPO_ROOT/test/rotation/exit-test-rotation.sh"

setup() {
  TMP="$(mktemp -d)"
  # The helper functions, taken out of the script. Sourcing the whole script
  # would run it.
  python3 - "$TEST" "$TMP/helpers.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
out = []
for name in ("ski_of", "aki_of", "mint_probe", "bundle_skis"):
    m = re.search(r"^%s\(\) \{.*?^\}\n|^%s\(\) \{[^\n]*\}\n" % (name, name), text, re.M | re.S)
    if not m:
        sys.exit("no function %s in the script" % name)
    out.append(m.group(0))
open(sys.argv[2], "w").write("\n".join(out))
PY
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=probe-ca" -keyout "$TMP/ca.key" -out "$TMP/ca.pem" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj "/CN=probe-leaf" -keyout "$TMP/leaf.key" -out "$TMP/leaf.csr" 2>/dev/null
  printf 'authorityKeyIdentifier=keyid\nsubjectKeyIdentifier=hash\n' > "$TMP/ext.cnf"
  openssl x509 -req -in "$TMP/leaf.csr" -CA "$TMP/ca.pem" -CAkey "$TMP/ca.key" -CAcreateserial \
    -days 1 -extfile "$TMP/ext.cnf" -out "$TMP/leaf.pem" 2>/dev/null
}

teardown() { rm -rf "$TMP"; }

@test "aki_of of a leaf equals ski_of of its CA, in lower-case hex" {
  run bash -c ". '$TMP/helpers.sh'; a=\$(aki_of < '$TMP/leaf.pem'); s=\$(ski_of < '$TMP/ca.pem'); echo \"\$a \$s\"; [ -n \"\$a\" ] && [ \"\$a\" = \"\$s\" ] && [[ \"\$a\" =~ ^[0-9a-f]+\$ ]]"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "FAILING FIXTURE: aki_of of a leaf differs from the ski_of of another CA" {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=other-ca" -keyout "$TMP/other.key" -out "$TMP/other.pem" 2>/dev/null
  run bash -c ". '$TMP/helpers.sh'; [ \"\$(aki_of < '$TMP/leaf.pem')\" = \"\$(ski_of < '$TMP/other.pem')\" ]"
  [ "$status" -ne 0 ]
}

@test "mint_probe prints the SVID certificate and drops the key" {
  mkdir -p "$TMP/bin"
  { echo "X509-SVID:"; cat "$TMP/leaf.pem"; echo; echo "Private key:"; cat "$TMP/leaf.key"; echo; echo "Root CAs:"; cat "$TMP/ca.pem"; } > "$TMP/mint.out"
  run bash -c ". '$TMP/helpers.sh'; spire() { cat '$TMP/mint.out'; }; mint_probe 5m example.org"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEGIN CERTIFICATE"* ]]
  [[ "$output" != *"PRIVATE KEY"* ]]
  [ "$(printf '%s\n' "$output" | openssl x509 -noout -subject)" = "$(openssl x509 -noout -subject < "$TMP/leaf.pem")" ]
}

@test "FAILING FIXTURE: mint_probe fails when mint fails" {
  run bash -c ". '$TMP/helpers.sh'; spire() { return 1; }; mint_probe 5m example.org"
  [ "$status" -ne 0 ]
}

@test "bundle_skis lists the subject key id of each certificate of a bundle" {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=other-ca" -keyout "$TMP/other.key" -out "$TMP/other.pem" 2>/dev/null
  cat "$TMP/ca.pem" "$TMP/other.pem" > "$TMP/bundle.pem"
  run bash -c ". '$TMP/helpers.sh'; bundle_skis '$TMP/bundle.pem'"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$(bash -c ". '$TMP/helpers.sh'; ski_of < '$TMP/ca.pem'")" ]
  [ "${lines[1]}" = "$(bash -c ". '$TMP/helpers.sh'; ski_of < '$TMP/other.pem'")" ]
}

# bao_ids reads the seal key ids from the seal stanza of the openbao
# container, not from its start log line, which the audit device rotates out
# in minutes (second drill sweep, row 18). The kubectl stub answers only that
# one read (hosted#654).
bao_ids_env() {
  python3 - "$TEST" "$TMP/bao.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^bao_ids\(\) \{.*?^\}\n", text, re.M | re.S)
if not m:
    sys.exit("no function bao_ids in the script")
open(sys.argv[2], "w").write(m.group(0))
PY
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n gibson exec gibson-openbao-0 -c openbao -- cat /tmp/seal.hcl")
    [ -f "$TMP/seal.hcl" ] || { echo "cat: /tmp/seal.hcl: No such file or directory" >&2; exit 1; }
    cat "$TMP/seal.hcl"; exit 0 ;;
esac
echo "kubectl stub: undeclared call: $*" >&2; exit 1
SH
  chmod +x "$TMP/bin/kubectl"
}

@test "bao_ids reads the current seal key id from the seal stanza" {
  bao_ids_env
  printf 'seal "static" {\n  current_key_id = "keyring-aaaa"\n  current_key    = "file:///k/cur"\n}\n' > "$TMP/seal.hcl"
  run env TMP="$TMP" PATH="$TMP/bin:$PATH" bash -c 'NS=gibson; OPENBAO_POD=gibson-openbao-0; . "$TMP/bao.sh"; bao_ids'
  [ "$output" = "[openbao] seal key id keyring-aaaa" ]
}

@test "bao_ids reads the current and the previous seal key id during a rotation" {
  bao_ids_env
  printf 'seal "static" {\n  current_key_id = "keyring-bbbb"\n  current_key    = "file:///k/cur"\n  previous_key_id = "keyring-aaaa"\n  previous_key    = "file:///k/prev"\n}\n' > "$TMP/seal.hcl"
  run env TMP="$TMP" PATH="$TMP/bin:$PATH" bash -c 'NS=gibson; OPENBAO_POD=gibson-openbao-0; . "$TMP/bao.sh"; bao_ids'
  [ "$output" = "[openbao] seal key id keyring-bbbb, previous keyring-aaaa" ]
}

@test "FAILING FIXTURE: no seal stanza gives no ids, and the class then stops" {
  bao_ids_env
  run env TMP="$TMP" PATH="$TMP/bin:$PATH" bash -c 'NS=gibson; OPENBAO_POD=gibson-openbao-0; . "$TMP/bao.sh"; bao_ids'
  [ -z "$output" ]
}

@test "FAILING FIXTURE: a pod name the stub does not declare reads nothing" {
  bao_ids_env
  printf 'seal "static" {\n  current_key_id = "keyring-aaaa"\n}\n' > "$TMP/seal.hcl"
  run env TMP="$TMP" PATH="$TMP/bin:$PATH" bash -c 'NS=gibson; OPENBAO_POD=gibson-workloads-openbao-0; . "$TMP/bao.sh"; bao_ids'
  [ -z "$output" ]
}

@test "no rotation class reads a start-time line from a container log" {
  # The one log read that decides is the --since-time read of the class
  # window. diagnose_failed_class prints log tails for a person and decides
  # nothing, so its body is left out of the search.
  python3 - "$TEST" "$TMP/no-diag.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r"^diagnose_failed_class\(\) \(.*?^\)\n", "", text, flags=re.M | re.S)
# velero_diagnose prints the log of the Velero server for a person, too.
text = re.sub(r"^velero_diagnose\(\) \{.*?^\}\n", "", text, flags=re.M | re.S)
open(sys.argv[2], "w").write(text)
PY
  run grep -nE 'kubectl[^|]*\blogs\b' "$TMP/no-diag.sh"
  [ "$(printf '%s\n' "$output" | grep -vc -- '--since-time')" -eq 0 ] || { echo "$output"; false; }
}

# set_at_source writes a rotated value through the charts setter with the
# value on stdin and two arguments (charts#679): an argument is readable by
# every local user, and the setter refuses a third one.
@test "set_at_source gives the setter the value on stdin and two arguments" {
  python3 - "$TEST" "$TMP/set.sh" <<'PY'
import re, sys
m = re.search(r"^set_at_source\(\) \{.*?^\}\n", open(sys.argv[1]).read(), re.M | re.S)
open(sys.argv[2], "w").write(m.group(0))
PY
  mkdir -p "$TMP/charts/scripts"
  cat > "$TMP/charts/scripts/baseline-set-secret.sh" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 2 ] || { echo "setter stub: $# arguments" >&2; exit 2; }
printf '%s %s ' "$1" "$2" > "$REC"; cat >> "$REC"
SH
  chmod +x "$TMP/charts/scripts/baseline-set-secret.sh"
  run env REC="$TMP/rec" bash -c "NS=gibson RELEASE=gibson CHARTS_ROOT='$TMP/charts'; . '$TMP/set.sh'; set_at_source gibson-x password 'v4lue-xyz'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$TMP/rec")" = "gibson-x password v4lue-xyz" ]
  [ "$(grep -c 'baseline-set-secret.sh "\$1" "\$2" "\$3"' "$TEST")" = 0 ]
  # The one call of the setter is set_at_source: every class writes through it.
  [ "$(grep -v '^\s*#' "$TEST" | grep -c 'scripts/baseline-set-secret.sh" "\$')" = 1 ]
}

# set_at_source --object writes all the properties of a key in one write, with
# the JSON on stdin and the key as the one argument after --object (charts#738).
@test "set_at_source --object gives the setter the object on stdin, in one call" {
  python3 - "$TEST" "$TMP/set.sh" <<'EOPY'
import re, sys
m = re.search(r"^set_at_source\(\) \{.*?^\}\n", open(sys.argv[1]).read(), re.M | re.S)
open(sys.argv[2], "w").write(m.group(0))
EOPY
  mkdir -p "$TMP/charts/scripts"
  cat > "$TMP/charts/scripts/baseline-set-secret.sh" <<'SH'
#!/usr/bin/env bash
[ "$#" -eq 2 ] && [ "$1" = --object ] || { echo "setter stub: $*" >&2; exit 2; }
printf '%s ' "$2" >> "$REC"; cat >> "$REC"
SH
  chmod +x "$TMP/charts/scripts/baseline-set-secret.sh"
  run env REC="$TMP/rec" D="$TMP" bash -c 'NS=gibson RELEASE=gibson CHARTS_ROOT="$D/charts"; . "$D/set.sh"; set_at_source --object gibson-cg-signing-key-previous "{\"kid\":\"\",\"key\":\"\"}"'
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$TMP/rec")" = 'gibson-cg-signing-key-previous {"kid":"","key":""}' ]
}

# The next slot that step 1 of platform-signing-keys writes holds both the new
# kid and its seed, in ONE object (review of hosted#49). The class runs with
# stubs up to that write; the stub setter records it and fails, so the class
# stops there.
next_slot_write() {
  python3 - "$1" "$TMP/cg.sh" <<'EOPY'
import re, sys
text = open(sys.argv[1]).read()
out = [re.search(r"^CG_KEY_KEY=.*$", text, re.M).group(0), re.search(r"^CG_SVID_SLACK_S=.*$", text, re.M).group(0)]
for n in ("set_at_source", "class_platform_signing_keys"):
    out.append(re.search(r"^%s\(\) \{.*?^\}\n" % n, text, re.M | re.S).group(0))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
EOPY
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj "/CN=reader" -keyout "$TMP/svid.key" -out "$TMP/svid.pem" 2>/dev/null
  mkdir -p "$TMP/charts/scripts"
  cat > "$TMP/charts/scripts/baseline-set-secret.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$REC.args"; cat >> "$REC"; exit 1
SH
  chmod +x "$TMP/charts/scripts/baseline-set-secret.sh"
  : > "$TMP/rec"; : > "$TMP/rec.args"
  run env REC="$TMP/rec" D="$TMP" bash -c '
    NS=gibson RELEASE=gibson DAEMON_STS=gibson-gibson-workloads ROTATION_WAIT=1500 CHARTS_ROOT="$D/charts"
    ok() { echo "ok: $*"; }
    miss() { echo "miss: $*"; return 1; }
    secret_value() { [ "$1 $2" = "gibson-gibson-workloads-cg-signing-key current.kid" ] && echo kid0; }
    kubectl() {
      case "$*" in
        "-n gibson get configmap gibson-server -o jsonpath={.data.server\.conf}") echo "{\"server\":{\"trust_domain\":\"example.org\"}}" ;;
        "-n gibson get statefulset gibson-gibson-workloads -o json")
          echo "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"env\":[{\"name\":\"GIBSON_AUTHZ_REGISTRY_READER_SVIDS\",\"value\":\"spiffe://example.org/platform/ext-authz\"}]}]}}}}" ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    spire() { cat "$D/svid.pem" "$D/svid.key"; }
    spire_bundle() { cp "$D/svid.pem" "$1"; }
    cg_all_pods() { return 0; }
    . "$D/cg.sh"; class_platform_signing_keys' _
}

@test "step 1 writes the next slot as one object with the new kid and its 32-byte seed" {
  next_slot_write "$TEST"
  [[ "$output" == *"miss: the write of the next kid failed"* ]] || { echo "$output"; false; }
  [ "$(cat "$TMP/rec.args")" = "--object gibson-cg-signing-key-next" ] || { cat "$TMP/rec.args"; false; }
  run python3 - "$TMP/rec" <<'EOPY'
import base64, json, re, sys
o = json.loads(open(sys.argv[1]).read())
assert sorted(o) == ["key", "kid"], sorted(o)
assert re.fullmatch(r"drill[a-z0-9]{8}", o["kid"]), o["kid"]
k = o["key"]
assert len(base64.urlsafe_b64decode(k + "=" * (-len(k) % 4))) == 32, k
EOPY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a next slot with no key is refused by the step 1 check" {
  sed 's/"$(printf '"'"'{"kid":"%s","key":"%s"}'"'"' "$new" "$seed")"/"$(printf '"'"'{"kid":"%s"}'"'"' "$new")"/' "$TEST" > "$TMP/nokey.sh"
  run grep -c "printf '{\"kid\":\"%s\"}' \"\$new\"" "$TMP/nokey.sh"
  [ "$output" -eq 1 ]
  next_slot_write "$TMP/nokey.sh"
  run python3 -c 'import json,sys; o=json.loads(open(sys.argv[1]).read()); assert sorted(o) == ["key", "kid"], sorted(o)' "$TMP/rec"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: no slot of the CG signing key is written one property at a time" {
  python3 - "$TEST" "$TMP/cg.sh" <<'EOPY'
import re, sys
m = re.search(r"^class_platform_signing_keys\(\) \{.*?^\}\n", open(sys.argv[1]).read(), re.M | re.S)
open(sys.argv[2], "w").write(m.group(0))
EOPY
  one='set_at_source "\$\{CG_KEY_KEY\}-(next|previous)" (kid|key) '
  run grep -cE "$one" "$TMP/cg.sh"
  [ "$output" -eq 0 ] || { grep -nE "$one" "$TMP/cg.sh"; false; }
  run grep -cF 'set_at_source --object "${CG_KEY_KEY}-' "$TMP/cg.sh"
  [ "$output" -eq 2 ]
  # The fixture: the form for charts 0.151.1 was two writes, and the check sees it.
  printf '%s\n' '  set_at_source "${CG_KEY_KEY}-previous" kid "" && set_at_source "${CG_KEY_KEY}-previous" key ""' > "$TMP/old.sh"
  run grep -cE "$one" "$TMP/old.sh"
  [ "$output" -eq 1 ]
}

# --- consumer_on_role (hosted#591) -------------------------------------------
# kubectl is a stub. STUB_PODS is the pod list, one "name start ip deleted|ready"
# line each. pg_su models Postgres: STUB_SESSIONS sessions of v-new exist, all
# from 10.0.0.5. A query with no client_addr filter sees all of them. A query
# with the filter sees them only when its IP list holds 10.0.0.5. So a check
# that drops the filter passes the "another workload" case, and that case
# fails it (hosted#737 review).
consumer_helpers() {
  python3 - "$TEST" "$TMP/consumer.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^consumer_on_role\(\) \{.*?^\}\n", text, re.M | re.S)
if not m:
    sys.exit("no function consumer_on_role in the script")
open(sys.argv[2], "w").write(m.group(0))
PY
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n gibson get deployment/gibson-billing-webhook -o jsonpath={.spec.selector.matchLabels}")
    printf '{"app.kubernetes.io/name":"billing-webhook"}' ;;
  "-n gibson get deployment/gibson-billing-webhook -o jsonpath={.spec.replicas}") printf '%s' "${STUB_REPLICAS:-1}" ;;
  "-n gibson get pods -l app.kubernetes.io/name=billing-webhook -o jsonpath="*) printf '%b' "$STUB_PODS" ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
}

run_consumer() {
  PATH="$TMP/bin:$PATH" run bash -c '
    NS=gibson
    ok() { echo "ok: $*"; }
    miss() { echo "miss: $*"; return 1; }
    pg_su() {
      case "$1" in *"usename = '"'"'v-new'"'"'"*) ;; *) echo 0; return 0 ;; esac
      case "$1" in
        *client_addr*"'"'"'10.0.0.5'"'"'"*) echo "${STUB_SESSIONS:-0}" ;;
        *client_addr*) echo 0 ;;
        *) echo "${STUB_SESSIONS:-0}" ;;
      esac
    }
    . "$1"
    consumer_on_role deployment/gibson-billing-webhook v-new "$2" "$3"' _ "$TMP/consumer.sh" "$@"
}

@test "a consumer whose pods all restarted after the rotation, with a session of the new role from them, passes" {
  consumer_helpers
  since=$(( $(date +%s) - 600 ))
  export STUB_PODS="billing-a $(date -u -d @$(( since + 60 )) +%Y-%m-%dT%H:%M:%SZ) 10.0.0.5 |True\n" STUB_SESSIONS=2
  run_consumer "$since" $(( $(date +%s) + 60 ))
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ok: deployment/gibson-billing-webhook runs a new generation: 1 Ready pod(s)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"holds 2 session(s) of v-new from its own pods"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a pod that started before the rotation fails the consumer, however Ready it is" {
  consumer_helpers
  since=$(( $(date +%s) - 600 ))
  export STUB_PODS="billing-old $(date -u -d @$(( since - 60 )) +%Y-%m-%dT%H:%M:%SZ) 10.0.0.4 |True\n" STUB_SESSIONS=2
  run_consumer "$since" $(( $(date +%s) - 1 ))
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"0 Ready pod(s) started after the rotation and 1 other(s)"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a session of the new role from another workload does not count" {
  consumer_helpers
  since=$(( $(date +%s) - 600 ))
  export STUB_PODS="billing-a $(date -u -d @$(( since + 60 )) +%Y-%m-%dT%H:%M:%SZ) 10.0.0.9 |True\n" STUB_SESSIONS=2
  run_consumer "$since" $(( $(date +%s) - 1 ))
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Postgres holds no session of v-new from its pods ('10.0.0.9')"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a workload with 0 replicas is refused at once" {
  consumer_helpers
  since=$(( $(date +%s) - 600 ))
  export STUB_PODS="" STUB_REPLICAS=0
  run_consumer "$since" $(( $(date +%s) + 600 ))
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"has 0 replicas, so no pod of it can run on v-new"* ]] || { echo "$output"; false; }
}

@test "a pod that is being deleted is not counted against the new generation" {
  consumer_helpers
  since=$(( $(date +%s) - 600 ))
  export STUB_PODS="billing-old $(date -u -d @$(( since - 60 )) +%Y-%m-%dT%H:%M:%SZ) 10.0.0.4 2026-10-14T12:00:00Z|True\nbilling-a $(date -u -d @$(( since + 60 )) +%Y-%m-%dT%H:%M:%SZ) 10.0.0.5 |True\n" STUB_SESSIONS=1
  run_consumer "$since" $(( $(date +%s) + 60 ))
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# --- substrate-cloud-credentials during an open rotation ----------------------
# The monthly rotation job starts a key rotation of each drill IAM user before
# the class test runs, so each user then has two active keys until a later
# daily run deletes the old one (scripts/drill-rotate-keys.sh). aws and
# kubectl are stubs. STUB_KEYS is the list-access-keys answer of every user,
# STUB_OLD_USED the last use of the old key (an RFC 3339 time or None).
substrate_helpers() {
  python3 - "$TEST" "$TMP/substrate.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
out = []
for name in ("secret_value", "key_last_used", "class_substrate_cloud_credentials"):
    m = re.search(r"^%s\(\) \{.*?^\}\n" % name, text, re.M | re.S)
    if not m:
        sys.exit("no function %s in the script" % name)
    out.append(m.group(0))
open(sys.argv[2], "w").write("\n".join(out))
PY
  mkdir -p "$TMP/bin" "$TMP/state"
  cat > "$TMP/bin/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "iam list-access-keys --user-name zeroroot-ai-drill-platform --output json"|\
  "iam list-access-keys --user-name zeroroot-ai-drill-dns --output json"|\
  "iam list-access-keys --user-name zeroroot-ai-drill-setec-disk-builder --output json"|\
  "iam list-access-keys --user-name zeroroot-ai-drill-smtp --output json")
    printf '%s' "$STUB_KEYS" ;;
  "iam get-access-key-last-used --access-key-id AKIAOLD "*) printf '%s\n' "${STUB_OLD_USED:-None}" ;;
  *) echo "aws stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  # Each Secret key the class reads holds the new key id AKIANEW.
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n gibson get secret bringup-keyring -o json"|"-n gibson get secret route53-credential -o json"|"-n gibson get secret setec-disk-push-credential -o json")
    v="$(printf AKIANEW | base64 -w0)"
    printf '{"data":{"bucket-access-key":"%s","access-key-id":"%s","smtp-username":"%s"}}' "$v" "$v" "$v" ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/aws" "$TMP/bin/kubectl"
  : > "$TMP/state/substrate.env"
}

open_slots() {
  printf '{"key_slots":{"platform":{"active":"b","keep":["a","b"]},"smtp":{"active":"b","keep":["a","b"]},"dns":{"active":"b","keep":["a","b"]},"setec-disk-builder":{"active":"b","keep":["a","b"]}}}' > "$TMP/state/key-slots.tfvars.json"
  printf '{"platform":%s,"smtp":%s,"dns":%s,"setec-disk-builder":%s}' "$1" "$1" "$1" "$1" > "$TMP/state/key-rotation.json"
}

run_substrate() {
  PATH="$TMP/bin:$PATH" run bash -c '
    NS=gibson ENV=drill SUBSTRATE_ENV_FILE="$1/substrate.env" SUBSTRATE_KEY_LIFETIME_DAYS=90
    ok() { echo "ok: $*"; }
    miss() { echo "miss: $*"; return 1; }
    . "$2"
    class_substrate_cloud_credentials' _ "$TMP/state" "$TMP/substrate.sh"
}

two_keys() {
  printf '{"AccessKeyMetadata":[{"AccessKeyId":"AKIAOLD","Status":"Active","CreateDate":"%s"},{"AccessKeyId":"AKIANEW","Status":"Active","CreateDate":"%s"}]}' \
    "$(date -u -d '-30 days' +%FT%TZ)" "$(date -u -d '-1 hour' +%FT%TZ)"
}

@test "one active key that the cluster holds passes" {
  substrate_helpers
  export STUB_KEYS="$(printf '{"AccessKeyMetadata":[{"AccessKeyId":"AKIANEW","Status":"Active","CreateDate":"%s"}]}' "$(date -u -d '-3 days' +%FT%TZ)")"
  run_substrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '^ok: .*one active key' <<<"$output")" = 4 ] || { echo "$output"; false; }
}

@test "an open rotation, the cluster on the newer key and the old key unused since the switch, passes" {
  substrate_helpers
  open_slots "$(date -d '-1 hour' +%s)"
  export STUB_KEYS="$(two_keys)" STUB_OLD_USED="$(date -u -d '-2 hours' +%FT%TZ)"
  run_substrate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '^ok: .*a rotation is open' <<<"$output")" = 4 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: two active keys with no open rotation in the slots fail" {
  substrate_helpers
  export STUB_KEYS="$(two_keys)"
  run_substrate
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"has 2 active access keys, not 1"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: an open rotation whose old key was used after the switch fails" {
  substrate_helpers
  open_slots "$(date -d '-1 hour' +%s)"
  export STUB_KEYS="$(two_keys)" STUB_OLD_USED="$(date -u -d '-5 minutes' +%FT%TZ)"
  run_substrate
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"after the switch: a consumer still holds it"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: an open rotation with the cluster still on the old key fails, and names the start step" {
  substrate_helpers
  open_slots "$(date -d '-1 hour' +%s)"
  sed -i 's/printf AKIANEW/printf AKIAOLD/' "$TMP/bin/kubectl"
  export STUB_KEYS="$(two_keys)" STUB_OLD_USED=None
  run_substrate
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"the cluster still holds the old key. The step 'Start the access key rotation' did not reach the cluster"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: an open rotation with the cluster on a key of neither slot fails" {
  substrate_helpers
  open_slots "$(date -d '-1 hour' +%s)"
  sed -i 's/printf AKIANEW/printf AKIAOTHER/' "$TMP/bin/kubectl"
  export STUB_KEYS="$(two_keys)" STUB_OLD_USED=None
  run_substrate
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"which is neither key of the user"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: an open rotation with no recorded switch time fails" {
  substrate_helpers
  open_slots 0
  export STUB_KEYS="$(two_keys)"
  run_substrate
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  [[ "$output" == *"records no switch time"* ]] || { echo "$output"; false; }
}

# --- velero_backup and the Velero queue (drill 38484872614, hosted#731) -------
# kubectl is a stub. The hourly backup stays InProgress for STUB_BUSY reads of
# the backup list, then Completed. The backup of the check then reads
# STUB_PHASE. sleep is a no-op, so the waits cost no time.
velero_helpers() {
  python3 - "$TEST" "$TMP/velero.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
out = []
for name in ("velero_in_flight", "velero_storage_ready", "velero_diagnose", "velero_delete_backup", "velero_pod_start", "velero_refusal_step", "password_refused", "password_named", "redact_add", "velero_backup"):
    m = re.search(r"^%s\(\) \{.*?^\}\n" % name, text, re.M | re.S)
    if not m:
        sys.exit("no function %s in the script" % name)
    out.append(m.group(0))
for const in ("VELERO_IN_FLIGHT_PHASES", "VELERO_READY_WAIT", "VELERO_PICKUP_WAIT", "VELERO_DELETE_WAIT", "VELERO_RESTARTED_AT", "VELERO_LAST_FILE", "VELERO_SCHEDULE", "VELERO_PASSWORD_ERROR"):
    m = re.search(r'^%s=.*\n' % const, text, re.M)
    if not m:
        sys.exit("no %s in the script" % const)
    out.insert(0, m.group(0))
open(sys.argv[2], "w").write("\n".join(out))
PY
  mkdir -p "$TMP/bin"
  : > "$TMP/reads"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n velero get backups.velero.io -o json")
    echo x >> "$STUB_DIR/reads"
    if [ "$(wc -l < "$STUB_DIR/reads")" -le "${STUB_BUSY:-0}" ]; then p=InProgress; else p=Completed; fi
    printf '{"items":[{"metadata":{"name":"platform-hourly-1"},"status":{"phase":"%s"}}]}' "$p" ;;
  "apply -f -") cat > "$STUB_DIR/applied"; echo x >> "$STUB_DIR/applies" ;;
  # The shipped Schedule, in the shape of helm/gibson-velero (charts):
  # every tenant namespace, and the kinds that the RBAC denies excluded.
  # STUB_NO_SCHEDULE: the read fails.
  "-n velero get schedule.velero.io/platform-hourly -o json")
    [ -z "${STUB_NO_SCHEDULE:-}" ] || { echo 'Error from server (NotFound): schedules.velero.io "platform-hourly" not found' >&2; exit 1; }
    [ -z "${STUB_SCHEDULE_JSON:-}" ] || { printf '%s' "$STUB_SCHEDULE_JSON"; exit 0; }
    echo '{"metadata":{"name":"platform-hourly","namespace":"velero"},"spec":{"schedule":"0 * * * *","template":{"includedNamespaces":["gibson","tenant-*"],"excludedNamespaceScopedResources":["secrets","*.generators.external-secrets.io"],"excludedClusterScopedResources":["helmchartconfigs.helm.cattle.io"],"includedClusterScopedResources":["tenants.gibson.zeroroot.ai"],"defaultVolumesToFsBackup":true,"ttl":"720h0m0s"}}}' ;;
  # The storage locations. STUB_BSL: the phase (default Available).
  # STUB_BSL_VALIDATED: the lastValidationTime (default: far in the future).
  "-n velero get backupstoragelocations.velero.io -o jsonpath="*) printf '%s %s\n' "${STUB_BSL:-Available}" "${STUB_BSL_VALIDATED-2099-01-01T00:00:00Z}" ;;
  # STUB_PHASE_FIRST_EMPTY: the first backup of the check has no phase, as a
  # server that does not reconcile it. STUB_PHASE_EMPTY: every backup has none.
  # A bound, so a loop that never ends fails the test instead of hanging it.
  "-n velero get backups.velero.io rotation-drill-"*" -o jsonpath={.status.phase}")
    echo x >> "$STUB_DIR/phase-reads"
    if [ "$(wc -l < "$STUB_DIR/phase-reads")" -gt 50 ]; then printf 'Completed'
    elif [ -n "${STUB_PHASE_EMPTY:-}" ]; then :
    elif [ -n "${STUB_PHASE_FIRST_EMPTY:-}" ] && [[ "$5" == *-1 ]]; then :
    else printf '%s' "$STUB_PHASE"; fi ;;
  # STUB_DELETE_FAILS: the delete fails. STUB_STAYS: the delete works and the
  # backup is still there.
  "-n velero delete backups.velero.io rotation-drill-"*" --ignore-not-found --wait=false")
    [ -z "${STUB_DELETE_FAILS:-}" ] || exit 1
    echo "$5" >> "$STUB_DIR/deleted" ;;
  "-n velero get backups.velero.io rotation-drill-"?*)
    # The check that a deleted backup is gone: --ignore-not-found -o name.
    # STUB_GET_ERROR: the API does not answer.
    if [ "$#" -eq 8 ] && [ "$6" = --ignore-not-found ]; then
      [ -z "${STUB_GET_ERROR:-}" ] || { echo "The connection to the server was refused - did you specify the right host or port? (connection refused)" >&2; exit 1; }
      if [ -n "${STUB_STAYS:-}" ] || ! grep -qx "$5" "$STUB_DIR/deleted" 2>/dev/null; then echo "backup.velero.io/$5"; fi
      exit 0
    fi
    echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
  # What the diagnostics read.
  # The Velero server pods: two start times, the newest counts.
  "-n velero get pods -l name=velero -o jsonpath="*)
    [ -n "${STUB_POD_NONE:-}" ] || printf '2026-10-20T12:00:00Z\n%s\n' "${STUB_POD_START:-2026-10-20T13:00:05Z}" ;;
  "-n velero get pods -o wide"|"-n velero get backupstoragelocations.velero.io"|"-n velero logs -l name=velero --tail=60") echo "stub diagnostics" ;;
  "-n velero get backups.velero.io rotation-drill-"*" -o yaml") printf 'status:\n  phase: ""\n' ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
}

run_velero() {
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" run bash -c '
    NS=gibson VELERO_QUEUE_WAIT="$2" VELERO_RUN_WAIT="${3:-900}" VELERO_PICKUP_WAIT=0 VELERO_READY_WAIT=0 VELERO_DELETE_WAIT=0 VELERO_RESTARTED_AT="${STUB_RESTARTED_AT-2026-10-20T13:00:00Z}" VELERO_LAST_FILE="$STUB_DIR/last"
    sleep() { :; }
    . "$1"
    velero_backup' _ "$TMP/velero.sh" "$1" "${2:-900}"
}

@test "velero_backup waits for the backup in flight, then reports the end phase of its own backup" {
  velero_helpers
  export STUB_BUSY=3 STUB_PHASE=Completed
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = Completed ] || { echo "$output"; false; }
  [ "$(wc -l < "$TMP/reads")" -eq 4 ] || { cat "$TMP/reads"; false; }
  # The spec of the shipped Schedule, narrowed to the OpenBao pod of the
  # release namespace. Its exclusions stay (drill rotation run 40438631534).
  jq -e '.kind == "Backup" and .metadata.namespace == "velero"
         and .spec.includedNamespaces == ["gibson"]
         and .spec.labelSelector.matchLabels["app.kubernetes.io/component"] == "openbao"
         and (.spec.excludedNamespaceScopedResources | index("secrets"))
         and .spec.excludedClusterScopedResources == ["helmchartconfigs.helm.cattle.io"]
         and .spec.defaultVolumesToFsBackup == true and .spec.ttl == "1h0m0s"' "$TMP/applied" \
    || { cat "$TMP/applied"; false; }
  # The diagnostics after a failed backup read its name from this file.
  grep -qE '^rotation-drill-[0-9]+-1$' "$TMP/last" || { cat "$TMP/last"; false; }
}

@test "FAILING FIXTURE: a Schedule that cannot be read makes no backup, and is never a refusal" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=PartiallyFailed STUB_NO_SCHEDULE=1
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | tail -n 1)" = no-schedule ] || { echo "$output"; false; }
  # The error of the read stays on stderr.
  [[ "$output" == *'schedules.velero.io "platform-hourly" not found'* ]] || { echo "$output"; false; }
  [ ! -e "$TMP/applied" ]
  run bash -c '. "$1"; miss() { echo "MISS $*"; return 1; }; VELERO_SCHEDULE=platform-hourly; password_refused no-schedule' _ "$TMP/velero.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISS the Schedule velero/platform-hourly could not be read"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a Schedule template with no excluded kinds makes no backup (hosted#153 review)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=Completed
  export STUB_SCHEDULE_JSON='{"spec":{"template":{"includedNamespaces":["gibson"],"defaultVolumesToFsBackup":true}}}'
  run_velero 3600
  [ "$(printf '%s\n' "$output" | tail -n 1)" = no-schedule ] || { echo "$output"; false; }
  [ ! -e "$TMP/applied" ]
}

@test "a Schedule template with orLabelSelectors gives a Backup with the OpenBao labelSelector alone (hosted#153 review)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=Completed
  export STUB_SCHEDULE_JSON='{"spec":{"template":{"includedNamespaces":["gibson"],"excludedNamespaceScopedResources":["secrets"],"orLabelSelectors":[{"matchLabels":{"a":"b"}}]}}}'
  run_velero 3600
  [ "$output" = Completed ] || { echo "$output"; false; }
  jq -e '(.spec | has("orLabelSelectors") | not) and .spec.labelSelector.matchLabels["app.kubernetes.io/component"] == "openbao"' "$TMP/applied" \
    || { cat "$TMP/applied"; false; }
}

@test "FAILING FIXTURE: a queue that does not clear in VELERO_QUEUE_WAIT is a timeout, and no backup is created" {
  velero_helpers
  export STUB_BUSY=100000 STUB_PHASE=Completed
  run_velero 0
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == "timeout:queue (platform-hourly-1)" ]] || { echo "$output"; false; }
  [ ! -e "$TMP/applied" ]
}

@test "FAILING FIXTURE: a backup list that cannot be read is a busy queue, not an empty one" {
  velero_helpers
  sed -i 's|^  "-n velero get backups.velero.io -o json")$|  "-n velero get backups.velero.io -o json") [ -z "${STUB_LIST_BROKEN:-}" ] \|\| exit 1|' "$TMP/bin/kubectl"
  export STUB_BUSY=0 STUB_PHASE=Completed STUB_LIST_BROKEN=1
  run_velero 0
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "timeout:queue ((the backup list could not be read))" ] || { echo "$output"; false; }
  [ ! -e "$TMP/applied" ]
}

@test "FAILING FIXTURE: a backup that stays InProgress past VELERO_RUN_WAIT is a timeout" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=InProgress
  run_velero 3600 0
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "timeout:InProgress" ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a backup that stays Queued past VELERO_QUEUE_WAIT is a timeout, not a refusal" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=Queued
  run_velero 0
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "timeout:Queued" ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a backup that the Velero server did not pick up is deleted and made once more (drill rotation run 1)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=PartiallyFailed STUB_PHASE_FIRST_EMPTY=1
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = PartiallyFailed ] || { echo "$output"; false; }
  [ "$(wc -l < "$TMP/applies")" -eq 2 ]
  [ "$(wc -l < "$TMP/deleted")" -eq 1 ]
  [[ "$output" == *"the Velero server, for backup rotation-drill-"*"-1"* ]]
}

@test "FAILING FIXTURE: a backup that is never picked up is a timeout with the diagnostics, and none is left behind (drill rotation run 1)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE_EMPTY=1
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = "timeout:unreconciled" ] || { echo "$output"; false; }
  [ "$(wc -l < "$TMP/applies")" -eq 2 ]
  [ "$(wc -l < "$TMP/deleted")" -eq 2 ]
  [[ "$output" == *"stub diagnostics"* ]]
}

@test "FAILING FIXTURE: a storage location that is not Available after the restart is a timeout, and no backup is made (drill rotation run 1)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=Completed STUB_BSL=Unavailable
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = "timeout:storage-location" ] || { echo "$output"; false; }
  [ ! -e "$TMP/applied" ]
}

@test "FAILING FIXTURE: an unpicked backup whose delete fails is a stale backup, and no second backup is made (hosted#68 review)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE_EMPTY=1 STUB_DELETE_FAILS=1
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = "timeout:stale-backup" ] || { echo "$output"; false; }
  [ "$(wc -l < "$TMP/applies")" -eq 1 ]
}

@test "FAILING FIXTURE: an unpicked backup that is still there after its delete is a stale backup (hosted#68 review)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE_EMPTY=1 STUB_STAYS=1
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = "timeout:stale-backup" ] || { echo "$output"; false; }
  [ "$(wc -l < "$TMP/applies")" -eq 1 ]
}

@test "velero_pod_start reads the newest start time of the Velero pods, from the cluster (hosted#68 review)" {
  velero_helpers
  STUB_POD_START=2026-10-20T13:07:09Z PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" run bash -c '. "$1"; velero_pod_start' _ "$TMP/velero.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "2026-10-20T13:07:09Z" ] || { echo "$output"; false; }
}

# velero_refusal_step runs with k2c, velero_restart and the backup stubbed. The
# backup prints the reference time it sees, and the stub pods give the times.
refusal_step() {
  velero_helpers
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" run bash -c '
    NS=gibson VELERO_READY_WAIT=0
    sleep() { :; }
    miss() { echo "miss: $*"; return 1; }
    ok() { echo "ok: $*"; }
    k2c() { echo "k2c ${1:-<keyring>}" >> "$STUB_DIR/calls"; return 0; }
    velero_restart() { echo restart >> "$STUB_DIR/calls"; return 0; }
    . "$1"
    # The backup sees the reference time that the step set.
    velero_backup() { echo "reference=$VELERO_RESTARTED_AT" >&2; printf PartiallyFailed; }
    # password_named has its own tests below. STUB_NOT_NAMED: no error names
    # the password. STUB_EVIDENCE: the line it found.
    password_named() { [ -z "${STUB_NOT_NAMED:-}" ] && printf "%s\n" "${STUB_EVIDENCE:-PodVolumeBackup p1: invalid repository password}"; }
    velero_refusal_step "${STUB_WORK:-/nonexistent}"; rc=$?
    echo "final=$VELERO_RESTARTED_AT"
    exit $rc' _ "$TMP/velero.sh"
}

@test "FAILING FIXTURE: the reference time of the backup is the start time of the Velero pod, never the runner clock (hosted#68 review)" {
  export STUB_POD_START=2031-01-02T03:04:05Z
  refusal_step
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"reference=2031-01-02T03:04:05Z"* ]] || { echo "$output"; false; }
  [[ "$output" == *"final=2031-01-02T03:04:05Z"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a PartiallyFailed backup whose errors do not name the password proves no refusal (hosted#153 review)" {
  export STUB_POD_START=2031-01-02T03:04:05Z STUB_NOT_NAMED=1
  refusal_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"miss: the backup with another repository password ended PartiallyFailed, but no error names the repository password"* ]] || { echo "$output"; false; }
  [[ "$output" != *"ok: a backup with another repository password"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: the ok line of a refusal holds the words of Velero, and both passwords go to the filter (coordinator, hosted#154)" {
  mkdir -p "$TMP/work"
  printf 'VELERO_REPO_PASSWORD=s3cr3t-random\n' > "$TMP/work/velero.env"
  printf 'VELERO_REPO_PASSWORD=k3yring-pw\n' > "$TMP/keyring.env"
  : > "$TMP/redact"
  export STUB_POD_START=2031-01-02T03:04:05Z STUB_WORK="$TMP/work" KEYRING_FILE="$TMP/keyring.env" VELERO_REDACT_FILE="$TMP/redact"
  export STUB_EVIDENCE='PodVolumeBackup p1: error to open repo: invalid repository password'
  refusal_step
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ok: a backup with another repository password does not complete (PartiallyFailed), and Velero names the password: PodVolumeBackup p1: error to open repo: invalid repository password"* ]] || { echo "$output"; false; }
  [ "$(cat "$TMP/redact")" = "$(printf 's3cr3t-random\nk3yring-pw')" ] || { cat "$TMP/redact"; false; }
}

@test "FAILING FIXTURE: a Velero pod read that gives nothing is a miss, and the time check is never skipped (hosted#68 review)" {
  export STUB_POD_NONE=1
  refusal_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"miss: the start time of the Velero pod could not be read"* ]] || { echo "$output"; false; }
  [[ "$output" != *"reference="* ]]
  # Velero ran on the random password. The miss puts the keyring password back
  # (k2c with no argument) and restarts Velero after it.
  [ "$(tr '\n' ' ' < "$TMP/calls")" = "k2c /nonexistent/velero.env restart k2c <keyring> restart " ] || { cat "$TMP/calls"; false; }
}

@test "FAILING FIXTURE: a storage location check with no reference time is not ready (hosted#68 review)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=Completed STUB_RESTARTED_AT=
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = "timeout:storage-location" ] || { echo "$output"; false; }
  [ ! -e "$TMP/applied" ]
}

@test "FAILING FIXTURE: a pod that started after the last validation of the location is not ready (hosted#68 review)" {
  velero_helpers
  # The location kept Available from the old server. The new pod started at
  # 13:00:05, and the last validation is older.
  export STUB_BUSY=0 STUB_PHASE=Completed STUB_RESTARTED_AT=2026-10-20T13:00:05Z STUB_BSL_VALIDATED=2026-10-20T12:30:00Z
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = "timeout:storage-location" ] || { echo "$output"; false; }
  [ ! -e "$TMP/applied" ]
}

@test "FAILING FIXTURE: a get that fails with connection refused is not a backup that is gone (hosted#68 review)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE_EMPTY=1 STUB_GET_ERROR=1
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = "timeout:stale-backup" ] || { echo "$output"; false; }
  [ "$(wc -l < "$TMP/applies")" -eq 1 ]
}

@test "FAILING FIXTURE: a storage location validated before the restart is not ready, and no backup is made (hosted#68 review)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=Completed STUB_RESTARTED_AT=2026-10-20T13:00:00Z STUB_BSL_VALIDATED=2026-10-20T12:59:00Z
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = "timeout:storage-location" ] || { echo "$output"; false; }
  [ ! -e "$TMP/applied" ]
}

@test "a storage location validated after the restart is ready (hosted#68 review)" {
  velero_helpers
  export STUB_BUSY=0 STUB_PHASE=Completed STUB_RESTARTED_AT=2026-10-20T13:00:00Z STUB_BSL_VALIDATED=2026-10-20T13:00:30Z
  run_velero 3600
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s' "$output" | tail -n1)" = Completed ]
}

# password_refused runs from the script text, with miss as the script has it.
run_refused() {
  python3 - "$TEST" "$TMP/refused.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^password_refused\(\) \{.*?^\}\n", text, re.M | re.S)
if not m:
    sys.exit("no function password_refused in the script")
open(sys.argv[2], "w").write(m.group(0))
PY
  run bash -c 'miss() { echo "miss: $*"; return 1; }; . "$1"; password_refused "$2"' _ "$TMP/refused.sh" "$1"
}

@test "an end phase of Failed or PartiallyFailed is the refusal of another password" {
  run_refused PartiallyFailed; [ "$status" -eq 0 ] || { echo "$output"; false; }
  run_refused Failed; [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a timeout, a queue, a validation failure or a Completed backup is no refusal" {
  for p in "timeout:InProgress" "timeout:queue (x)" "timeout:Queued" "timeout:unreconciled" "timeout:storage-location" "timeout:stale-backup" FailedValidation Completed ""; do
    run_refused "$p"
    [ "$status" -ne 0 ] || { echo "phase '$p' read as a refusal: $output"; false; }
    [[ "$output" == miss:* ]] || { echo "$output"; false; }
  done
}

# --- setec-disk-signing-seed (hosted#444, owner decision option a) ---------
disk_seed_helpers() {
  python3 - "$TEST" "$TMP/disk.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
out = []
for name in ("disk_key_id", "with_disk_seeds", "disk_job_name"):
    m = re.search(r"^%s\(\) \{.*?^\}\n|^%s\(\) \{[^\n]*\}\n" % (name, name), text, re.M | re.S)
    if not m:
        sys.exit("no function %s in the script" % name)
    out.append(m.group(0))
open(sys.argv[2], "w").write("\n".join(out))
PY
}

@test "disk_key_id is the first 16 hex of the SHA-256 of the raw public key, as setec names it" {
  disk_seed_helpers
  pub="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
  # The key id of the RFC 8032 test key, as setec diskbuilder.KeyID gives it.
  want="21fe31dfa154a261"
  run bash -c ". '$TMP/disk.sh'; disk_key_id '$pub'"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
  [ "${#output}" -eq 16 ]
}

@test "with_disk_seeds swaps the two disk seeds and keeps every other member" {
  disk_seed_helpers
  printf 'A=1\nSETEC_DISK_SIGNING_SEED=cur\nB=2\nSETEC_DISK_SIGNING_SEED_PREVIOUS=prev\n' > "$TMP/k.env"
  run bash -c ". '$TMP/disk.sh'; with_disk_seeds '$TMP/k.env' '$TMP/out.env' prev cur"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^SETEC_DISK_SIGNING_SEED=prev$' "$TMP/out.env")" = 1 ]
  [ "$(grep -c '^SETEC_DISK_SIGNING_SEED_PREVIOUS=cur$' "$TMP/out.env")" = 1 ]
  grep -qx 'A=1' "$TMP/out.env"; grep -qx 'B=2' "$TMP/out.env"
  [ "$(stat -c %a "$TMP/out.env")" = 600 ]
}

@test "disk_job_name names the disk Job as the setec operator does" {
  disk_seed_helpers
  run bash -c ". '$TMP/disk.sh'; disk_job_name ghcr.io/zeroroot-ai/mirror/alpine@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d 0123456789abcdef"
  [ "$status" -eq 0 ]
  [ "$output" = "setec-disk-48b0309ca019d89d40f6-0123456789abcdef" ]
}

@test "FAILING FIXTURE: an image with no digest has no disk Job name" {
  disk_seed_helpers
  run bash -c ". '$TMP/disk.sh'; disk_job_name ghcr.io/zeroroot-ai/mirror/alpine:3.21 0123456789abcdef"
  [ "$status" -ne 0 ]
}

# The class itself, with stubs: kubectl answers the Sandbox and the disk Job,
# k2c records each write of the keyring, and the operator Secret follows the
# last write at once. STUB_JOB=succeeded|absent.
disk_class_run() {
  python3 - "$TEST" "$TMP/class.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
out = [re.search(r'^SETEC_NS=.*\n(?:.*\n)*?^DISK_PROBE_IMAGE=.*\n', text, re.M).group(0)]
for name in ("disk_key_id", "with_disk_seeds", "disk_job_name", "probe_sandbox", "class_setec_disk_signing_seed"):
    m = re.search(r"^%s\(\) \{.*?^\}\n|^%s\(\) \{[^\n]*\}\n" % (name, name), text, re.M | re.S)
    if not m:
        sys.exit("no function %s in the script" % name)
    out.append(m.group(0))
open(sys.argv[2], "w").write("\n".join(out))
PY
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "apply -f -") cat > "$STUB_DIR/sandbox.yaml" ;;
  "-n setec-sandboxes get sandbox rotation-disk-seed-"*" -o jsonpath={.status.phase}/{.status.reason}") printf 'Running/' ;;
  "-n setec-sandboxes delete sandbox rotation-disk-seed-"*" --wait=false") echo deleted >> "$STUB_DIR/deleted" ;;
  "-n setec-system get job setec-disk-"*" -o jsonpath={.status.succeeded}") [ "$STUB_JOB" = succeeded ] && printf 1 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
  cur="$(head -c 32 /dev/urandom | base64 -w0)"; prev="$(head -c 32 /dev/urandom | base64 -w0)"
  printf 'SETEC_DISK_SIGNING_SEED=%s\nSETEC_DISK_SIGNING_SEED_PREVIOUS=%s\n' "$cur" "$prev" > "$TMP/keyring.env"
  echo "SETEC_DISK_REPO=447184491447.dkr.ecr.us-east-1.amazonaws.com/zeroroot-ai-drill-setec-disks" > "$TMP/substrate.env"
  cd "$REPO_ROOT"
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" run bash -c '
    KEYRING_FILE="$1" SUBSTRATE_ENV_FILE="$2" D="$3"
    ok() { echo "ok: $*"; }
    miss() { echo "miss: $*"; return 1; }
    mask() { :; }
    sleep() { :; }
    # k2c writes the keyring it gets, or the real one. The operator Secret
    # holds the seed of the last write.
    k2c() { local f="${1:-$KEYRING_FILE}"; echo "k2c $(basename "$f")" >> "$D/k2c.log"; sed -n "s/^SETEC_DISK_SIGNING_SEED=//p" "$f" > "$D/secret"; }
    signing_seed_is() { [ "$(cat "$D/secret" 2>/dev/null)" = "$1" ]; }
    wait_signing_seed() { signing_seed_is "$1"; }
    sed -n "s/^SETEC_DISK_SIGNING_SEED=//p" "$KEYRING_FILE" > "$D/secret"
    . "$4"
    class_setec_disk_signing_seed' _ "$TMP/keyring.env" "$TMP/substrate.env" "$TMP" "$TMP/class.sh"
}

@test "the disk seed class switches to the second seed, proves the disk Job and the Sandbox, and switches back" {
  export STUB_JOB=succeeded
  disk_class_run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$TMP/k2c.log" | tr '\n' ' ')" = "k2c switched.env k2c keyring.env " ] || { cat "$TMP/k2c.log"; false; }
  [ "$(cat "$TMP/secret")" = "$(sed -n 's/^SETEC_DISK_SIGNING_SEED=//p' "$TMP/keyring.env")" ]
  grep -q 'image: ghcr.io/zeroroot-ai/mirror/alpine@sha256:' "$TMP/sandbox.yaml"
  [ -s "$TMP/deleted" ]
}

@test "FAILING FIXTURE: with no disk Job of the second key the class fails, and the seed switches back" {
  export STUB_JOB=absent
  disk_class_run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no succeeded disk Job setec-disk-"* ]] || { echo "$output"; false; }
  [ "$(cat "$TMP/k2c.log" | tr '\n' ' ')" = "k2c switched.env k2c keyring.env " ] || { cat "$TMP/k2c.log"; false; }
  [ "$(cat "$TMP/secret")" = "$(sed -n 's/^SETEC_DISK_SIGNING_SEED=//p' "$TMP/keyring.env")" ]
  [ -s "$TMP/deleted" ]
}

# --- diagnose_failed_class (drill run 39125128505) ---------------------------
diag_setup() {
  python3 - "$TEST" "$TMP/diag.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^diagnose_failed_class\(\) \(.*?^\)\n", text, re.M | re.S)
if not m:
    sys.exit("no function diagnose_failed_class in the script")
open(sys.argv[2], "w").write(m.group(0))
PY
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
[ -z "${STUB_ALL_FAIL:-}" ] || { echo "error: the server is currently unable to handle the request" >&2; exit 1; }
case "$*" in
  "-n gibson get pods --no-headers -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.conditions[?(@.type==\"Ready\")].status,RESTARTS:.status.containerStatuses[*].restartCount,START:.status.startTime")
    printf 'gibson-gibson-workloads-0 Pending False 3 2026-10-18T12:40:00Z\ngibson-envoy-1 Running True 0 2026-10-18T12:00:00Z\n' ;;
  "-n gibson get events --field-selector involvedObject.name=gibson-gibson-workloads-0 --sort-by=.lastTimestamp")
    echo "Warning BackOff Back-off restarting failed container wait-for-redis" ;;
  "-n gibson logs gibson-gibson-workloads-0 --all-containers --tail=15") echo '{"msg":"redis auth failed"}' ;;
  "-n gibson get jobs --sort-by=.metadata.creationTimestamp -o name")
    printf 'job.batch/gibson-redis-rotation-29872250\njob.batch/other-job\n' ;;
  "-n gibson logs job.batch/gibson-redis-rotation-29872250 --all-containers --tail=20")
    echo "[rotation] restarting statefulset/gibson-gibson-workloads..." ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
}

@test "diagnose_failed_class names the pods that are not Ready, Pending ones too, their events and logs, and the rotation Job logs" {
  diag_setup
  run env PATH="$TMP/bin:$PATH" bash -c 'set -euo pipefail; NS=gibson RELEASE=gibson; . "$1"; diagnose_failed_class redis-password; echo after' _ "$TMP/diag.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"gibson-gibson-workloads-0 Pending False 3"* ]] || { echo "$output"; false; }
  [[ "$output" != *"gibson-envoy-1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"Back-off restarting failed container wait-for-redis"* ]] || { echo "$output"; false; }
  [[ "$output" == *"redis auth failed"* ]] || { echo "$output"; false; }
  [[ "$output" == *"log of job.batch/gibson-redis-rotation-29872250"* ]] || { echo "$output"; false; }
  [[ "$output" != *"other-job"* ]] || { echo "$output"; false; }
  [ "${lines[-1]}" = after ]
}

@test "FAILING FIXTURE: a diagnostics run where every kubectl read fails does not stop a script under set -euo pipefail" {
  diag_setup
  run env PATH="$TMP/bin:$PATH" STUB_ALL_FAIL=1 bash -c 'set -euo pipefail; NS=gibson RELEASE=gibson; . "$1"; diagnose_failed_class redis-password; echo after' _ "$TMP/diag.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[-1]}" = after ]
}

@test "FAILING FIXTURE: a failed class runs diagnose_failed_class, after its row, under a time limit" {
  # The row of the failed class comes right before the diagnosis.
  grep -B3 '^    run_diagnosis "\$name"$' "$TEST" | grep -q "printf '%s\\\\tfail\\\\t%s\\\\n' \"\$name\""
  # The diagnosis runs in a child under timeout.
  grep -A3 '^run_diagnosis() {' "$TEST" | grep -q 'ROTATION_ONE_CLASS=diagnose_failed_class'
  grep -A6 '^run_diagnosis() {' "$TEST" | grep -q 'timeout --kill-after="\$CLASS_KILL_AFTER_S" "\$DIAG_TIMEOUT_S"'
}

# --- velero_failed_volumes names the cause (drill rotation run 40429097454) ---
# The backup of the keyring class ended PartiallyFailed with errors=44 and no
# failed PodVolumeBackup. The count names no cause. The helper now prints the
# phase of each BackupRepository and the errors from the log of the backup.
failed_volumes_helpers() {
  python3 - "$TEST" "$TMP/fv.sh" "$REPO_ROOT/scripts/lib/velero-backup-log.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^velero_failed_volumes\(\) \{.*?^\}\n", text, re.M | re.S)
if not m:
    sys.exit("no function velero_failed_volumes in the script")
if 'scripts/lib/velero-backup-log.sh"' not in text:
    sys.exit("the script does not source scripts/lib/velero-backup-log.sh")
open(sys.argv[2], "w").write('. "%s"\n' % sys.argv[3] + m.group(0))
PY
  mkdir -p "$TMP/bin"
  python3 -c 'import gzip,sys; gzip.open(sys.argv[1],"wt").write(
    "time=\"t\" level=info msg=\"Backing up item\" backup=velero/b1\n"
    "time=\"t\" level=error msg=\"Error backing up item\" backup=velero/b1 error=\"repository not ready\" logSource=\"x.go:1\"\n"
    "time=\"t\" level=error msg=\"Error backing up item\" backup=velero/b1 error=\"repository not ready\" logSource=\"x.go:2\"\n")' "$TMP/log.gz"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n velero get podvolumebackups.velero.io -l velero.io/backup-name=b1 -o json") echo '{"items":[]}' ;;
  "-n velero get backups.velero.io b1 -o jsonpath="*) printf '      errors=2 warnings=\n' ;;
  "-n velero get backuprepositories.velero.io -o json")
    echo '{"items":[{"metadata":{"name":"gibson-default-kopia"},"spec":{"repositoryType":"kopia"},"status":{"phase":"NotReady","message":"invalid repository password"}}]}' ;;
  "apply -f -") cat > "$STUB_DIR/applied" ;;
  "-n velero get downloadrequest.velero.io/velero-explain-b1 -o jsonpath={.status.downloadURL}") printf 'http://bucket.invalid/signed' ;;
  "-n velero delete downloadrequest.velero.io/velero-explain-b1 --ignore-not-found") : ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
cp "$STUB_DIR/log.gz" "${@: -1}"
SH
  chmod +x "$TMP/bin/kubectl" "$TMP/bin/curl"
}

@test "FAILING FIXTURE: velero_failed_volumes names the BackupRepository phase and the grouped errors of the backup log" {
  failed_volumes_helpers
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" run bash -c 'set -euo pipefail; . "$1"; velero_failed_volumes b1' _ "$TMP/fv.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"gibson-default-kopia kopia NotReady invalid repository password"* ]] || { echo "$output"; false; }
  [[ "$output" == *"1 distinct errors in the backup log"* ]] || { echo "$output"; false; }
  [[ "$output" == *'2 msg="Error backing up item" error="repository not ready"'* ]] || { echo "$output"; false; }
  [[ "$output" != *"Backing up item"* ]] || { echo "$output"; false; }
  grep -q 'kind: BackupLog' "$TMP/applied"
}

# --- password_named: the refusal names the password (hosted#153 review) -----
# Drill rotation run 40438631534: the backup with another password ended
# PartiallyFailed on 44 refused lists, and that counted as a refusal.
password_named_helpers() {
  python3 - "$TEST" "$TMP/pn.sh" "$REPO_ROOT/scripts/lib/velero-backup-log.sh" <<'PY2'
import re, sys
text = open(sys.argv[1]).read()
out = ['. "%s"' % sys.argv[3]]
for const in ("VELERO_PASSWORD_ERROR",):
    m = re.search(r'^%s=.*\n' % const, text, re.M)
    if not m:
        sys.exit("no %s in the script" % const)
    out.append(m.group(0))
m = re.search(r"^password_named\(\) \{.*?^\}\n", text, re.M | re.S)
if not m:
    sys.exit("no function password_named in the script")
out.append(m.group(0))
open(sys.argv[2], "w").write("\n".join(out))
PY2
  mkdir -p "$TMP/bin"
  # STUB_PVB_MSG: the message of the one PodVolumeBackup. STUB_LOG: the lines of the backup log.
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n velero get podvolumebackups.velero.io -l velero.io/backup-name=b1 -o json")
    jq -n --arg m "${STUB_PVB_MSG:-}" '{items: [{metadata: {name: "b1-pvb"}, status: {phase: "Failed", message: $m}} | select(.status.message != "")]}' ;;
  # STUB_REPO_MSG: the message of the one BackupRepository.
  "-n velero get backuprepositories.velero.io -o json")
    jq -n --arg m "${STUB_REPO_MSG:-}" '{items: [{metadata: {name: "gibson-default-kopia"}, status: {phase: "Ready", message: $m}} | select(.status.message != "")]}' ;;
  "apply -f -") cat > /dev/null ;;
  "-n velero get downloadrequest.velero.io/velero-explain-b1 -o jsonpath={.status.downloadURL}") printf 'http://bucket.invalid/signed' ;;
  "-n velero delete downloadrequest.velero.io/velero-explain-b1 --ignore-not-found") echo x >> "$STUB_DIR/deletes" ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%b' "${STUB_LOG:-}" | gzip > "${@: -1}"
SH
  chmod +x "$TMP/bin/kubectl" "$TMP/bin/curl"
}

run_named() {
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" run bash -c 'set -euo pipefail; . "$1"; if e="$(password_named b1)"; then echo "NAMED: $e"; else echo NOT-NAMED; fi' _ "$TMP/pn.sh"
}

@test "password_named: a PodVolumeBackup message with the kopia password error names the password" {
  password_named_helpers
  export STUB_PVB_MSG='error to initialize data path: error to connect to backup repo: invalid repository password'
  run_named
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "NAMED: PodVolumeBackup b1-pvb: error to initialize data path: error to connect to backup repo: invalid repository password" ] || { echo "$output"; false; }
}

@test "password_named: an error line of the backup log with the password error names the password" {
  password_named_helpers
  export STUB_LOG='time="t" level=info msg="Backing up item"\ntime="t" level=error msg="pod volume backup failed" error="Invalid Repository Password"\n'
  run_named
  [ "$(printf '%s\n' "$output" | tail -n 1)" = 'NAMED: backup log: level=error msg="pod volume backup failed" error="Invalid Repository Password"' ] || { echo "$output"; false; }
  [ "$(wc -l < "$TMP/deletes")" -eq 1 ]
}

@test "password_named: a BackupRepository message with the password error names the password (hosted#154 review)" {
  password_named_helpers
  export STUB_PVB_MSG='' STUB_REPO_MSG='error to connect to backup repo: error to open repo: invalid repository password'
  export STUB_LOG='time="t" level=error msg="backup repository is not ready"\n'
  run_named
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "NAMED: BackupRepository gibson-default-kopia: error to connect to backup repo: error to open repo: invalid repository password" ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: password_named: refused lists alone do not name the password, and the errors are printed" {
  password_named_helpers
  export STUB_PVB_MSG=''
  export STUB_LOG='time="t" level=error msg="Error listing resources" error="secrets is forbidden"\ntime="t" level=info msg="invalid repository password"\n'
  run_named
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(printf '%s\n' "$output" | tail -n 1)" = NOT-NAMED ] || { echo "$output"; false; }
  [[ "$output" == *'backup log: level=error msg="Error listing resources" error="secrets is forbidden"'* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: password_named: a log that cannot be read does not name the password" {
  password_named_helpers
  sed -i 's|printf .http://bucket.invalid/signed. ;;|printf "" ;;|' "$TMP/bin/kubectl"
  export STUB_PVB_MSG='' VELERO_LOG_WAIT=0
  run_named
  [ "$(printf '%s\n' "$output" | tail -n 1)" = NOT-NAMED ] || { echo "$output"; false; }
}

# --- run_one_class: one filter for all output of a class (coordinator, hosted#154)
one_class_helpers() {
  python3 - "$TEST" "$TMP/one.sh" "$REPO_ROOT/scripts/lib/velero-backup-log.sh" <<'PY2'
import re, sys
text = open(sys.argv[1]).read()
out = ['. "%s"' % sys.argv[3]]
for name in ("redact_add", "redact_stream", "run_one_class"):
    m = re.search(r"^%s\(\) \{.*?^\}\n" % name, text, re.M | re.S)
    if not m:
        sys.exit("no function %s in the script" % name)
    out.append(m.group(0))
if 'run_one_class "$ROTATION_ONE_CLASS"' not in text:
    sys.exit("the class child does not run through run_one_class")
open(sys.argv[2], "w").write("\n".join(out))
PY2
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "apply -f -") cat > /dev/null ;;
  "-n velero get downloadrequest.velero.io/velero-explain-b1 -o jsonpath={.status.downloadURL}") printf 'http://bucket.invalid/signed' ;;
  "-n velero delete downloadrequest.velero.io/velero-explain-b1 --ignore-not-found") : ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'time="t" level=error msg="error to open repo" error="s3://bucket/kopia?pw=r4nd-pw-7: invalid repository password"\n' | gzip > "${@: -1}"
SH
  chmod +x "$TMP/bin/kubectl" "$TMP/bin/curl"
  printf 'VELERO_REPO_PASSWORD=k3yring-pw\n' > "$TMP/keyring.env"
}

@test "FAILING FIXTURE: a backup-log error that holds the password prints [redacted] in the explain_bad_backup output of a class" {
  one_class_helpers
  PATH="$TMP/bin:$PATH" KEYRING_FILE="$TMP/keyring.env" ROTATION_REASON_FILE="$TMP/reason" run bash -c '
    . "$1"
    fake_class() {
      redact_add r4nd-pw-7
      echo "ok: the keyring password k3yring-pw and the random one r4nd-pw-7"
      explain_bad_backup b1
      REASON="the class saw r4nd-pw-7"
      return 1
    }
    run_one_class fake_class; echo "rc=$?"' _ "$TMP/one.sh"
  [[ "$output" == *"rc=1"* ]] || { echo "$output"; false; }
  [[ "$output" == *'1 msg="error to open repo" error="s3://bucket/kopia?pw=[redacted]: invalid repository password"'* ]] || { echo "$output"; false; }
  [[ "$output" == *"ok: the keyring password [redacted] and the random one [redacted]"* ]] || { echo "$output"; false; }
  [[ "$output" != *"r4nd-pw-7"* ]] || { echo "$output"; false; }
  [[ "$output" != *"k3yring-pw"* ]] || { echo "$output"; false; }
  [ "$(cat "$TMP/reason")" = "the class saw [redacted]" ] || { cat "$TMP/reason"; false; }
}

# redact_stream alone, from the script text (coordinator, hosted#154).
redact_only() {
  python3 - "$TEST" "$TMP/rs.sh" <<'PY2'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^redact_stream\(\) \{.*?^\}\n", text, re.M | re.S)
if not m:
    sys.exit("no function redact_stream in the script")
open(sys.argv[2], "w").write(m.group(0))
PY2
}

@test "FAILING FIXTURE: redact_stream skips an empty value and a value of one or two characters" {
  redact_only
  printf '\na\nab\nabc\n' > "$TMP/values"
  run bash -c '. "$1"; printf "a cab dabc ab\n" | VELERO_REDACT_FILE="$2" redact_stream' _ "$TMP/rs.sh" "$TMP/values"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "a cab d[redacted] ab" ] || { echo "$output"; false; }
}

@test "redact_stream matches a password with & \\ . * [ ( as plain text" {
  redact_only
  pw='p&w\1.*[x(y'
  printf '%s\n' "$pw" > "$TMP/values"
  line="key=${pw} and pAw\\1zz[x(y and p&w\\1.*[x(y."
  run bash -c '. "$1"; printf "%s\n" "$3" | VELERO_REDACT_FILE="$2" redact_stream' _ "$TMP/rs.sh" "$TMP/values" "$line"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = 'key=[redacted] and pAw\1zz[x(y and [redacted].' ] || { echo "$output"; false; }
}

# --- mask: never on stdout (drill rotation run 40456829215) -----------------
@test "FAILING FIXTURE: admin_pat_status under GITHUB_ACTIONS prints the HTTP code alone, and mask goes to stderr" {
  python3 - "$TEST" "$TMP/mask.sh" <<'PY2'
import re, sys
text = open(sys.argv[1]).read()
out = []
for name in ("mask", "admin_pat_status"):
    # A one-line function first: the multi-line form would run on to the
    # next closing brace.
    m = re.search(r"^%s\(\) \{.*\}\n" % name, text, re.M) or re.search(r"^%s\(\) \{.*?^\}\n" % name, text, re.M | re.S)
    if not m:
        sys.exit("no function %s in the script" % name)
    out.append(m.group(0))
open(sys.argv[2], "w").write("\n".join(out))
PY2
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "get platformbootstrap -o json") echo '{"items":[{"spec":{"zitadel":{"adminTokenRef":{"name":"pat","key":"token"}}}}]}' ;;
  "-n gibson get secret pat -o json") printf '{"data":{"token":"%s"}}' "$(printf 'the-pat' | base64)" ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
  PATH="$TMP/bin:$PATH" GITHUB_ACTIONS=true run bash -c '
    NS=gibson; . "$1"
    zitadel_admin_status() { printf 200; }
    code="$(admin_pat_status 2>"$2")"
    printf "code=[%s]\n" "$code"' _ "$TMP/mask.sh" "$TMP/stderr"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "code=[200]" ] || { echo "$output"; false; }
  grep -qx '::add-mask::the-pat' "$TMP/stderr" || { cat "$TMP/stderr"; false; }
}
