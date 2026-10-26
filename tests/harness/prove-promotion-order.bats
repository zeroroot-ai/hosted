#!/usr/bin/env bats
#
# prove-promotion-order.bats: the promotion proof waits until the promotion
# lands before the smoke (run 39137283280 signed up during the rollout of the
# new chart, and failed on a promotion that was fine).
#
# Offline. kubectl, the landed check and prove-bringup.sh are stubs. Each
# stub writes one line to a log, so the test reads the order of the steps.
#
# Run:
#   bats tests/harness/prove-promotion-order.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  TMP="$(mktemp -d)"; export TMP
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  # STUB_ANNOTATE_FAILS: the first N annotates fail, as a dropped SSM forward.
  "-n argocd annotate application/gibson argocd.argoproj.io/refresh=hard --overwrite")
    a=$(( $(cat "$TMP/annotates" 2>/dev/null || echo 0) + 1 )); echo "$a" > "$TMP/annotates"
    [ "$a" -gt "${STUB_ANNOTATE_FAILS:-0}" ] || { echo "error: lost connection to pod" >&2; exit 1; } ;;
  "-n argocd get application/gibson -o jsonpath={.metadata.annotations.argocd\.argoproj\.io/refresh}") exit 0 ;;
  # The live spec pins the old chart for STUB_OLD_PIN_READS reads, then the
  # new one (the app-of-apps copies the pin on its git poll).
  "-n argocd get application/gibson -o json")
    n=$(( $(cat "$TMP/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/reads"
    v=0.151.0; [ "$n" -gt "${STUB_OLD_PIN_READS:-0}" ] || v=0.150.0
    # STUB_OLD_PIN_AFTER: from this read on, the old pin again.
    [ -z "${STUB_OLD_PIN_AFTER:-}" ] || [ "$n" -lt "$STUB_OLD_PIN_AFTER" ] || v=0.150.0
    # STUB_D91: the live source carries the recovery parameters of a restore.
    h='"helm":{"parameters":[]}'
    [ -z "${STUB_D91:-}" ] || h='"helm":{"parameters":[{"name":"platformPostgres.recovery.backupID","value":"x"}]}'
    printf '{"spec":{"sources":[{"repoURL":"ghcr.io/zeroroot-ai/charts","chart":"gibson","targetRevision":"%s",%s},{"repoURL":"https://github.com/zeroroot-ai/hosted","ref":"values"}]}}' "$v" "$h" ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  # The landed check fails STUB_LAND_FAILS times, then passes.
  cat > "$TMP/landed" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$TMP/landed.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/landed.calls"
if [ "${STUB_LAND_FAILS}" = always ] || [ "$n" -le "${STUB_LAND_FAILS:-0}" ]; then
  echo "landed-fail" >> "$TMP/order"; echo "operation at a stale revision"; exit 1
fi
echo "landed-ok" >> "$TMP/order"; echo "promotion landed"
SH
  printf '#!/usr/bin/env bash\necho smoke >> "$TMP/order"\n' > "$TMP/bringup"
  chmod +x "$TMP/bin/kubectl" "$TMP/landed" "$TMP/bringup"
}

teardown() { rm -rf "$TMP"; }

run_prove() {
  run env PATH="$TMP/bin:$PATH" PROVE_BRINGUP="$TMP/bringup" LANDED_CHECK="$TMP/landed" \
    LAND_POLL=0 LAND_WAIT="${LAND_WAIT:-60}" APP=gibson CHART_VERSION=0.151.0 \
    bash "$REPO_ROOT/scripts/prove-promotion.sh" drill
}

@test "the smoke runs only after the promotion landed, and the landed check runs once more after it" {
  export STUB_LAND_FAILS=2
  run_prove
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(tr '\n' ' ' < "$TMP/order")" = "landed-fail landed-fail landed-ok smoke landed-ok " ] || { cat "$TMP/order"; false; }
}

@test "FAILING FIXTURE: while the live spec still pins the old chart, the landed check does not count and the smoke waits" {
  # The landed check would pass at once on the old pin (review of 977a8fa).
  export STUB_LAND_FAILS=0 STUB_OLD_PIN_READS=2
  run_prove
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"pins '0.150.0', not 0.151.0 yet"* ]] || { echo "$output"; false; }
  [ "$(tr '\n' ' ' < "$TMP/order")" = "landed-ok smoke landed-ok " ] || { cat "$TMP/order"; false; }
  [ "$(cat "$TMP/reads")" -ge 3 ]
}

@test "FAILING FIXTURE: a live spec that never pins the version stops the proof before the smoke" {
  export STUB_LAND_FAILS=0 STUB_OLD_PIN_READS=100000 LAND_WAIT=0
  run_prove
  [ "$status" -ne 0 ]
  [[ "$output" == *"the promotion did not land within 0s"* ]] || { echo "$output"; false; }
  run grep -qx smoke "$TMP/order"
  [ "$status" -ne 0 ]
}

@test "a failed annotate inside the wait is one more poll, not the end of the proof" {
  export STUB_LAND_FAILS=0 STUB_ANNOTATE_FAILS=1
  run_prove
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"not landed yet: cannot annotate application/gibson for a hard refresh"* ]] || { echo "$output"; false; }
  [ "$(tr '\n' ' ' < "$TMP/order")" = "landed-ok smoke landed-ok " ]
}

@test "FAILING FIXTURE: a live spec that moved back to the old pin after the smoke fails the proof" {
  # Read 1 lands. The read after the smoke is read 2.
  export STUB_LAND_FAILS=0 STUB_OLD_PIN_AFTER=2
  run_prove
  [ "$status" -ne 0 ]
  [[ "$output" == *"pins '0.150.0', not 0.151.0 yet"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a manual run with no CHART_VERSION and no pin for the env is refused before any call" {
  run env PATH="$TMP/bin:$PATH" PROVE_BRINGUP="$TMP/bringup" LANDED_CHECK="$TMP/landed" \
    LAND_POLL=0 LAND_WAIT=60 APP=gibson \
    bash "$REPO_ROOT/scripts/prove-promotion.sh" no-such-env
  [ "$status" -eq 2 ]
  [[ "$output" == *"no chart version to prove"* ]] || { echo "$output"; false; }
  [ ! -e "$TMP/annotates" ]
}

@test "FAILING FIXTURE: a promotion that does not land stops the proof before the smoke" {
  export STUB_LAND_FAILS=always LAND_WAIT=0
  run_prove
  [ "$status" -ne 0 ]
  [[ "$output" == *"the promotion did not land within 0s"* ]] || { echo "$output"; false; }
  run grep -qx smoke "$TMP/order"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: live D91 recovery parameters stop the proof at once, and name restore-settle" {
  export STUB_LAND_FAILS=0 STUB_OLD_PIN_READS=100000 STUB_D91=1 LAND_WAIT=600
  run_prove
  [ "$status" -ne 0 ]
  [[ "$output" == *"carries the D91 recovery parameters"* ]] || { echo "$output"; false; }
  [[ "$output" == *"make restore-settle ENV=drill"* ]] || { echo "$output"; false; }
  # One read, no wait for the deadline.
  [ "$(cat "$TMP/reads")" -eq 1 ] || { cat "$TMP/reads"; false; }
}

@test "live D91 parameters at the pinned version do not stop the proof" {
  export STUB_LAND_FAILS=0 STUB_OLD_PIN_READS=0 STUB_D91=1
  run_prove
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

