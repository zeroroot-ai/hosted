#!/usr/bin/env bats
#
# drill-restore.bats: a dispatched drill does the restore half that its input
# selects, and a skipped restore cannot report green (hosted#443). A drill
# runs only on dispatch (owner order, 2026-10-19).
#
# Offline. Each assertion uses `run` and `$status`.
#
# Run:
#   bats tests/harness/drill-restore.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PLAN="$REPO_ROOT/scripts/drill-plan.sh"
WF="$REPO_ROOT/.github/workflows/drill.yml"

@test "FAILING FIXTURE: a dispatch with no restore input selects the restore half" {
  run "$PLAN" workflow_dispatch "" ""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "restore=true" ]
}

@test "a dispatch follows its restore input" {
  run "$PLAN" workflow_dispatch false ""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "restore=false" ]
  run "$PLAN" workflow_dispatch true ""
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "restore=true" ]
}

@test "FAILING FIXTURE: a schedule, a push or a bad input is refused, not read as a skip" {
  run "$PLAN" schedule "" ""
  [ "$status" -eq 2 ]
  run "$PLAN" push "" ""
  [ "$status" -eq 2 ]
  run "$PLAN" workflow_dispatch maybe ""
  [ "$status" -eq 2 ]
}

@test "the workflow wires the plan, the seed, the check and the skip guard" {
  run python3 - "$WF" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
jobs = w["jobs"]
up = {s.get("id"): s for s in jobs["up"]["steps"] if s.get("id")}
assert "scripts/drill-plan.sh" in up["plan"]["run"], "the plan step does not run drill-plan.sh"
rj = jobs["restore"]
assert rj["needs"] == "up", "the restore job does not wait for the up job"
assert "needs.up.outputs.restore_planned == 'true'" in rj["if"], rj["if"]
assert "needs.up.result == 'success'" in rj["if"], rj["if"]
steps = rj["steps"]
by_id = {s.get("id"): s for s in steps if s.get("id")}
assert "restore-markers.sh seed" in by_id["seed"]["run"]
assert "restore-markers.sh check" in by_id["restore"]["run"], "the restore step checks no data"
names = [s.get("id") for s in steps]
assert names.index("seed") < names.index("restore")
guard = {s.get("id"): s for s in jobs["teardown"]["steps"] if s.get("id")}["restore-ran"]
assert "always()" in guard["if"]
assert "needs.up.outputs.restore_planned" in str(guard.get("env", {}))
assert "needs.restore.outputs.restore" in str(guard.get("env", {}))
# no step or job reads inputs.restore directly: drill-plan.sh is the one reader
for j in jobs.values():
    assert "inputs.restore" not in str(j.get("if", ""))
    for s in j.get("steps", []):
        assert "inputs.restore" not in str(s.get("if", "")), s.get("name")
PY
  [ "$status" -eq 0 ]
}

@test "FAILING FIXTURE: the restore job proves restore-settle after the marker check, and a failure fails the job" {
  run python3 - "$WF" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
steps = w["jobs"]["restore"]["steps"]
ids = [s.get("id") for s in steps]
assert "settle" in ids, "the restore job never proves restore-settle"
s = steps[ids.index("settle")]
assert ids.index("restore") < ids.index("settle"), "the probe runs before the restore"
assert s["run"].strip() == 'make with-cluster ENV="${ENV}" CMD="test/dr/settle-probe.sh"', s["run"]
assert "continue-on-error" not in s, "a failed probe must fail the job"
assert w["jobs"]["restore"]["outputs"]["settle"], "the report cannot see the probe"
assert "O_SETTLE" in w["jobs"]["teardown"]["steps"][-1]["run"], "the report has no line for the probe"
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
