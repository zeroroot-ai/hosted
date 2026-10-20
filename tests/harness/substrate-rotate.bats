#!/usr/bin/env bats
# substrate-rotate.bats — the access key rotation of a substrate IAM user
# (ADR-0171, row substrate-cloud-credentials), offline.
#
# terraform, aws and kubectl are stubs on PATH. The terraform stub keeps the
# keys of the slots in a file and plans from the slot file the script writes.
# The keyring is the real scripts/keyring.sh.

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  D="$BATS_TEST_TMPDIR"; export D
  STATE="$D/state"; export STATE; mkdir -p "$STATE" "$D/bin" "$D/used"
  echo '{"key_slots": {"platform": {"active": "a", "keep": ["a"]}, "smtp": {"active": "a", "keep": ["a"]}, "dns": {"active": "a", "keep": ["a"]}, "setec-disk-builder": {"active": "a", "keep": ["a"]}}}' > "$STATE/key-slots.tfvars.json"
  echo '{"a": "AKIAAAAAAAAAAAAAAAAA"}' > "$D/keys.json"
  head -c 30 /dev/urandom | base64 -w0 > "$D/secret.a"
  printf 'BUCKET_ACCESS_KEY=AKIAAAAAAAAAAAAAAAAA\nBUCKET_SECRET_KEY=%s\nSMTP_PASSWORD=smtp-password-of-the-bats-suite\n' "$(cat "$D/secret.a")" > "$D/provided"
  "$REPO/scripts/keyring.sh" generate "$STATE/keyring.env" "$D/provided" >/dev/null
  printf 'KEYRING_FILE=%s\n' "$STATE/keyring.env" > "$STATE/substrate.env"

  # terraform: slots come from the -var-file key-slots.tfvars.json.
  cat > "$D/bin/terraform" <<'SH'
#!/usr/bin/env bash
shift  # -chdir=...
cmd="$1"; shift
U="${U:-platform}"
slots="$(jq -c --arg u "$U" '.key_slots[$u]' "$STATE/key-slots.tfvars.json")"
active="$(jq -r .active <<<"$slots")"
# STUB_TF_REQUIRE_INIT: a command other than init fails until init ran, as
# terraform does on a fresh runner (drill rotation run 1).
# STUB_TF_OUTPUT_FAIL: terraform output fails.
if [ -n "${STUB_TF_REQUIRE_INIT:-}" ] && [ "$cmd" != init ] && [ ! -e "$D/tf.inited" ]; then
  echo "Error: Backend initialization required, please run \"terraform init\"" >&2; exit 1
fi
[ "$cmd" != output ] || [ -z "${STUB_TF_OUTPUT_FAIL:-}" ] || { echo "Error: Failed to load state" >&2; exit 1; }
case "$cmd" in
  init) : > "$D/tf.inited"; exit 0 ;;
  plan) for a in "$@"; do case "$a" in -out=*) out="${a#-out=}" ;; esac; done
        jq -n --argjson s "$slots" --slurpfile k "$D/keys.json" '
          [($k[0] | keys[]) as $have | select(($s.keep | index($have)) == null)
            | {address: "aws_iam_access_key.\(if (env.TFRES // "") != "" then env.TFRES else (env.U // "platform") end)[\"\($have)\"]", change: {actions: ["delete"]}}]
          + (if env.EXTRA_DELETE then [{address: env.EXTRA_DELETE, change: {actions: ["delete"]}}] else [] end)
          | {resource_changes: .}' > "$out" ;;
  show) cat "${@: -1}" ;;
  apply) # Create a key for each new slot, delete each dropped slot.
         for s in $(jq -r '.keep[]' <<<"$slots"); do
           if [ "$(jq -r --arg s "$s" '.[$s] // empty' "$D/keys.json")" = "" ]; then
             id="AKIA$(echo "$s" | tr a-z A-Z)BBBBBBBBBBBBBBB"
             jq --arg s "$s" --arg i "$id" '.[$s] = $i' "$D/keys.json" > "$D/k.tmp" && mv "$D/k.tmp" "$D/keys.json"
             head -c 30 /dev/urandom | base64 -w0 > "$D/secret.$s"
           fi
         done
         jq --argjson s "$slots" 'with_entries(select(.key as $k | $s.keep | index($k)))' "$D/keys.json" > "$D/k.tmp" && mv "$D/k.tmp" "$D/keys.json"
         echo "apply" >> "$D/log"
         [ -z "${APPLY_FAIL:-}" ] || { echo "terraform stub: apply failed after it made the key" >&2; exit 1; } ;;
  output) if [ "$1" = -json ]; then jq --arg u "$U" '{platform: {}, smtp: {}, dns: {}, "setec-disk-builder": {}} + {($u): .}' "$D/keys.json"; exit 0; fi
          case "$2" in
            platform_access_key_id|smtp_user|setec_disk_builder_access_key_id) jq -j --arg a "$active" '.[$a]' "$D/keys.json" ;;
            platform_secret_access_key|smtp_password|setec_disk_builder_secret_access_key) cat "$D/secret.$active" ;;
          esac ;;
esac
SH
  # aws: the last use of a key is the epoch in $D/used/<id>, or none.
  # For drill, the stage 0 files live in AWS (scripts/stage0-store.sh): the
  # state bucket is $D/s3 and the keyring secret is $D/sm.json.
  cat > "$D/bin/aws" <<'SH'
#!/usr/bin/env bash
B=zeroroot-ai-prod-tfstate-447184491447-us-east-1
case "$*" in
  "sts get-caller-identity --query Account --output text") echo 447184491447; exit 0 ;;
  # Only the stage 0 prefix of drill and its keyring secret are declared.
  "s3api head-object --bucket $B --key substrate/drill/"*)
    k="${*: -1}"; [ -f "$D/s3/$(basename "$k")" ] && exit 0
    echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254 ;;
  "s3 cp --only-show-errors s3://$B/substrate/drill/"*)
    cp "$D/s3/$(basename "${@: -2:1}")" "${@: -1}"; exit 0 ;;
  "s3 cp --only-show-errors --sse aws:kms --sse-kms-key-id alias/zeroroot-ai-prod-tf-bootstrap "*" s3://$B/substrate/drill/"*)
    mkdir -p "$D/s3"; cp "${@: -2:1}" "$D/s3/$(basename "${@: -1}")"; exit 0 ;;
  "secretsmanager get-secret-value --secret-id zeroroot-ai/drill/keyring "*)
    [ -s "$D/sm.json" ] || { echo "An error occurred (ResourceNotFoundException): Secrets Manager can't find the specified secret value" >&2; exit 254; }
    cat "$D/sm.json"; exit 0 ;;
  "secretsmanager put-secret-value --secret-id zeroroot-ai/drill/keyring --secret-string file://"*)
    f="${*: -1}"; cp "${f#file://}" "$D/sm.json"; exit 0 ;;
  # Only an access key that the test made exists.
  "iam get-access-key-last-used --access-key-id "*)
    for a in "$@"; do case "$prev" in --access-key-id) id="$a" ;; esac; prev="$a"; done
    case "$id" in AKIA[A-Z]BBBBBBBBBBBBBBB|AKIAAAAAAAAAAAAAAAAA) ;; *) echo "aws stub: no access key ${id}" >&2; exit 254 ;; esac ;;
  *) echo "aws stub: undeclared call: $*" >&2; exit 1 ;;
esac
if [ -s "$D/used/$id" ]; then date -u -d "@$(cat "$D/used/$id")" +%Y-%m-%dT%H:%M:%SZ; else echo None; fi
SH
  # kubectl: one workload mounts velero-bucket-credential, one does not.
  cat > "$D/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  # A restart is a pod delete (scripts/lib/restart-pods.sh). Each workload
  # <kind>/<name> has one pod, <kind>--<name>-0, selected by the label
  # stub-workload=<kind>--<name>. Its pod UID is u<number of deletes>. A delete logs "restart <kind>/<name>". A DaemonSet has
  # the real shape: no .spec.replicas, and .status.desiredNumberScheduled.
  # NOT_READY=<kind>/<name>: its new pod never becomes Ready.
  # With OLD_USED_AT_RESTART, a reader on its old pod uses the old key while
  # it restarts, one second before it runs again (review of hosted#749).
  "-n "*" get deployment/"*" -o json"|"-n "*" get statefulset/"*" -o json"|"-n "*" get daemonset/"*" -o json")
    k="${4%%/*}"; w="${4/\//--}"
    if [ "$k" = daemonset ]; then
      printf '{"kind":"DaemonSet","spec":{"selector":{"matchLabels":{"stub-workload":"%s"}}},"status":{"desiredNumberScheduled":1}}' "$w"
    else
      # WANT0=<kind>/<name>: that workload wants 0 pods.
      rep=1; [ "$4" != "${WANT0:-}" ] || rep=0
      printf '{"kind":"x","spec":{"replicas":%s,"selector":{"matchLabels":{"stub-workload":"%s"}}}}' "$rep" "$w"
    fi ;;
  "-n "*" delete pod "*"-0 --ignore-not-found --wait=true --timeout="*)
    w="${5%-0}"; echo "restart ${w/--//}" >> "$D/log"; echo x >> "$D/deleted.$w"
    if [ -n "${OLD_USED_AT_RESTART:-}" ]; then date +%s > "$D/used/AKIAAAAAAAAAAAAAAAAA"; sleep 1; fi ;;
  "-n "*" get pods -l stub-workload="*" -o json")
    w="${6#stub-workload=}"; r=True; [ "${w/--//}" != "${NOT_READY:-}" ] || r=False
    u="u$(cat "$D/deleted.$w" 2>/dev/null | wc -l)"
    jq -n --arg r "$r" --arg n "${w}-0" --arg u "$u" \
      '{items: [{metadata: {name: $n, uid: $u}, status: {conditions: [{type: "Ready", status: $r}]}}]}' ;;
  # A copy of the relay Secret in another namespace (drill: the Alertmanager
  # configuration). COPY lists it, COPY_STALE keeps it from refreshing.
  # The list also holds an ExternalSecret in the namespace of the relay
  # Secret that names it: that one is no copy, and the stub answers no read
  # of it. COPY_DATAFROM reads the copy through spec.dataFrom.
  "get externalsecrets -A -o json")
    [ -z "${COPY_LIST_BROKEN:-}" ] || { echo "Unable to connect to the server" >&2; exit 1; }
    if [ -n "${COPY:-}" ]; then
      if [ -n "${COPY_DATAFROM:-}" ]; then spec='{"dataFrom": [{"extract": {"key": "gibson-email-smtp"}}]}'
      else spec='{"data": [{"remoteRef": {"key": "gibson-email-smtp", "property": "password"}}]}'; fi
      printf '{"items": [{"metadata": {"namespace": "monitoring", "name": "alertmanager-config"}, "spec": %s},
                       {"metadata": {"namespace": "gibson", "name": "gibson-email-smtp"}, "spec": {"data": [{"remoteRef": {"key": "ses-smtp-credentials"}}]}},
                       {"metadata": {"namespace": "gibson", "name": "same-namespace"}, "spec": {"data": [{"remoteRef": {"key": "gibson-email-smtp"}}]}}]}' "$spec"
    else echo '{"items": []}'; fi ;;
  "-n monitoring annotate externalsecret alertmanager-config "*)
    [ -n "${COPY_STALE:-}" ] || date -u +%Y-%m-%dT%H:%M:%SZ > "$D/copy.synced" ;;
  # COPY_NOT_READY: the copy refreshed and is not Ready. COPY_SLOW: the first
  # read is stale, and the second takes 3 s.
  "-n monitoring get externalsecret alertmanager-config -o json")
    n=$(( $(cat "$D/copy.reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/copy.reads"
    t="$(cat "$D/copy.synced" 2>/dev/null || echo 2000-01-01T00:00:00Z)"
    if [ -n "${COPY_SLOW:-}" ]; then
      if [ "$n" -eq 1 ]; then t=2000-01-01T00:00:00Z; else sleep 3; fi
    fi
    jq -n --arg t "$t" --arg r "$([ -n "${COPY_NOT_READY:-}" ] && echo False || echo True)" \
      '{status: {refreshTime: $t, conditions: [{type: "Ready", status: $r}]}}' ;;
  # ESO_AFTER=N: ESO writes the new value on the Nth refresh, and each
  # refresh takes ESO_SECS seconds.
  *"annotate externalsecret"*)
    sleep "${ESO_SECS:-0}"
    n=$(( $(cat "$D/eso.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$D/eso.calls"
    [ -n "${ESO_STALE:-}" ] || [ "$n" -lt "${ESO_AFTER:-1}" ] || cp "$D/relay.new" "$D/mail.secret" ;;
  *"annotate platformbootstrap"*)
    # The operator applies the Secret it reads: its hash stands for the value.
    # OPERATOR_LATE: it applies it only by the second read after the annotate.
    : > "$D/pb.reads"
    [ -n "${OPERATOR_STALE:-}" ] || [ -n "${OPERATOR_LATE:-}" ] || jq -r .password "$D/mail.secret" | sha256sum | cut -d' ' -f1 > "$D/pb.hash" ;;
  *"get platformbootstrap -o json"*) jq -n --arg h "$(cat "$D/pb.hash" 2>/dev/null)" '{items: [{metadata: {name: "gibson"},
      spec: {zitadel: {smtp: {host: "email-smtp.example.test", port: 587, fromAddress: "noreply@example.test", fromName: "Gibson",
        userSecretRef: {name: "gibson-email-smtp", key: "username"}, passwordSecretRef: {name: "gibson-email-smtp", key: "password"}}}},
      status: {smtpSettingsHash: $h, conditions: [{type: "SMTPProviderReady", status: "True"}]}}]}' ;;
  *"get platformbootstrap gibson -o json"*)
    echo x >> "$D/pb.reads"
    if [ -n "${OPERATOR_LATE:-}" ] && [ "$(wc -l < "$D/pb.reads")" -ge 2 ]; then
      jq -r .password "$D/mail.secret" | sha256sum | cut -d' ' -f1 > "$D/pb.hash"
    fi
    jq -n --arg h "$(cat "$D/pb.hash" 2>/dev/null)" \
      '{status: {smtpSettingsHash: $h, conditions: [{type: "SMTPProviderReady", status: "True"}]}}' ;;
  *"get secret gibson-email-smtp"*) jq '{data: {username: (.user | @base64), password: (.password | @base64)}}' "$D/mail.secret" ;;
  *"get deploy"*) cat <<'J'
{"items": [
 {"kind": "Deployment", "metadata": {"name": "velero"}, "spec": {"template": {"spec": {"containers": [{"name": "v"}],
   "volumes": [{"name": "c", "secret": {"secretName": "velero-bucket-credential"}}]}}}},
 {"kind": "DaemonSet", "metadata": {"name": "node-agent"}, "spec": {"template": {"spec": {"containers": [{"name": "n"}],
   "volumes": [{"name": "c", "secret": {"secretName": "velero-bucket-credential"}}]}}}},
 {"kind": "Deployment", "metadata": {"name": "disk-registry-reader"}, "spec": {"template": {"spec": {"containers": [{"name": "r",
   "env": [{"name": "K", "valueFrom": {"secretKeyRef": {"name": "setec-disk-push-credential", "key": "access-key-id"}}}]}]}}}},
 {"kind": "Deployment", "metadata": {"name": "unrelated"}, "spec": {"template": {"spec": {"containers": [{"name": "u"}]}}}},
 {"kind": "StatefulSet", "metadata": {"name": "otherkeys"}, "spec": {"template": {"spec": {"containers": [{"name": "o"}],
   "volumes": [{"name": "s", "secret": {"secretName": "bringup-keyring", "items": [{"key": "openbao-seal-key", "path": "k"}]}}]}}}},
 {"kind": "StatefulSet", "metadata": {"name": "gibson-openbao"}, "spec": {"template": {"spec": {"containers": [{"name": "b"}],
   "volumes": [{"name": "i", "secret": {"secretName": "bringup-keyring", "items": [{"key": "smtp-password", "path": "p"}, {"key": "bucket-access-key", "path": "a"}]}}]}}}},
 {"kind": "StatefulSet", "metadata": {"name": "gibson-daemon"}, "spec": {"template": {"spec": {"containers": [{"name": "d",
   "env": [{"name": "P", "valueFrom": {"secretKeyRef": {"name": "gibson-email-smtp", "key": "password"}}}]}]}}}},
 {"kind": "Deployment", "metadata": {"name": "envreader"}, "spec": {"template": {"spec": {"containers": [{"name": "e",
   "env": [{"name": "K", "valueFrom": {"secretKeyRef": {"name": "bringup-keyring", "key": "bucket-access-key"}}}]}]}}}}
]}
J
  ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  # openssl: the relay answers 235 to the AUTH PLAIN of the user and password
  # in $D/relay.accept, and 535 otherwise.
  cat > "$D/bin/openssl" <<'SH'
#!/usr/bin/env bash
while read -r line; do
  line="${line%$'\r'}"
  case "$line" in "AUTH PLAIN "*)
    [ "${line#AUTH PLAIN }" = "$(tr -d '\r' < "$D/relay.accept")" ] && echo "235 Authentication successful" || echo "535 Authentication Credentials Invalid" ;;
  esac
done
SH
  # The Secret of the relay credential that ESO writes, before the rotation,
  # and the status hash of the operator on it.
  jq -n '{user: "AKIAAAAAAAAAAAAAAAAA", password: "old"}' > "$D/mail.secret"
  printf 'old' | sha256sum | cut -d' ' -f1 > "$D/pb.hash"
  printf '#!/bin/sh\necho "$@" >> "%s/log"\n' "$D" > "$D/bin/k2c"
  printf '#!/bin/sh\nexit 0\n' > "$D/bin/substrate"
  chmod +x "$D/bin/"*
}

rotate() {
  run env PATH="$D/bin:$PATH" SUBSTRATE_SH="$D/bin/substrate" K2C="$D/bin/k2c" SLEEP_SECS=0 RESTART_TIMEOUT=2 RESTART_PODS_POLL=0 \
    STUB_TF_REQUIRE_INIT="${STUB_TF_REQUIRE_INIT:-}" STUB_TF_OUTPUT_FAIL="${STUB_TF_OUTPUT_FAIL:-}" WANT0="${WANT0:-}" WAIT_SECS="${WAIT_SECS:-0}" QUIET_SECS="${QUIET_SECS:-0}" U="${U:-platform}" TFRES="${TFRES:-}" APPLY_FAIL="${APPLY_FAIL:-}" \
    "$REPO/scripts/substrate-rotate.sh" "$STATE" "${E:-staging}" "${U:-platform}"
}
slots() { jq -c --arg u "${U:-platform}" '.key_slots[$u]' "$STATE/key-slots.tfvars.json"; }

@test "a rotation adds slot b, moves the keyring and the cluster, and deletes the old key once the new one is used" {
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(slots)" = '{"active":"b","keep":["b"]}' ]
  [ "$("$REPO/scripts/keyring.sh" get "$STATE/keyring.env" BUCKET_ACCESS_KEY)" = AKIABBBBBBBBBBBBBBBB ]
  [ "$(jq -c 'keys' "$D/keys.json")" = '["b"]' ]
  grep -q "restart deployment/velero" "$D/log"
  # A DaemonSet reader restarts too: its want is desiredNumberScheduled
  # (review of hosted#776).
  grep -q "restart daemonset/node-agent" "$D/log"
  run grep -q "restart deployment/unrelated" "$D/log"
  [ "$status" -ne 0 ]
  grep -q "restart deployment/envreader" "$D/log"
  run grep -q "restart statefulset/otherkeys" "$D/log"
  [ "$status" -ne 0 ]
  run grep -q "restart statefulset/gibson-openbao" "$D/log"
  [ "$status" -ne 0 ]
  grep -q "substrate.env" "$D/log"
}

@test "FAILING FIXTURE: a reader that wants 0 pods is reported as nothing to restart, never as restarted (hosted#12)" {
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  WANT0=deployment/velero rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"nothing to restart in velero/deployment/velero"* ]] || { echo "$output"; false; }
  [[ "$output" != *"restarted velero/deployment/velero"* ]] || { echo "$output"; false; }
  [[ "$output" == *"restarted "*"deployment/envreader"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: the old key used after the switch stops the rotation, and both keys stay" {
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  echo $(( $(date +%s) + 60 )) > "$D/used/AKIAAAAAAAAAAAAAAAAA"
  rotate
  [ "$status" -eq 3 ]
  [[ "$output" == *"a consumer still holds it"* ]]
  [ "$(slots)" = '{"active":"b","keep":["a","b"]}' ]
  [ "$(jq -c 'keys' "$D/keys.json")" = '["a","b"]' ]
}

@test "a use of the old key while its readers restart is not a consumer that still holds it" {
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  OLD_USED_AT_RESTART=1 rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"the cluster runs on the new key of platform from"* ]] || { echo "$output"; false; }
  [ "$(jq -c 'keys' "$D/keys.json")" = '["b"]' ]
}

@test "a new rotation drops the switch time of the last one, and records its own after the restarts" {
  echo '{"platform": 1000}' > "$STATE/key-rotation.json"
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  before="$(date +%s)"
  rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -r .platform "$STATE/key-rotation.json")" -ge "$before" ]
}

@test "FAILING FIXTURE: a run that stops after the slots change never keeps the switch time of the last rotation" {
  echo '{"platform": 1000}' > "$STATE/key-rotation.json"
  # The apply fails after it made the new key.
  APPLY_FAIL=1 rotate
  [ "$status" -ne 0 ]
  [ "$(jq -r '.platform // "none"' "$STATE/key-rotation.json")" = none ]
  # The old key was used until now. The next run continues the rotation and
  # records its own switch time, so that use does not halt it.
  echo $(( $(date +%s) - 5 )) > "$D/used/AKIAAAAAAAAAAAAAAAAA"
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  sleep 1
  rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a later run of an open rotation keeps the first switch time" {
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  QUIET_SECS=3600 rotate
  [ "$status" -eq 10 ]
  first="$(jq -r .platform "$STATE/key-rotation.json")"
  sleep 1
  QUIET_SECS=3600 rotate
  [ "$status" -eq 10 ]
  [ "$(jq -r .platform "$STATE/key-rotation.json")" = "$first" ]
}

@test "a new key not yet in use stops the run, and a later run finishes the rotation" {
  rotate
  [ "$status" -eq 10 ]
  [[ "$output" == *"no use of the new key"* ]]
  [ "$(slots)" = '{"active":"b","keep":["a","b"]}' ]
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(slots)" = '{"active":"b","keep":["b"]}' ]
}

@test "FAILING FIXTURE: an open rotation on a runner with no initialized backend inits first and goes on (drill rotation run 1)" {
  rotate
  [ "$status" -eq 10 ]
  # A fresh runner: nothing is initialized, and the next call is not an apply.
  rm -f "$D/tf.inited"
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  STUB_TF_REQUIRE_INIT=1 rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(slots)" = '{"active":"b","keep":["b"]}' ]
}

@test "FAILING FIXTURE: a terraform error ends with exit 2 and never with the exit 10 of a wait (drill rotation run 1)" {
  rotate
  [ "$status" -eq 10 ]
  STUB_TF_OUTPUT_FAIL=1 rotate
  [ "$status" -eq 2 ] || { echo "status ${status}: $output"; false; }
  # The rotation stays open: the old key is not deleted.
  [ "$(slots)" = '{"active":"b","keep":["a","b"]}' ]
}

@test "FAILING FIXTURE: a plan that deletes anything else stops before the apply" {
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  EXTRA_DELETE='aws_s3_bucket.durable' rotate
  [ "$status" -eq 2 ]
  [[ "$output" == *"the plan deletes"* ]]
  [ "$(jq -c 'keys' "$D/keys.json")" = '["a"]' ]
}

@test "inside the quiet time the old key stays, and the run asks to come back" {
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  QUIET_SECS=3600 rotate
  [ "$status" -eq 10 ]
  [[ "$output" == *"must stay unused"* ]]
  [ "$(slots)" = '{"active":"b","keep":["a","b"]}' ]
}

@test "FAILING FIXTURE: a reader that does not run again after the restart stops the rotation, and both keys stay" {
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  NOT_READY=deployment/velero rotate
  [ "$status" -eq 10 ]
  [[ "$output" == *"does not run again"* ]]
  [ "$(jq -c 'keys' "$D/keys.json")" = '["a","b"]' ]
}

# smtp: the first apply makes the key of slot b. The relay accepts it, and
# ESO writes it, only when the test says so.
smtp_relay_new() {
  jq -n --arg p "$(cat "$D/secret.b")" '{user: "AKIABBBBBBBBBBBBBBBB", password: $p}' > "$D/relay.new"
  printf '\0%s\0%s' AKIABBBBBBBBBBBBBBBB "$(cat "$D/secret.b")" | base64 -w0 > "$D/relay.accept"
}

@test "an smtp rotation moves the derived Secret, restarts its readers, updates Zitadel, and proves the relay takes the new key" {
  export U=smtp
  ESO_STALE=1 rotate
  [ "$status" -eq 10 ]
  [[ "$output" == *"does not hold the new SMTP credential yet"* ]]
  smtp_relay_new
  rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"the platform-operator applied the new SMTP password to Zitadel"* ]]
  [[ "$output" == *"accepts the new SMTP credential"* ]]
  grep -q "restart statefulset/gibson-daemon" "$D/log"
  run grep -q "restart statefulset/gibson-openbao" "$D/log"
  [ "$status" -ne 0 ]
  [ "$(slots)" = '{"active":"b","keep":["b"]}' ]
  [ "$(jq -c 'keys' "$D/keys.json")" = '["b"]' ]
}

@test "an smtp rotation refreshes each copy of the relay Secret in another namespace" {
  export U=smtp
  ESO_STALE=1 rotate
  smtp_relay_new
  COPY=1 rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"the copy monitoring/alertmanager-config refreshed from gibson/gibson-email-smtp"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a copy of the relay Secret that does not refresh stops the rotation before the switch time" {
  export U=smtp
  ESO_STALE=1 rotate
  smtp_relay_new
  COPY=1 COPY_STALE=1 rotate
  [ "$status" -eq 10 ]
  [[ "$output" == *"the copy monitoring/alertmanager-config of gibson/gibson-email-smtp has not refreshed yet"* ]] || { echo "$output"; false; }
  [ "$(jq -r '.smtp // "none"' "$STATE/key-rotation.json")" = none ]
}

@test "FAILING FIXTURE: the operator wait has its own deadline after a slow copy wait" {
  # The Secret wait breaks before its deadline check. The copy wait then uses
  # its whole WAIT_SECS of 2: the first read is stale, the second takes 3 s.
  # The operator applies on its second read. Only the operator's own
  # deadline lets that read happen. No step here depends on the speed of the
  # runner: each wait ends on a read, not on a race with the clock.
  export U=smtp
  ESO_STALE=1 rotate
  smtp_relay_new
  rm -f "$D/eso.calls"
  COPY=1 COPY_SLOW=1 OPERATOR_LATE=1 WAIT_SECS=2 rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"the platform-operator applied the new SMTP password to Zitadel"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a copy that refreshed and is not Ready stops the rotation" {
  export U=smtp
  ESO_STALE=1 rotate
  smtp_relay_new
  COPY=1 COPY_NOT_READY=1 rotate
  [ "$status" -eq 10 ]
  [[ "$output" == *"has not refreshed yet"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a list of the ExternalSecrets that cannot be read stops the rotation" {
  export U=smtp
  ESO_STALE=1 rotate
  smtp_relay_new
  COPY=1 COPY_LIST_BROKEN=1 rotate
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot list the ExternalSecrets of the cluster"* ]] || { echo "$output"; false; }
  [ "$(jq -r '.smtp // "none"' "$STATE/key-rotation.json")" = none ]
}

@test "FAILING FIXTURE: the smtp Secret wait uses SECRET_WAIT_SECS, not WAIT_SECS" {
  # WAIT_SECS 0 would stop at the first stale read. ESO writes on its second
  # refresh, inside SECRET_WAIT_SECS.
  export U=smtp
  ESO_STALE=1 rotate
  smtp_relay_new
  rm -f "$D/eso.calls"
  ESO_AFTER=2 SECRET_WAIT_SECS=30 WAIT_SECS=0 rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"gibson/gibson-email-smtp holds the new SMTP credential"* ]] || { echo "$output"; false; }
}

@test "a copy that reads the relay Secret through dataFrom refreshes too" {
  export U=smtp
  ESO_STALE=1 rotate
  smtp_relay_new
  COPY=1 COPY_DATAFROM=1 rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"the copy monitoring/alertmanager-config refreshed"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: an smtp rotation that Zitadel did not take keeps the old key" {
  export U=smtp
  ESO_STALE=1 rotate
  smtp_relay_new
  OPERATOR_STALE=1 rotate
  [ "$status" -eq 10 ]
  [[ "$output" == *"the Zitadel SMTP provider does not hold the new password yet"* ]]
  [ "$(jq -c 'keys' "$D/keys.json")" = '["a","b"]' ]
}

@test "FAILING FIXTURE: a relay that refuses the new smtp key keeps the old key" {
  export U=smtp
  ESO_STALE=1 rotate
  smtp_relay_new
  echo refused > "$D/relay.accept"
  rotate
  [ "$status" -eq 3 ]
  [[ "$output" == *"refuses the new SMTP credential"* ]]
  [ "$(jq -c 'keys' "$D/keys.json")" = '["a","b"]' ]
}

@test "a setec-disk-builder rotation moves the disk push pair in the keyring and restarts only its readers (D85)" {
  export U=setec-disk-builder TFRES=setec_disk_builder
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(slots)" = '{"active":"b","keep":["b"]}' ]
  [ "$("$REPO/scripts/keyring.sh" get "$STATE/keyring.env" SETEC_DISK_PUSH_ACCESS_KEY)" = AKIABBBBBBBBBBBBBBBB ]
  [ "$("$REPO/scripts/keyring.sh" get "$STATE/keyring.env" SETEC_DISK_PUSH_SECRET_KEY)" = "$(cat "$D/secret.b")" ]
  grep -q "restart deployment/disk-registry-reader" "$D/log"
  run grep -q "restart deployment/velero" "$D/log"
  [ "$status" -ne 0 ]
  [ "$(jq -c 'keys' "$D/keys.json")" = '["b"]' ]
}

# drill keeps stage 0 in AWS (ADR-0083, scripts/stage0-store.sh): the run reads
# the slots and the keyring from there, and keeps every change there, also
# when it stops.
@test "a drill rotation reads stage 0 from AWS and keeps each change there" {
  mkdir -p "$D/s3"
  cp "$STATE/key-slots.tfvars.json" "$D/s3/key-slots.tfvars.json"
  jq -n --rawfile k "$STATE/keyring.env" --rawfile s "$STATE/substrate.env" '{keyring: $k, substrate_env: $s}' > "$D/sm.json"
  rm -f "$STATE/key-slots.tfvars.json" "$STATE/keyring.env" "$STATE/substrate.env"
  # A new key not yet in use: the run stops after the switch.
  E=drill rotate
  [ "$status" -eq 10 ]
  [[ "$output" == *"no use of the new key"* ]]
  [ "$(jq -c '.key_slots.platform' "$D/s3/key-slots.tfvars.json")" = '{"active":"b","keep":["a","b"]}' ]
  printf '%s' "$(jq -r .keyring "$D/sm.json")" > "$D/kr"
  [ "$("$REPO/scripts/keyring.sh" get "$D/kr" BUCKET_ACCESS_KEY)" = AKIABBBBBBBBBBBBBBBB ]
  # A later run, from a runner with no files, finishes the rotation.
  rm -rf "$STATE"; mkdir -p "$STATE"
  date +%s > "$D/used/AKIABBBBBBBBBBBBBBBB"
  E=drill rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(jq -c '.key_slots.platform' "$D/s3/key-slots.tfvars.json")" = '{"active":"b","keep":["b"]}' ]
}

@test "FAILING FIXTURE: a drill rotation with no keyring in AWS stops before it changes a key" {
  rm -f "$STATE/key-slots.tfvars.json"
  E=drill rotate
  [ "$status" -ne 0 ]
  [ ! -s "$D/log" ] || [ "$(grep -c apply "$D/log")" = 0 ]
}

@test "FAILING FIXTURE: a keyring changed on the runner after its pull is never overwritten by the next pull" {
  mkdir -p "$D/s3"
  cp "$STATE/key-slots.tfvars.json" "$D/s3/key-slots.tfvars.json"
  jq -n --rawfile k "$STATE/keyring.env" --rawfile s "$STATE/substrate.env" '{keyring: $k, substrate_env: $s}' > "$D/sm.json"
  rm -f "$STATE/key-slots.tfvars.json" "$STATE/keyring.env" "$STATE/substrate.env"
  E=drill rotate
  [ "$status" -eq 10 ]
  # The seal key class of the rotation test rotates the seal key in this
  # runner's keyring only. The next substrate-rotate.sh must not pull over it.
  sed -i "s|^OPENBAO_SEAL_KEY=.*|OPENBAO_SEAL_KEY=$(head -c 32 /dev/urandom | base64 -w0)|" "$STATE/keyring.env"
  before="$(sha256sum < "$STATE/keyring.env")"
  E=drill rotate
  [ "$status" -eq 2 ]
  [[ "$output" == *"changed since it was read from or written to AWS"* ]]
  [ "$(sha256sum < "$STATE/keyring.env")" = "$before" ]
}
