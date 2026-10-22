#!/usr/bin/env bats
#
# drill-budget.bats: the drill is four jobs, the teardown never depends on
# what is left of another job, and each tool and commit of a drill run is
# fixed (drill sweep rows 19, 21, 26 and 29).
#
#   - up, restore, rotation and teardown. Each one sets itself up from
#     nothing with a credential of its own (.github/actions/stage0-setup)
#   - the teardown job waits for every job, runs `always()`, and skips only
#     a run that changed nothing (hosted#470)
#   - each job stops before GitHub's 360 minutes, the credential outlives
#     each job, and the drill node's ceiling outlives the up job
#   - Argo CD tracks the commit of the run, and the summary records it and main
#   - helm, kubectl and the SSM plugin come from the pinned installer, and
#     the browser driver from the lockfile
#
# Offline. The check is one function. The FAILING FIXTURE tests feed it a
# changed copy of drill.yml and prove that it refuses each change.
#
# Run:
#   bats tests/harness/drill-budget.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
WF="$REPO_ROOT/.github/workflows/drill.yml"
TFVARS="$REPO_ROOT/bootstrap/ec2/gibson/envs/drill.tfvars"

# check MUTATION: apply the python MUTATION to the parsed drill.yml, then run
# the check. An empty MUTATION checks the committed file.
check() {
  python3 - "$WF" "$TFVARS" "$REPO_ROOT/.github/actions/stage0-setup/action.yml" "$1" <<'PY'
import re, sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
tfvars = open(sys.argv[2]).read()
setup = yaml.safe_load(open(sys.argv[3]))
exec(sys.argv[4])
jobs = w["jobs"]
td = jobs.get("teardown")
assert td is not None, "no teardown job"
work = {n: j for n, j in jobs.items() if n != "teardown"}
assert set(work) == {"up", "restore", "rotation"}, "the work jobs are not up, restore and rotation: %s" % sorted(work)
assert sorted(td.get("needs") or []) == ["restore", "rotation", "up"], "the teardown job does not wait for every job"
assert "always()" in td.get("if", ""), "the teardown job does not run after a failed job"
assert "needs.up.outputs.started != 'false'" in td.get("if", ""), "the teardown job does not skip a run that changed nothing"
for n in ("restore", "rotation"):
    needs = jobs[n].get("needs")
    needs = [needs] if isinstance(needs, str) else (needs or [])
    assert "up" in needs and "needs.up.result == 'success'" in jobs[n].get("if", ""), n + " does not wait for a green up job"
names = [s.get("name", "") for s in td["steps"]]
assert "Tear down, and ask the account what survived" in names, "the teardown step is not in the teardown job"
for n, j in work.items():
    for s in j["steps"]:
        assert "MODE=wipe" not in s.get("run", "") or s.get("name", "").startswith("From zero"), \
            "a teardown step is in the job " + n + ": " + s.get("name", "")
cred = [s for s in setup["runs"]["steps"] if "configure-aws-credentials" in s.get("uses", "")][0]
duration = int(cred["with"]["role-duration-seconds"])
ceiling = int(re.search(r"^self_terminate_after_minutes = (\d+)", tfvars, re.M).group(1))
for n, j in jobs.items():
    limit = j["timeout-minutes"]
    assert limit < 360, n + ": the job limit is not below the GitHub limit of 360 minutes"
    assert duration >= limit * 60, n + ": the credential ends before the job"
    assert any(s.get("uses") == "./.github/actions/stage0-setup" for s in j["steps"]), n + " has no credential and setup of its own"
assert ceiling > jobs["up"]["timeout-minutes"], "the drill node terminates before the up job ends"
assert jobs["up"]["outputs"]["started"], "the up job does not say whether it started"
for n in ("up", "restore"):
    assert jobs[n]["env"].get("GITOPS_REF") == "${{ github.sha }}", n + ": Argo CD of drill does not track the commit of the run"
tds = {s.get("id"): s for s in td["steps"] if s.get("id")}
assert "commits" in tds, "no step records the commits of the run"
assert "exit 1" not in tds["commits"]["run"], "the commits step fails a run; a change on main must not"
up = {s.get("id"): s for s in jobs["up"]["steps"] if s.get("id")}
assert up["up"].get("timeout-minutes"), "the recreate step has no limit"
text = (open(sys.argv[1]).read() if not sys.argv[4] else yaml.safe_dump(w)) + yaml.safe_dump(setup)
for bad in ("get-helm-3", "stable.txt", "/plugin/latest/", "npm --prefix test/signup install", "playwright install"):
    assert bad not in text, "an unpinned tool: " + bad
assert any(s.get("uses") == "./.github/actions/install-cluster-tools" for s in setup["runs"]["steps"]), "the setup does not use the pinned installer"
print("ok")
PY
}

@test "the committed drill workflow passes the check" {
  run check ""
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: no teardown job is refused" {
  run check 'w["jobs"].pop("teardown")'
  [ "$status" -ne 0 ]
  [[ "$output" == *"no teardown job"* ]]
}

@test "FAILING FIXTURE: a teardown job that skips a failed job is refused" {
  run check 'w["jobs"]["teardown"]["if"] = "${{ success() }}"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not run after a failed job"* ]]
}

@test "FAILING FIXTURE: a credential shorter than a job is refused" {
  run check '[s for s in setup["runs"]["steps"] if "configure-aws-credentials" in s.get("uses", "")][0]["with"]["role-duration-seconds"] = 14400'
  [ "$status" -ne 0 ]
  [[ "$output" == *"the credential ends before the job"* ]]
}

@test "FAILING FIXTURE: a node ceiling below the up job limit is refused" {
  run check 'tfvars = re.sub(r"self_terminate_after_minutes = [0-9]+", "self_terminate_after_minutes = 240", tfvars)'
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminates before the up job ends"* ]]
}

@test "FAILING FIXTURE: Argo CD of drill that tracks main is refused" {
  run check 'w["jobs"]["up"]["env"].pop("GITOPS_REF")'
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not track the commit of the run"* ]]
}

@test "FAILING FIXTURE: a restore job that runs after a failed up job is refused" {
  run check 'w["jobs"]["restore"]["if"] = "${{ always() }}"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"restore does not wait for a green up job"* ]]
}

@test "FAILING FIXTURE: a job over 360 minutes is refused" {
  run check 'w["jobs"]["restore"]["timeout-minutes"] = 400'
  [ "$status" -ne 0 ]
  [[ "$output" == *"restore: the job limit is not below the GitHub limit"* ]]
}

@test "FAILING FIXTURE: an unpinned kubectl is refused" {
  run check 'w["jobs"]["rotation"]["steps"].append({"run": "curl -fsSL https://dl.k8s.io/release/stable.txt"})'
  [ "$status" -ne 0 ]
  [[ "$output" == *"an unpinned tool: stable.txt"* ]]
}

@test "the commits step records the run commit and main, and never fails the run" {
  run python3 - "$WF" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
s = [s for s in w["jobs"]["teardown"]["steps"] if s.get("id") == "commits"][0]
assert "always()" in s["if"]
assert "GITHUB_STEP_SUMMARY" in s["run"] and "GITHUB_SHA" in s["run"] and "FETCH_HEAD" in s["run"]
assert "exit 1" not in s["run"] and "::error::" not in s["run"]
report = w["jobs"]["teardown"]["steps"][-1]["run"]
assert "one commit" not in report, "the report still makes a stage of the commit check"
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the EC2 recreate gives Terraform the ref of the run, in each apply" {
  run python3 - "$REPO_ROOT/scripts/recreate-ec2.sh" <<'PY'
import sys
t = open(sys.argv[1]).read()
decl = t.index('TF_ARGS+=( -var="git_revision=${GITOPS_REF}" )')
first_apply = t.index('apply -auto-approve "${TF_ARGS[@]}"')
assert decl < first_apply, "git_revision is set after the first apply"
assert t.count('apply -auto-approve "${TF_ARGS[@]}"') >= 3, "an apply does not use TF_ARGS"
assert 'GITOPS_REF="${GITOPS_REF:-main}"' in t
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: each job that runs the smoke sets up its prerequisites before it" {
  check_smoke() {
    python3 - "$1" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
for name, job in w["jobs"].items():
    steps = job["steps"]
    smoke = [i for i, s in enumerate(steps) if "prove-" in s.get("run", "")]
    if not smoke:
        continue
    pre = [i for i, s in enumerate(steps) if s.get("uses") == "./.github/actions/smoke-prereqs"]
    assert pre and pre[0] < smoke[0], f"job {name} runs the smoke with no smoke-prereqs before it"
print("ok")
PY
  }
  for wf in drill promote-staging; do
    run check_smoke "$REPO_ROOT/.github/workflows/${wf}.yml"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
  python3 -c '
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
w["jobs"]["restore"]["steps"] = [s for s in w["jobs"]["restore"]["steps"] if s.get("uses") != "./.github/actions/smoke-prereqs"]
yaml.safe_dump(w, open(sys.argv[2], "w"))' "$WF" "$BATS_TEST_TMPDIR/bad.yml"
  run check_smoke "$BATS_TEST_TMPDIR/bad.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"job restore runs the smoke with no smoke-prereqs"* ]]
}
