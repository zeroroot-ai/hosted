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
for name in ("velero_in_flight", "velero_backup"):
    m = re.search(r"^%s\(\) \{.*?^\}\n" % name, text, re.M | re.S)
    if not m:
        sys.exit("no function %s in the script" % name)
    out.append(m.group(0))
m = re.search(r'^VELERO_IN_FLIGHT_PHASES=.*\n', text, re.M)
out.insert(0, m.group(0))
open(sys.argv[2], "w").write("\n".join(out))
PY
  mkdir -p "$TMP/bin"
  : > "$TMP/reads"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-n velero get backups -o json")
    echo x >> "$STUB_DIR/reads"
    if [ "$(wc -l < "$STUB_DIR/reads")" -le "${STUB_BUSY:-0}" ]; then p=InProgress; else p=Completed; fi
    printf '{"items":[{"metadata":{"name":"platform-hourly-1"},"status":{"phase":"%s"}}]}' "$p" ;;
  "apply -f -") cat > "$STUB_DIR/applied" ;;
  # A bound, so a loop that never ends fails the test instead of hanging it.
  "-n velero get backup rotation-drill-"*" -o jsonpath={.status.phase}")
    echo x >> "$STUB_DIR/phase-reads"
    if [ "$(wc -l < "$STUB_DIR/phase-reads")" -gt 50 ]; then printf 'Completed'; else printf '%s' "$STUB_PHASE"; fi ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
}

run_velero() {
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" run bash -c '
    NS=gibson VELERO_QUEUE_WAIT="$2" VELERO_RUN_WAIT="${3:-900}"
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
  grep -q 'app.kubernetes.io/component: openbao' "$TMP/applied"
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
  sed -i 's|^  "-n velero get backups -o json")$|  "-n velero get backups -o json") [ -z "${STUB_LIST_BROKEN:-}" ] \|\| exit 1|' "$TMP/bin/kubectl"
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
  for p in "timeout:InProgress" "timeout:queue (x)" "timeout:Queued" FailedValidation Completed ""; do
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
