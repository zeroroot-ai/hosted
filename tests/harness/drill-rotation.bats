#!/usr/bin/env bats
#
# drill-rotation.bats: the monthly drill run does the rotation test and no
# restore half, and a tested class that fails fails the run (hosted#444).
#
# Offline. Each assertion uses `run` and `$status`. A stub kubectl stands in
# for the cluster, so the test reaches no cluster.
#
# Run:
#   bats tests/harness/drill-rotation.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PLAN="$REPO_ROOT/scripts/drill-plan.sh"
WF="$REPO_ROOT/.github/workflows/drill.yml"
TEST="$REPO_ROOT/test/rotation/exit-test-rotation.sh"
DAILY="10 4 * * *"
MONTHLY="10 12 1 * *"

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  # Each kubectl call fails, as on a cluster that does not answer.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/kubectl"
  chmod +x "$TMP/bin/kubectl"
}

teardown() { rm -rf "$TMP"; }

# class NAME STATUS TEST [GAP]: one class entry of a list.
class() {
  printf '  - name: %s\n    lifetime: no expiry\n    source: the keyring\n    rotation: none\n' "$1"
  printf '    revokes_old: false\n    status: %s\n    test: %s\n' "$2" "$3"
  [ -z "${4:-}" ] || printf '    gap: %s\n' "$4"
}

@test "FAILING FIXTURE: the monthly schedule selects the rotation test and no restore half" {
  run "$PLAN" schedule "" 7 "" "$MONTHLY"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "restore=false" ]
  [ "${lines[1]}" = "rotation=true" ]
}

@test "the daily schedule never selects the rotation test, on Sunday too" {
  for d in 1 3 6 7; do
    run "$PLAN" schedule "" "$d" "" "$DAILY"
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "rotation=false" ]
  done
}

@test "a dispatch follows its rotation input, and a dispatch can run both halves" {
  run "$PLAN" workflow_dispatch "" 3 "" ""
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "rotation=false" ]
  run "$PLAN" workflow_dispatch "" 3 true ""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "restore=true" ]
  [ "${lines[1]}" = "rotation=true" ]
  run "$PLAN" workflow_dispatch false 3 true ""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "restore=false" ]
  [ "${lines[1]}" = "rotation=true" ]
}

@test "FAILING FIXTURE: the rotation job never runs beside the restore job, and starts the key rotation before the class test" {
  run python3 - "$WF" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
rj = w["jobs"]["rotation"]
assert sorted(rj["needs"]) == ["restore", "up"], "the rotation job can run beside the restore job"
assert "needs.restore.result == 'success' || needs.restore.result == 'skipped'" in rj["if"], rj["if"]
names = [s.get("id") for s in rj["steps"]]
assert names.index("keys-start") < names.index("rotation"), \
    "the class test rotates the seal key before substrate-rotate.sh reads the keyring from AWS"
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "an unknown schedule or a bad rotation input is refused, not read as a skip" {
  run "$PLAN" schedule "" 3 "" "0 0 * * *"
  [ "$status" -eq 2 ]
  run "$PLAN" schedule "" 3 "" ""
  [ "$status" -eq 2 ]
  run "$PLAN" workflow_dispatch "" 3 maybe ""
  [ "$status" -eq 2 ]
}

@test "drill.yml schedules exactly the two cron lines of drill-plan.sh" {
  run python3 -c '
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get("on", w.get(True))
crons = sorted(s["cron"] for s in on["schedule"])
assert crons == sorted(sys.argv[2:]), crons
' "$WF" "$DAILY" "$MONTHLY"
  [ "$status" -eq 0 ]
  run grep -c -F -x -e "DAILY=\"$DAILY\"" -e "MONTHLY=\"$MONTHLY\"" "$PLAN"
  [ "$output" = 2 ]
}

@test "FAILING FIXTURE: a tested class whose test the script does not have fails the run" {
  { echo "classes:"; class gamma-key tested gamma-key; } > "$TMP/classes.yaml"
  PATH="$TMP/bin:$PATH" run "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 1 ]
  run grep -c "$(printf '^gamma-key\tfail\t')" "$TMP/results.tsv"
  [ "$output" = 1 ]
}

@test "FAILING FIXTURE: when no Alertmanager takes the alert, the results hold a failed line for it" {
  { echo "classes:"; class gamma-key tested gamma-key; } > "$TMP/classes.yaml"
  PATH="$TMP/bin:$PATH" run "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 1 ]
  run grep -c "$(printf '^alert CredentialRotationFailed\tfail\t')" "$TMP/results.tsv"
  [ "$output" = 1 ]
}

@test "an untested class is recorded as untested and opens no failure" {
  { echo "classes:"; class beta-key no-rotation-path none "No rotation path in code."
    class gamma-key tested gamma-key; } > "$TMP/classes.yaml"
  PATH="$TMP/bin:$PATH" run "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 1 ]
  run grep -c -x "$(printf 'beta-key\tuntested\tno-rotation-path: No rotation path in code.')" "$TMP/results.tsv"
  [ "$output" = 1 ]
  run grep -c "$(printf '^beta-key\tfail')" "$TMP/results.tsv"
  [ "$output" = 0 ]
}

@test "a list with no tested class cannot run, and is not a pass" {
  { echo "classes:"; class beta-key no-rotation-path none "No rotation path in code."; } > "$TMP/classes.yaml"
  PATH="$TMP/bin:$PATH" run "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 2 ]
}

@test "a missing class list cannot run, and is not a pass" {
  PATH="$TMP/bin:$PATH" run "$TEST" "$TMP/none.yaml" "$TMP/results.tsv"
  [ "$status" -eq 2 ]
  PATH="$TMP/bin:$PATH" run "$TEST"
  [ "$status" -eq 2 ]
}

@test "the workflow wires the plan, the test, the skip guard and one issue per failed line" {
  run python3 -c '
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get("on", w.get(True))
assert "pull_request" not in on and "schedule" in on, "the drill must run on a schedule and never on a pull request"
jobs = w["jobs"]
up = {s.get("id"): s for s in jobs["up"]["steps"] if s.get("id")}
plan_env = str(up["plan"].get("env", {}))
assert "ROTATION_INPUT" in plan_env and "github.event.schedule" in plan_env, "the plan step does not pass the rotation input and the schedule"
rj = jobs["rotation"]
assert "up" in rj["needs"], "the rotation job does not wait for the up job"
assert "needs.up.outputs.rotation_planned == '"'"'true'"'"'" in rj["if"], rj["if"]
assert "needs.up.result == '"'"'success'"'"'" in rj["if"], "the rotation test runs on a cluster the smoke did not prove"
assert "needs.restore.result" in rj["if"], "the rotation test can run beside a preserve teardown"
steps = rj["steps"]
by_id = {s.get("id"): s for s in steps if s.get("id")}
assert "sha256sum -c" in by_id["rotation-tools"]["run"], "cmctl is not checked against its sha256"
rot = by_id["rotation"]
assert "test/rotation/exit-test-rotation.sh credential-classes.yaml" in rot["run"], rot["run"]
td = jobs["teardown"]
tds = {s.get("id"): s for s in td["steps"] if s.get("id")}
ran = tds["rotation-ran"]
assert "always()" in ran["if"]
assert "rotation-results.tsv" in ran["run"]
assert "needs.up.outputs.rotation_planned" in str(ran.get("env", {}))
# The teardown job reports, after the other jobs, pass or fail.
report = td["steps"][-1]
charts = [s for s in steps if s.get("name") == "Checkout charts, for baseline-set-secret.sh"][0]
assert charts["with"].get("ref") == "${{ steps.charts-tag.outputs.tag }}", "the charts checkout is not the pinned tag"
assert "env_chart_version" in by_id["charts-tag"]["run"], "the tag is not read from the drill pin"
assert "rotation-results.tsv" in report["run"] and "gh issue create" in report["run"]
assert "title=\"rotation: ${class} failed\"" in report["run"], "no issue for each failed line"
assert "[ \"$outcome\" = fail ] || continue" in report["run"], "an untested line must open no issue"
' "$WF"
  [ "$status" -eq 0 ]
}
