#!/usr/bin/env bats
#
# rotation-masterkey.bats: the masterkey half of the rotation class
# platform-generated-secrets takes its two reference points before the write
# of `next` (audit of the drill path, 2026-10-19).
#
#   - Zitadel accepts its admin PAT before the write. A check after the write
#     left a masterkey rotation running when it failed.
#   - The Zitadel restart is dated from the last read that saw the old
#     masterkey. Reloader restarts Zitadel seconds after ESO writes, before the
#     class sees the new Secret.
#
# Offline. rotate_masterkey is taken out of the script text and run with
# stubs and a fake clock (`date +%s` and `sleep`). Each assertion uses `run`
# and `$status`.
#
# Run:
#   bats tests/harness/rotation-masterkey.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TEST="$REPO_ROOT/test/rotation/exit-test-rotation.sh"

setup() { TMP="$(mktemp -d)"; }
teardown() { rm -rf "$TMP"; }

# extract SCRIPT OUT: rotate_masterkey of SCRIPT.
extract() {
  python3 - "$1" "$2" <<'PY'
import re, sys
m = re.search(r"^rotate_masterkey\(\) \{.*?^\}\n", open(sys.argv[1]).read(), re.M | re.S)
if not m:
    sys.exit("no function rotate_masterkey in the script")
open(sys.argv[2], "w").write(m.group(0))
PY
}

# mk_run SCRIPT PATS POD_DELAY: run rotate_masterkey of SCRIPT with a deadline
# 1800 s away.
#   PATS       the answers of Zitadel to the admin PAT, one per check; the
#              last one repeats.
#   POD_DELAY  seconds from the Secret change to the start of the new Zitadel
#              pod (Reloader). A negative value is a pod that started before
#              the change.
# The CronJob moves `next` to `value` 300 s after the write.
mk_run() {
  extract "$1" "$TMP/mk.sh"
  echo 1000 > "$TMP/clock"
  printf '%s\n' $2 > "$TMP/pats"
  : > "$TMP/events"
  run env D="$TMP" POD_DELAY="$3" bash -c '
    NS=gibson RELEASE=gibson
    kubectl() {
      case "$*" in
        "-n gibson rollout status deployment/gibson-zitadel --timeout="*"s")
          echo "rollout" >> "$D/events"; return "${STUB_ROLLOUT_RC:-0}" ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    date() { if [ "${1:-}" = +%s ]; then cat "$D/clock"; else command date "$@"; fi; }
    sleep() { echo $(( $(cat "$D/clock") + $1 )) > "$D/clock"; }
    now() { cat "$D/clock"; }
    ok() { echo "ok: $*"; }
    miss() { echo "miss: $*"; return 1; }
    mask() { :; }
    admin_pat_status() {
      local c; c="$(head -n1 "$D/pats")"
      [ "$(wc -l < "$D/pats")" -le 1 ] || sed -i 1d "$D/pats"
      echo "pat $c" >> "$D/events"; printf "%s" "$c"
    }
    set_at_source() { echo "set $1 $2" >> "$D/events"; printf "%s" "$3" > "$D/next"; now > "$D/written"; }
    changed_at() { [ -s "$D/written" ] && echo $(( $(cat "$D/written") + 300 )); }
    secret_value() {
      [ "$1 $2" = "gibson-zitadel-masterkey masterkey" ] || return 1
      local c; c="$(changed_at)"
      if [ -n "$c" ] && [ "$(now)" -ge "$c" ]; then head -c 32 "$D/next"; else echo "old-masterkey-of-thirty-two-char"; fi
    }
    zitadel_pods_after() {
      local c; c="$(changed_at)"
      [ -n "$c" ] && [ "$(now)" -ge $(( c + POD_DELAY )) ] && [ $(( c + POD_DELAY )) -gt "$1" ]
    }
    zitadel_marker() { echo marker; }
    mk_decrypt_text() { [ "$2" = "$(head -c 32 "$D/next")" ] && echo gibson-zitadel-masterkey-marker-v1; }
    . "$1"; rotate_masterkey $(( $(now) + 1800 ))' _ "$TMP/mk.sh"
}

@test "a Zitadel that answers late passes the PAT check before the write, and the restart Reloader made at once is found" {
  mk_run "$TEST" "000 503 200" 5
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(head -n5 "$TMP/events" | tr '\n' ' ')" = "pat 000 pat 503 pat 200 rollout set zitadel-masterkey next " ] || { cat "$TMP/events"; false; }
  [[ "$output" == *"Zitadel restarted on the new masterkey"* ]]
}

@test "FAILING FIXTURE: a Zitadel that never accepts its admin PAT fails the class, and the masterkey is never written" {
  mk_run "$TEST" "401" 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"Zitadel answers 401 to its admin PAT before the masterkey rotation, not 200"* ]] || { echo "$output"; false; }
  run grep -c '^set ' "$TMP/events"
  [ "$output" -eq 0 ]
}

@test "FAILING FIXTURE: a Zitadel pod that started before the Secret changed is not the restart" {
  mk_run "$TEST" "200" -400
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Zitadel pod is Ready that started after the new masterkey"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: dated from the read that saw the new masterkey, the restart that Reloader made at once is missed" {
  python3 - "$TEST" "$TMP/old.sh" <<'PY'
import sys
text = open(sys.argv[1]).read()
new = 'until zitadel_pods_after "$(( seen_old - 1 ))"; do'
if new not in text:
    sys.exit("rotate_masterkey does not date the restart from seen_old")
open(sys.argv[2], "w").write(text.replace(new, 'until zitadel_pods_after "$(date +%s)"; do', 1))
PY
  mk_run "$TMP/old.sh" "200" 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Zitadel pod is Ready that started after the new masterkey"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a Zitadel pod that started after the write and before the Secret changed is not the restart (review of hosted#806)" {
  mk_run "$TEST" "200" -100
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Zitadel pod is Ready that started after the new masterkey"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a Zitadel that refuses its admin PAT after the restart fails the class (review of hosted#806)" {
  mk_run "$TEST" "200 503" 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"Zitadel on the new masterkey answers 503 to its admin PAT, not 200"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a Zitadel rollout that does not finish stops the class before the write (review of hosted#806)" {
  STUB_ROLLOUT_RC=1 mk_run "$TEST" "200" 5
  [ "$status" -ne 0 ]
  [[ "$output" == *"a rollout of gibson-zitadel did not finish before the masterkey rotation"* ]] || { echo "$output"; false; }
  run grep -c '^set ' "$TMP/events"
  [ "$output" -eq 0 ]
}
