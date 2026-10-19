#!/usr/bin/env bats
#
# rotation-bounds.bats: the declared time bound of a class covers its slowest
# path (review of hosted#807).
#
# Each class that rotates in place runs with stubs and a fake clock. Each
# wait of the class runs to its limit, and each producer answers as late as
# the class still passes: just before the class deadline, or at the end of a
# wait of fixed length. The test then asserts that the class passed and that
# the fake time it took is not more than time_bound_of of the class. A bound
# cut below the slowest path fails the test.
#
# Classes: openfga-preshared-key, keyring-generated-keys and
# platform-generated-secrets.
#
# Offline. Each assertion uses `run` and `$status`.
#
# Run:
#   bats tests/harness/rotation-bounds.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TEST="$REPO_ROOT/test/rotation/exit-test-rotation.sh"

setup() {
  TMP="$(mktemp -d)"
  echo 100000 > "$TMP/clock"
  mkdir -p "$TMP/charts/scripts"
  printf '#!/bin/sh\n' > "$TMP/charts/scripts/baseline-set-secret.sh"
  chmod +x "$TMP/charts/scripts/baseline-set-secret.sh"
}
teardown() { rm -rf "$TMP"; }

# src SCRIPT FUNCTION...: the simple constants of SCRIPT and FUNCTIONs.
src() {
  python3 - "$@" "$TMP/src.sh" <<'EOPY'
import re, sys
script, names, dst = sys.argv[1], sys.argv[2:-1], sys.argv[-1]
text = open(script).read()
simple = r'^[A-Z][A-Z0-9_]*=(?:\d+|"\$\{[A-Z0-9_]+:-\d+\}"|\$\(\(.*\)\))'
out = [re.match(simple, l).group(0) for l in re.findall(r'^[A-Z][A-Z0-9_]*=.*$', text, re.M)
       if re.match(simple + r'[ \t]*(?:#.*)?$', l)]
for n in names:
    # A one-line function first, so the match does not run on into the
    # functions after it.
    m = (re.search(r"^%s\(\) \{[^\n]*\}\n" % n, text, re.M)
         or re.search(r"^%s\(\) \{.*?^\}\n" % n, text, re.M | re.S))
    if not m:
        sys.exit("no function %s in the script" % n)
    out.append(m.group(0))
open(dst, "w").write("\n".join(out) + "\n")
EOPY
}

# The fake clock and the plain helpers, for each class.
COMMON='
date() { if [ "${1:-}" = +%s ]; then cat "$D/clock"; else command date "$@"; fi; }
sleep() { echo $(( $(cat "$D/clock") + $1 )) > "$D/clock"; }
now() { cat "$D/clock"; }
ok() { echo "ok: $*"; }
miss() { echo "miss: $*"; return 1; }
mask() { :; }
bootstrap_ready() { return 0; }
NS=gibson RELEASE=gibson ROTATION_WAIT=1500 CHARTS_ROOT="$D/charts"
'

# took_within NAME: the class passed, and the fake time it took is not more
# than the bound of NAME less BOUND_SLACK_S. The fake clock spends nothing on
# reads, and the slack is for the reads of a real run, so the waits alone
# must fit the bound without it (review of hosted#807).
took_within() {
  local took bound slack
  took=$(( $(cat "$TMP/clock") - 100000 ))
  bound="$(bash -c '. "$1"; time_bound_of "$2"' _ "$TMP/src.sh" "$1")"
  slack="$(bash -c '. "$1"; echo "$BOUND_SLACK_S"' _ "$TMP/src.sh")"
  echo "took ${took} s, bound ${bound} s, slack ${slack} s"
  [ "$slack" -gt 0 ] && [ "$took" -le $(( bound - slack )) ]
}

# --- openfga-preshared-key ---------------------------------------------------

# OpenFGA and the daemon key file move to a new key at the gate G, 5 s before
# the class deadline. Before G, OpenFGA answers 503 after a write. The
# restart of ext-authz takes its whole limit.
fga_slow() {
  src "$1" time_bound_of new_fga_key fga_key_mounts fga_key_held wait_fga_clients class_openfga_preshared_key
  printf 'k0' > "$TMP/key"; printf '' > "$TMP/prev"; : > "$TMP/written"
  python3 - > "$TMP/pod.json" <<'EOPY'
import json
print(json.dumps({"spec": {
  "volumes": [{"name": "openfga-key", "secret": {"secretName": "gibson-openfga-preshared-key"}}],
  "containers": [{"name": "gibson", "env": [{"name": "GIBSON_FGA_KEY_DIR", "value": "/etc/gibson/openfga-key"}],
                  "volumeMounts": [{"name": "openfga-key", "mountPath": "/etc/gibson/openfga-key"}]}]}}))
EOPY
  run env D="$TMP" bash -c "$COMMON"'
    G=$(( $(now) + ROTATION_WAIT - 5 ))
    FGA_CLIENTS="app.kubernetes.io/component=daemon" FGA_KEY_SECRET=gibson-openfga-preshared-key
    set_at_source() {
      case "$2" in key) printf "%s" "$3" > "$D/key"; echo w > "$D/written" ;; key_previous) printf "%s" "$3" > "$D/prev" ;; esac
    }
    secret_value() { cat "$D/key"; }
    fga_status() {
      if [ -s "$D/written" ] && [ "$(now)" -lt "$G" ]; then echo 503; return; fi
      if [ -z "$1" ]; then echo 401
      elif [ "$1" = "$(cat "$D/key")" ] || [ "$1" = "$(cat "$D/prev")" ]; then echo 200
      else echo 401; fi
    }
    daemons_ready() { return 0; }
    daemon_restarts() { echo "d/gibson 0"; }
    daemon_readyz() { echo 200; }
    refused_fga_calls() { echo 0; }
    pods_of() { echo gibson-gibson-workloads-0; }
    kubectl() {
      case "$*" in
        "-n gibson get pod gibson-gibson-workloads-0 -o json") cat "$D/pod.json" ;;
        "-n gibson exec gibson-gibson-workloads-0 -c gibson -- sh -c "*)
          if [ "$(now)" -ge "$G" ]; then printf "%s" "$(cat "$D/key")" | sha256sum; else echo stale | sha256sum; fi ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    restart_pods() { sleep "$3"; }
    . "$D/src.sh"; class_openfga_preshared_key'
}

@test "openfga-preshared-key: the slowest passing path fits its bound" {
  fga_slow "$TEST"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run took_within openfga-preshared-key
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: an openfga bound of ROTATION_WAIT alone is shorter than the slowest path" {
  sed 's/^\(    openfga-preshared-key) *b=\).*$/\1$(( w )) ;;/' "$TEST" > "$TMP/cut.sh"
  run grep -c 'openfga-preshared-key) *b=$(( w )) ;;' "$TMP/cut.sh"
  [ "$output" -eq 1 ]
  fga_slow "$TMP/cut.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run took_within openfga-preshared-key
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: an openfga bound with no restart of ext-authz is shorter than the slowest path" {
  sed 's/^\(    openfga-preshared-key) *b=\).*$/\1$(( w + 2 * KUBELET_SYNC_WAIT )) ;;/' "$TEST" > "$TMP/cut.sh"
  run grep -c 'openfga-preshared-key) *b=$(( w + 2 \* KUBELET_SYNC_WAIT )) ;;' "$TMP/cut.sh"
  [ "$output" -eq 1 ]
  fga_slow "$TMP/cut.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run took_within openfga-preshared-key
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: an openfga bound with no kubelet wait is shorter than the slowest path" {
  sed 's/^\(    openfga-preshared-key) *b=\).*$/\1$(( w + RESTART_WAIT_S )) ;;/' "$TEST" > "$TMP/cut.sh"
  run grep -c 'openfga-preshared-key) *b=$(( w + RESTART_WAIT_S )) ;;' "$TMP/cut.sh"
  [ "$output" -eq 1 ]
  fga_slow "$TMP/cut.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run took_within openfga-preshared-key
  [ "$status" -ne 0 ]
}

# --- keyring-generated-keys --------------------------------------------------

# Each OpenBao restart, Velero restart, rollout and backup takes its whole
# limit and then succeeds. keyring.sh is a stub of the same file format.
keyring_slow() {
  src "$1" time_bound_of seal_id_of password_refused class_keyring_generated_keys
  sed -i 's#scripts/keyring.sh #keyring_sh #g' "$TMP/src.sh"
  printf 'OPENBAO_SEAL_KEY=k0\nOPENBAO_SEAL_KEY_PREVIOUS=\nVELERO_REPO_PASSWORD=p0\n' > "$TMP/keyring.env"
  echo "X=1" > "$TMP/substrate.env"
  cp "$TMP/keyring.env" "$TMP/live.env"
  run env D="$TMP" bash -c "$COMMON"'
    KEYRING_FILE="$D/keyring.env" SUBSTRATE_ENV_FILE="$D/substrate.env"
    OPENBAO_POD=gibson-openbao-0
    keyring_sh() {
      local f="$2" k="$3" cur
      case "$1" in
        get) sed -n "s/^$k=//p" "$f" ;;
        rotate) cur="$(sed -n "s/^$k=//p" "$f")"
                sed -i "s/^${k}_PREVIOUS=.*/${k}_PREVIOUS=$cur/; s/^$k=.*/$k=k$RANDOM/" "$f" ;;
        retire) sed -i "s/^${k}_PREVIOUS=.*/${k}_PREVIOUS=/" "$f" ;;
      esac
    }
    k2c() { cp "${1:-$KEYRING_FILE}" "$D/live.env"; }
    bao_ids() {
      local cur prev
      cur="$(sed -n "s/^OPENBAO_SEAL_KEY=//p" "$D/live.env")"
      prev="$(sed -n "s/^OPENBAO_SEAL_KEY_PREVIOUS=//p" "$D/live.env")"
      printf "[openbao] seal key id %s%s\n" "$(seal_id_of "$cur")" "${prev:+, previous $(seal_id_of "$prev")}"
    }
    bao_restart() { sleep $(( BAO_DELETE_WAIT_S + BAO_STATE_WAIT_S )); }
    velero_restart() { sleep "$ROLLOUT_WAIT_S"; }
    velero_backup() {
      sleep $(( VELERO_QUEUE_WAIT + VELERO_RUN_WAIT ))
      if [ -e "$D/backup1" ]; then printf Completed; else touch "$D/backup1"; printf PartiallyFailed; fi
    }
    kubectl() {
      case "$*" in
        "-n gibson rollout status statefulset/gibson-openbao --timeout="*"s") sleep "$ROLLOUT_WAIT_S" ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    . "$D/src.sh"; class_keyring_generated_keys'
}

@test "keyring-generated-keys: the slowest passing path fits its bound" {
  keyring_slow "$TEST"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run took_within keyring-generated-keys
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a keyring bound with one Velero backup is shorter than the slowest path" {
  sed 's/2 \* (VELERO_QUEUE_WAIT + VELERO_RUN_WAIT)/1 * (VELERO_QUEUE_WAIT + VELERO_RUN_WAIT)/' "$TEST" > "$TMP/cut.sh"
  run grep -c '1 \* (VELERO_QUEUE_WAIT + VELERO_RUN_WAIT)' "$TMP/cut.sh"
  [ "$output" -eq 1 ]
  keyring_slow "$TMP/cut.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run took_within keyring-generated-keys
  [ "$status" -ne 0 ]
}

# --- platform-generated-secrets ----------------------------------------------

# The slot of the System API key moves 60 s before the class deadline D, and
# Zitadel refuses the old key at D. The masterkey CronJob moves `next` at once,
# and Reloader restarts Zitadel at that moment. The session secrets work at
# once. So each loop waits up to D, and the class then runs the steps that
# come after its deadline.
gen_slow() {
  src "$1" time_bound_of rotate_masterkey class_platform_generated_secrets
  run env D="$TMP" bash -c "$COMMON"'
    DASHBOARD_SECRETS=gibson-gibson-workloads-dashboard-secrets
    DL=$(( $(now) + 2 * ROTATION_WAIT ))
    G=$(( DL - 60 ))
    echo gibson-system-bot > "$D/user"; echo old-mk-of-thirty-two-characters > "$D/mk"
    echo s0 > "$D/auth"; echo "" > "$D/prev"
    secret_value() {
      case "$1 $2" in
        "gibson-zitadel-system-key user") if [ -e "$D/slot" ] && [ "$(now)" -ge "$G" ]; then echo gibson-system-bot-b; else cat "$D/user"; fi ;;
        "gibson-zitadel-system-key private-key.pem") echo pem ;;
        "gibson-zitadel-masterkey masterkey") cat "$D/mk" ;;
        "gibson-gibson-workloads-dashboard-secrets auth-secret") cat "$D/auth" ;;
      esac
    }
    system_jwt_status() {
      if [ "$2" = gibson-system-bot ] && [ -e "$D/slot" ] && [ "$(now)" -ge "$DL" ]; then echo 401; else echo 200; fi
    }
    set_at_source() {
      case "$1 $2" in
        "gibson-zitadel-system-active slot") touch "$D/slot" ;;
        "zitadel-masterkey next") printf "%s" "${3:0:32}" > "$D/mk"; now > "$D/mk.at" ;;
        "gibson-dashboard-session-secrets auth_secret") printf "%s" "$3" > "$D/auth" ;;
        "gibson-dashboard-session-secrets auth_secret_previous") printf "%s" "$3" > "$D/prev" ;;
      esac
    }
    admin_pat_status() { echo 200; }
    zitadel_pods_after() { [ "$(cat "$D/mk.at" 2>/dev/null || echo 0)" -gt "$1" ]; }
    zitadel_marker() { echo marker; }
    mk_decrypt_text() { [ "$2" = "$(cat "$D/mk")" ] && echo gibson-zitadel-masterkey-marker-v1; }
    session_probe() {
      if [ "$1" = "$(cat "$D/auth")" ] || [ "$1" = "$(cat "$D/prev")" ]; then echo accepted; else echo refused; fi
    }
    kubectl() {
      case "$*" in
        "-n gibson rollout status deployment/gibson-zitadel --timeout="*"s") return 0 ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    . "$D/src.sh"; class_platform_generated_secrets'
}

@test "platform-generated-secrets: the slowest passing path fits its bound" {
  gen_slow "$TEST"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run took_within platform-generated-secrets
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a platform-generated-secrets bound with no settle is shorter than the slowest path" {
  sed 's/^\(    platform-generated-secrets) *b=\).*$/\1$(( 2 * w )) ;;/' "$TEST" > "$TMP/cut.sh"
  run grep -c 'platform-generated-secrets) *b=$(( 2 \* w )) ;;' "$TMP/cut.sh"
  [ "$output" -eq 1 ]
  gen_slow "$TMP/cut.sh"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run took_within platform-generated-secrets
  [ "$status" -ne 0 ]
}
