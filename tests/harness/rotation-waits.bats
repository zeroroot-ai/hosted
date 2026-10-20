#!/usr/bin/env bats
#
# rotation-waits.bats: each wait and each lifetime of the rotation test covers
# the producer it waits for (audit of the drill path, 2026-10-19).
#
#   - redis-password waits for as long as the CronJob Job may run, plus one
#     tick and the ESO write.
#   - platform-signing-keys mints a reader SVID that lives to the end of the
#     class.
#   - zitadel-bringup-tokens rotates both tokens at once, so the two retire
#     graces run side by side in one deadline.
#   - openfga-preshared-key waits a kubelet sync period between its two
#     rotations, so no client holds a key that OpenFGA dropped.
#
# Offline. The class functions are taken out of the script text and run with
# stubs. A fake clock stands in for `date +%s` and `sleep`, so a wait costs
# no time. Each assertion uses `run` and `$status`.
#
# Run:
#   bats tests/harness/rotation-waits.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TEST="$REPO_ROOT/test/rotation/exit-test-rotation.sh"

setup() { TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

# extract SCRIPT OUT NAME...: the functions and the NAME=value lines of SCRIPT.
extract() {
  python3 - "$@" <<'PY'
import re, sys
src, dst, names = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(src).read()
out = []
for name in names:
    m = (re.search(r"^%s\(\) \{.*?^\}\n|^%s\(\) \{[^\n]*\}\n" % (name, name), text, re.M | re.S)
         or re.search(r'^%s="[^"]*"\n' % name, text, re.M)
         or re.search(r"^%s=.*\n" % name, text, re.M))
    if not m:
        sys.exit("no %s in the script" % name)
    out.append(m.group(0))
open(dst, "w").write("\n".join(out))
PY
}

# The fake clock: `date +%s` reads it, and `sleep N` moves it on by N.
CLOCK='
date() { if [ "${1:-}" = +%s ]; then cat "$D/clock"; else command date "$@"; fi; }
sleep() { echo $(( $(cat "$D/clock") + $1 )) > "$D/clock"; }
ok() { echo "ok: $*"; }
miss() { echo "miss: $*"; return 1; }
mask() { :; }
'

# --- redis-password ----------------------------------------------------------

# redis_wait SCRIPT LIMIT EVERY: redis_rotation_wait of SCRIPT, with a CronJob
# whose Job limit is LIMIT and an ExternalSecret that refreshes EVERY (empty:
# the field is not set).
redis_wait() {
  extract "$1" "$TMP/redis.sh" REDIS_TICK_S duration_s redis_rotation_wait
  run env LIMIT="$2" EVERY="$3" bash -c '
    NS=gibson RELEASE=gibson
    kubectl() {
      case "$*" in
        "-n gibson get cronjob gibson-redis-rotation -o jsonpath={.spec.jobTemplate.spec.activeDeadlineSeconds}") printf "%s" "$LIMIT" ;;
        "-n gibson get externalsecret gibson-redis-stack -o jsonpath={.spec.refreshInterval}") printf "%s" "$EVERY" ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    . "$1"; redis_rotation_wait gibson-redis-stack' _ "$TMP/redis.sh"
}

@test "the redis wait is the Job limit of the CronJob, one tick and two refresh intervals of the ExternalSecret" {
  redis_wait "$TEST" 1800 60s
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" -eq 1980 ]
  redis_wait "$TEST" 1800 1m30s
  [ "$output" -eq 2040 ]
}

@test "FAILING FIXTURE: a CronJob with no Job limit gives no wait, never a default" {
  redis_wait "$TEST" "" 60s
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "FAILING FIXTURE: an ExternalSecret with no refresh interval, or one that is not a duration, gives no wait" {
  redis_wait "$TEST" 1800 ""
  [ "$status" -ne 0 ]
  redis_wait "$TEST" 1800 "soon"
  [ "$status" -ne 0 ]
}

@test "the longest redis wait of charts 0.151.1 is the most the time bound allows" {
  extract "$TEST" "$TMP/max.sh" REDIS_TICK_S REDIS_WAIT_MAX_S
  run bash -c '. "$1"; echo "$REDIS_WAIT_MAX_S"' _ "$TMP/max.sh"
  [ "$output" -eq 1980 ]
}

@test "the redis class waits redis_rotation_wait, not the fixed ROTATION_WAIT" {
  extract "$TEST" "$TMP/class.sh" class_redis_password
  run grep -c 'redis_rotation_wait' "$TMP/class.sh"
  [ "$output" -ge 1 ]
  run grep -c 'ROTATION_WAIT' "$TMP/class.sh"
  [ "$output" -eq 0 ] || { grep -n 'ROTATION_WAIT' "$TMP/class.sh"; false; }
}

# --- platform-signing-keys ---------------------------------------------------

# svid_ttl SCRIPT: the seconds of the -ttl that the class of SCRIPT gives the
# reader SVID, with ROTATION_WAIT 1500. The stub spire records its arguments
# and fails, so the class stops right after the mint.
svid_ttl() {
  extract "$1" "$TMP/cg.sh" CG_SVID_SLACK_S class_platform_signing_keys
  mkdir -p "$TMP/charts/scripts"
  printf '#!/bin/sh\n' > "$TMP/charts/scripts/baseline-set-secret.sh"
  chmod +x "$TMP/charts/scripts/baseline-set-secret.sh"
  run env D="$TMP" bash -c '
    NS=gibson RELEASE=gibson DAEMON_STS=gibson-gibson-workloads ROTATION_WAIT=1500 CHARTS_ROOT="$D/charts"
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
    spire() { echo "$*" > "$D/spire.args"; return 1; }
    . "$1"; class_platform_signing_keys' _ "$TMP/cg.sh"
  [ -s "$TMP/spire.args" ] || { echo "$output"; return 1; }
  python3 - "$(cat "$TMP/spire.args")" <<'PY'
import re, sys
m = re.search(r"-ttl (\d+)([smh])\b", sys.argv[1])
if not m:
    sys.exit("no -ttl in: " + sys.argv[1])
print(int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)])
PY
}

@test "the reader SVID outlives the deadline of the class and the last checks after it" {
  ttl="$(svid_ttl "$TEST")"
  extract "$TEST" "$TMP/slack.sh" CG_SVID_SLACK_S
  slack="$(bash -c '. "$1"; echo "$CG_SVID_SLACK_S"' _ "$TMP/slack.sh")"
  echo "ttl=${ttl} slack=${slack}"
  [ "$slack" -ge 300 ]
  [ "$ttl" -ge $(( 1500 + slack )) ]
}

@test "FAILING FIXTURE: a reader SVID of ROTATION_WAIT plus one second ends during the checks after the deadline" {
  sed 's/-ttl "\$(( ROTATION_WAIT + CG_SVID_SLACK_S ))s"/-ttl "$(( ROTATION_WAIT + 1 ))s"/' "$TEST" > "$TMP/short.sh"
  ttl="$(svid_ttl "$TMP/short.sh")"
  [ "$ttl" -eq 1501 ]
  run test "$ttl" -ge 1800
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: a reader SVID of 10 minutes ends inside the class" {
  sed 's/-ttl "\$(( ROTATION_WAIT + CG_SVID_SLACK_S ))s"/-ttl 10m/' "$TEST" > "$TMP/old.sh"
  run grep -c -- '-ttl 10m' "$TMP/old.sh"
  [ "$output" -eq 1 ]
  ttl="$(svid_ttl "$TMP/old.sh")"
  [ "$ttl" -eq 600 ]
  run test "$ttl" -gt 1500
  [ "$status" -ne 0 ]
}

# --- zitadel-bringup-tokens --------------------------------------------------

# The operator model: a token made due gets a new token 30 s later, and Zitadel
# refuses the old token RETIRE seconds after the new one is in its Secret.
# ROTATION_WAIT 150, so the class deadline is 300 s: one retire grace of 180 s
# fits, two in a row do not.
zitadel_run() {
  extract "$TEST" "$TMP/zt.sh" ZITADEL_TOKENS ROLLOUT_WAIT_S RECONCILE_PASS_S class_zitadel_bringup_tokens
  echo 1000 > "$TMP/clock"
  mkdir -p "$TMP/charts/scripts"
  printf '#!/bin/sh\n' > "$TMP/charts/scripts/baseline-set-secret.sh"
  chmod +x "$TMP/charts/scripts/baseline-set-secret.sh"
  run env D="$TMP" RETIRE="$1" bash -c "$CLOCK"'
    NS=gibson RELEASE=gibson ROTATION_WAIT=150 CHARTS_ROOT="$D/charts"
    now() { cat "$D/clock"; }
    due_at() { cat "$D/due.$1" 2>/dev/null; }
    set_at_source() { echo "set $1 $2" >> "$D/events"; now > "$D/due.$1"; }
    key_of() { case "$1" in iam-admin-pat) echo gibson-zitadel-iam-admin-pat ;; login-client) echo gibson-zitadel-login-client-pat ;; esac; }
    secret_value() {
      local t; t="$(due_at "$(key_of "$1")")"
      if [ -n "$t" ] && [ "$(now)" -ge $(( t + 30 )) ]; then echo "new-$1"; else echo "old-$1"; fi
    }
    zitadel_user_status() {
      local s="${1#*-}" t; t="$(due_at "$(key_of "$s")")"
      case "$1" in
        new-*) echo 200 ;;
        old-*) if [ -n "$t" ] && [ "$(now)" -ge $(( t + 30 + RETIRE )) ]; then echo 401; else echo 200; fi ;;
      esac
    }
    kubectl() {
      case "$*" in
        "-n gibson rollout status deployment/gibson-zitadel-login --timeout=300s") return 0 ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    bootstrap_ready() { return 0; }
    . "$1"; class_zitadel_bringup_tokens' _ "$TMP/zt.sh"
}

@test "both Zitadel tokens are made due before the class waits, so two retire graces fit one deadline" {
  zitadel_run 180
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$TMP/events")" = "$(printf 'set gibson-zitadel-iam-admin-pat mintedAt\nset gibson-zitadel-login-client-pat mintedAt')" ]
  [ "$(cat "$TMP/due.gibson-zitadel-iam-admin-pat")" = "$(cat "$TMP/due.gibson-zitadel-login-client-pat")" ]
  [[ "$output" == *"Zitadel refuses the old token of iam-admin-pat"* ]]
  [[ "$output" == *"Zitadel refuses the old token of login-client"* ]]
}

@test "FAILING FIXTURE: a retire grace longer than the deadline fails the class and names each token still open" {
  zitadel_run 400
  [ "$status" -ne 0 ]
  [[ "$output" == *"the token rotation did not finish"* ]] || { echo "$output"; false; }
  [[ "$output" == *"iam-admin-pat: Zitadel answers 200 to the old token, not 401"* ]]
  [[ "$output" == *"login-client: Zitadel answers 200 to the old token, not 401"* ]]
}

# --- openfga-preshared-key ---------------------------------------------------

# The model: OpenFGA accepts `key` and `key_previous` at once after a write.
# The clients read `key` SYNC seconds after its write (the kubelet). A write
# of `key` that leaves OpenFGA without the key a client holds makes that
# client log a refused call until the kubelet catches up, and makes a daemon
# that is asked then not Ready.
# fga_run SCRIPT SYNC
fga_run() {
  extract "$1" "$TMP/fga.sh" KUBELET_SYNC_WAIT new_fga_key class_openfga_preshared_key
  echo 1000 > "$TMP/clock"
  mkdir -p "$TMP/charts/scripts"
  printf '#!/bin/sh\n' > "$TMP/charts/scripts/baseline-set-secret.sh"
  chmod +x "$TMP/charts/scripts/baseline-set-secret.sh"
  printf 'k0' > "$TMP/key"; printf '' > "$TMP/prev"; printf 'k0' > "$TMP/client"; echo 0 > "$TMP/key.at"; : > "$TMP/refused"
  run env D="$TMP" SYNC="$2" bash -c "$CLOCK"'
    NS=gibson RELEASE=gibson ROTATION_WAIT=1500 CHARTS_ROOT="$D/charts"
    now() { cat "$D/clock"; }
    # The kubelet: the clients hold the last key written SYNC seconds ago.
    client_key() { if [ "$(now)" -ge $(( $(cat "$D/key.at") + SYNC )) ]; then cat "$D/key"; else cat "$D/client"; fi; }
    set_at_source() {
      local held
      case "$2" in
        key)
          held="$(client_key)"; printf "%s" "$held" > "$D/client"
          printf "%s" "$3" > "$D/key"; now > "$D/key.at"
          [ "$held" = "$3" ] || [ "$held" = "$(cat "$D/prev")" ] || echo "refused $held" >> "$D/refused" ;;
        key_previous) printf "%s" "$3" > "$D/prev" ;;
      esac
    }
    secret_value() { [ "$1 $2" = "gibson-openfga-preshared-key key" ] && cat "$D/key"; }
    fga_status() {
      if [ -z "$1" ]; then echo 401
      elif [ "$1" = "$(cat "$D/key")" ] || [ "$1" = "$(cat "$D/prev")" ]; then echo 200
      else echo 401; fi
    }
    daemons_ready() { [ "$(fga_status "$(client_key)")" = 200 ]; }
    # The proof of the script reads the key back from the daemon key file.
    # Here the file holds what the kubelet model gives.
    wait_fga_clients() { while [ "$(client_key)" != "$1" ]; do sleep 10; done; }
    daemon_restarts() { echo "gibson-gibson-workloads-0/daemon 0"; }
    pods_of() { echo gibson-gibson-workloads-0; }
    daemon_readyz() { if daemons_ready; then echo 200; else echo 503; fi; }
    refused_fga_calls() { wc -l < "$D/refused" | tr -d " "; }
    restart_ext_authz() { return 0; }
    bootstrap_ready() { return 0; }
    . "$1"; class_openfga_preshared_key' _ "$TMP/fga.sh"
}

@test "the second OpenFGA rotation waits until the clients hold the first new key" {
  fga_run "$TEST" 90
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -s "$TMP/refused" ]
  [[ "$output" == *"no OpenFGA client logged a refused call"* ]]
}

@test "FAILING FIXTURE: with no wait between the two rotations a client is refused, and the class fails" {
  python3 - "$TEST" "$TMP/old.sh" <<'PY2'
import sys
text = open(sys.argv[1]).read()
line = '  wait_fga_clients "$k1" "$written" "$deadline" || return 1\n'
if line not in text:
    sys.exit("the wait before the second rotation is not in the script")
open(sys.argv[2], "w").write(text.replace(line, "", 1))
PY2
  fga_run "$TMP/old.sh" 90
  [ "$status" -ne 0 ]
  [ -s "$TMP/refused" ]
  [[ "$output" == *"refused OpenFGA calls during the rotations"* ]] || { echo "$output"; false; }
}

# --- the OpenFGA key read-back (review of hosted#805) --------------------------

# pod_json SUBPATH SECRET: a daemon pod that reads its key from SECRET, by
# SUBPATH when it is not empty.
pod_json() {
  python3 - "$1" "$2" <<'PY2'
import json, sys
sub, secret = sys.argv[1], sys.argv[2]
m = {"name": "openfga-key", "mountPath": "/etc/gibson/openfga-key"}
if sub:
    m["subPath"] = sub
print(json.dumps({"spec": {
  "volumes": [{"name": "openfga-key", "secret": {"secretName": secret}}],
  "containers": [{"name": "gibson", "env": [{"name": "GIBSON_FGA_KEY_DIR", "value": "/etc/gibson/openfga-key"}],
                  "volumeMounts": [m]}]}}))
PY2
}

# fga_wait_run SUBPATH SECRET HELD: wait_fga_clients for the key k1, with one
# daemon pod whose key file holds HELD.
fga_wait_run() {
  extract "$TEST" "$TMP/w.sh" KUBELET_SYNC_WAIT FGA_KEY_SECRET fga_key_mounts fga_key_held wait_fga_clients
  echo 1000 > "$TMP/clock"
  pod_json "$1" "$2" > "$TMP/pod.json"
  run env D="$TMP" HELD="$3" bash -c "$CLOCK"'
    NS=gibson FGA_CLIENTS="app.kubernetes.io/component=daemon"
    pods_of() { echo gibson-gibson-workloads-0; }
    kubectl() {
      case "$*" in
        "-n gibson get pod gibson-gibson-workloads-0 -o json") cat "$D/pod.json" ;;
        "-n gibson exec gibson-gibson-workloads-0 -c gibson -- sh -c "*) printf "%s" "$HELD" | sha256sum ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    . "$1"; wait_fga_clients k1 1000 1300' _ "$TMP/w.sh"
}

@test "a daemon that reads the new key back from its Secret volume passes, after the kubelet bound for the other clients" {
  fga_wait_run "" gibson-openfga-preshared-key k1
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$TMP/clock")" -ge 1120 ]
}

@test "FAILING FIXTURE: a daemon that still holds the old key fails at the deadline, and names the pod" {
  fga_wait_run "" gibson-openfga-preshared-key k0
  [ "$status" -ne 0 ]
  [[ "$output" == *"gibson-gibson-workloads-0/gibson does not hold the new OpenFGA key"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a key mounted by subPath is a mount defect, refused at once" {
  fga_wait_run key gibson-openfga-preshared-key k1
  [ "$status" -ne 0 ]
  [[ "$output" == *"mounted by subPath"* ]] || { echo "$output"; false; }
  [ "$(cat "$TMP/clock")" -eq 1000 ]
}

@test "FAILING FIXTURE: a key directory that is not the preshared key Secret is refused" {
  fga_wait_run "" some-other-secret k1
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a volume of the Secret gibson-openfga-preshared-key"* ]] || { echo "$output"; false; }
}
