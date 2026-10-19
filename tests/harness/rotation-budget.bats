#!/usr/bin/env bats
#
# rotation-budget.bats: the rotation test has one time budget, and no class
# starts that cannot finish in it (review of hosted#805).
#
#   - drill.yml gives the script a budget equal to the step limit less 10
#     minutes, so the two numbers cannot drift.
#   - Each tested class of credential-classes.yaml declares a time bound.
#   - The plan of the script splits the classes into as many runs as
#     ROTATION_RUNS of scripts/drill-plan.sh, and each run fits the budget.
#   - A class whose bound does not fit in the time left is not started, and
#     its line says so. A class that runs past its bound fails.
#
# Offline. A stub kubectl fails each call, as a cluster that does not answer.
# A stub date gives a clock that moves on by STEP seconds at each read. Each
# assertion uses `run` and `$status`.
#
# Run:
#   bats tests/harness/rotation-budget.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TEST="$REPO_ROOT/test/rotation/exit-test-rotation.sh"
WF="$REPO_ROOT/.github/workflows/drill.yml"
PLAN="$REPO_ROOT/scripts/drill-plan.sh"
LIST="$REPO_ROOT/credential-classes.yaml"

setup() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/kubectl"
  chmod +x "$TMP/bin/kubectl"
}
teardown() { rm -rf "$TMP"; }

# budget_of WORKFLOW: "<step limit in minutes> <ROTATION_BUDGET_S>" of the
# rotation step.
budget_of() {
  python3 - "$1" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in w["jobs"]["rotation"]["steps"] if s.get("id") == "rotation")
print(step["timeout-minutes"], (step.get("env") or {}).get("ROTATION_BUDGET_S", ""))
PY
}

# budget_matches WORKFLOW: the budget is the step limit less 10 minutes.
budget_matches() {
  local limit budget
  read -r limit budget <<< "$(budget_of "$1")"
  echo "step limit ${limit} min, budget ${budget} s"
  [ "$budget" = $(( (limit - 10) * 60 )) ]
}

@test "drill.yml gives the test a budget of the step limit less 10 minutes" {
  run budget_matches "$WF"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a step limit that changes without the budget is refused" {
  sed 's/^        timeout-minutes: 260$/        timeout-minutes: 300/' "$WF" > "$TMP/drill.yml"
  run grep -c '^        timeout-minutes: 300$' "$TMP/drill.yml"
  [ "$output" -eq 1 ]
  run budget_matches "$TMP/drill.yml"
  [ "$status" -ne 0 ]
}

# plan_src SCRIPT: the constants and time_bound_of of SCRIPT.
plan_src() {
  python3 - "$1" "$TMP/plan.sh" <<'EOPY'
import re, sys
text = open(sys.argv[1]).read()
simple = r'^[A-Z][A-Z0-9_]*=(?:\d+|"\$\{[A-Z0-9_]+:-\d+\}"|\$\(\(.*\)\))'
out = [re.match(simple, l).group(0) for l in re.findall(r'^[A-Z][A-Z0-9_]*=.*$', text, re.M)
       if re.match(simple + r'[ \t]*(?:#.*)?$', l)]
m = re.search(r"^time_bound_of\(\) \{.*?^\}\n", text, re.M | re.S)
if not m:
    sys.exit("no function time_bound_of in the script")
out.append(m.group(0))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
EOPY
}

# plan_check SCRIPT LIST BUDGET: the plan of LIST (the field `run` of each
# tested class) is whole and fits:
#   - each tested class has a bound and a run;
#   - the runs are 1 to ROTATION_RUNS of drill-plan.sh, each with a class;
#   - the bounds of each run fit BUDGET;
#   - substrate-cloud-credentials is in the run that starts the access key
#     rotation (drill.yml), so it proves the open rotation in the same job.
plan_check() {
  plan_src "$1"
  python3 - "$2" "$PLAN" "$WF" > "$TMP/runs.tsv" <<'EOPY' || return 1
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
want = int(re.search(r"^ROTATION_RUNS=(\d+)$", open(sys.argv[2]).read(), re.M).group(1))
w = yaml.safe_load(open(sys.argv[3]))
start = next(s for s in w["jobs"]["rotation"]["steps"] if s.get("id") == "keys-start")
keys_run = int(re.search(r"rotation_run == '(\d+)'", start["if"]).group(1))
print("WANT\t%d\t%d" % (want, keys_run))
for c in doc["classes"]:
    if c["status"] == "tested":
        print("%s\t%s\t%s" % (c["name"], c["test"], c.get("run") or "-"))
EOPY
  bash -c '
    set -euo pipefail
    . "$1"
    read -r _ want keys_run < <(head -n1 "$2")
    declare -A sum=()
    while IFS=$'"'"'\t'"'"' read -r name test run; do
      b="$(time_bound_of "$test")" || { echo "the tested class $name declares no time bound"; exit 1; }
      [[ "$run" =~ ^[1-9][0-9]*$ ]] || { echo "the tested class $name names no run"; exit 1; }
      [ "$run" -le "$want" ] || { echo "the class $name is in run $run, and drill-plan.sh has $want runs"; exit 1; }
      sum[$run]=$(( ${sum[$run]:-0} + b ))
      if [ "$name" = substrate-cloud-credentials ] && [ "$run" != "$keys_run" ]; then
        echo "substrate-cloud-credentials is in run $run, and run $keys_run starts the access key rotation"; exit 1
      fi
    done < <(tail -n +2 "$2")
    for r in $(seq 1 "$want"); do
      [ -n "${sum[$r]:-}" ] || { echo "run $r of drill-plan.sh has no class"; exit 1; }
      [ "${sum[$r]}" -le "$3" ] || { echo "run $r needs ${sum[$r]} s, more than $3 s"; exit 1; }
      echo "run $r: ${sum[$r]} s of $3 s"
    done' _ "$TMP/plan.sh" "$TMP/runs.tsv" "$3"
}

@test "the plan of credential-classes.yaml is whole, has the runs of drill-plan.sh, and each run fits the budget" {
  read -r _ budget <<< "$(budget_of "$WF")"
  run plan_check "$TEST" "$LIST" "$budget"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"run 3: "* ]]
}

# moved LIST CLASS RUN: LIST with CLASS in RUN.
moved() {
  python3 - "$1" "$2" "$3" <<'EOPY'
import re, sys
text = open(sys.argv[1]).read()
pat = r"(  - name: %s\n(?:    [^\n]*\n)*?    run: )\d+" % re.escape(sys.argv[2])
new, n = re.subn(pat, r"\g<1>" + sys.argv[3], text, count=1)
assert n == 1, sys.argv[2]
sys.stdout.write(new)
EOPY
}

@test "FAILING FIXTURE: a run whose bounds pass the budget is refused" {
  moved "$LIST" spire-svid 1 > "$TMP/list.yaml"
  run plan_check "$TEST" "$TMP/list.yaml" 15000
  [ "$status" -ne 0 ]
  [[ "$output" == *"run 1 needs "*"more than 15000 s"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a class in a run that drill-plan.sh does not have is refused" {
  moved "$LIST" edge-tls 4 > "$TMP/list.yaml"
  run plan_check "$TEST" "$TMP/list.yaml" 15000
  [ "$status" -ne 0 ]
  [[ "$output" == *"the class edge-tls is in run 4, and drill-plan.sh has 3 runs"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: substrate-cloud-credentials outside the run that starts the key rotation is refused" {
  moved "$LIST" substrate-cloud-credentials 2 > "$TMP/list.yaml"
  run plan_check "$TEST" "$TMP/list.yaml" 15000
  [ "$status" -ne 0 ]
  [[ "$output" == *"substrate-cloud-credentials is in run 2, and run 1 starts the access key rotation"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a tested class with no bound is refused by the check" {
  sed '/^    neo4j-password) /d' "$TEST" > "$TMP/nobound.sh"
  run plan_check "$TMP/nobound.sh" "$LIST" 15000
  [ "$status" -ne 0 ]
  [[ "$output" == *"the tested class neo4j-password declares no time bound"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: the script refuses to start when a run of the list does not fit the budget" {
  moved "$LIST" spire-svid 1 > "$TMP/list.yaml"
  PATH="$TMP/bin:$PATH" ROTATION_BUDGET_S=15000 ROTATION_RUN=2 run "$TEST" "$TMP/list.yaml" "$TMP/results.tsv"
  [ "$status" -eq 2 ]
  [[ "$output" == *"the classes of run 1 in "*"more than the budget of 15000 s"* ]] || { echo "$output"; false; }
}

# --- the runner --------------------------------------------------------------

# list CLASS[:RUN]...: a class list of tested classes, each with its own test,
# in RUN (default 1).
list() {
  echo "classes:"
  for c in "$@"; do
    printf '  - name: %s\n    lifetime: no expiry\n    source: the keyring\n    rotation: none\n' "${c%%:*}"
    printf '    revokes_old: false\n    status: tested\n    test: %s\n' "${c%%:*}"
    case "$c" in *:-) ;; *:*) printf '    run: %s\n' "${c##*:}" ;; *) printf '    run: 1\n' ;; esac
  done
}

# fake_date STEP: a date whose `+%s` moves on by STEP at each read.
fake_date() {
  echo 100000 > "$TMP/clock"
  cat > "$TMP/bin/date" <<SH
#!/usr/bin/env bash
if [ "\$*" = "+%s" ]; then
  n="\$(cat "$TMP/clock")"; echo \$(( n + $1 )) > "$TMP/clock"; echo "\$n"
else
  exec /bin/date "\$@"
fi
SH
  chmod +x "$TMP/bin/date"
}

@test "FAILING FIXTURE: a class whose bound does not fit in the time left is not started, and its line still opens an issue" {
  list neo4j-password > "$TMP/classes.yaml"
  # The first read of the clock is the start. Each later read is 20000 s on,
  # past the budget.
  fake_date 20000
  PATH="$TMP/bin:$PATH" ROTATION_BUDGET_S=15000 ROTATION_RUN=1 run "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 1 ]
  run grep -c "$(printf '^neo4j-password\tfail\tnot started: ')" "$TMP/results.tsv"
  [ "$output" -eq 1 ] || { cat "$TMP/results.tsv"; false; }
}

@test "FAILING FIXTURE: a class that runs past its declared bound fails with that reason" {
  list neo4j-password > "$TMP/classes.yaml"
  fake_date 400
  PATH="$TMP/bin:$PATH" ROTATION_BUDGET_S=15000 ROTATION_RUN=1 run "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 1 ]
  run grep -c "past its declared bound of 300 s" "$TMP/results.tsv"
  [ "$output" -eq 1 ] || { cat "$TMP/results.tsv"; false; }
}

@test "a class of another run is not started, and its line names the run that tests it" {
  list neo4j-password:2 keyring-generated-keys:1 > "$TMP/classes.yaml"
  fake_date 1
  PATH="$TMP/bin:$PATH" ROTATION_BUDGET_S=15000 ROTATION_RUN=2 run "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  run grep -c "$(printf '^keyring-generated-keys\tother-run\trun 1 of 2 tests it')" "$TMP/results.tsv"
  [ "$output" -eq 1 ] || { cat "$TMP/results.tsv"; false; }
  run grep -c "$(printf '^neo4j-password\t')" "$TMP/results.tsv"
  [ "$output" -eq 1 ]
}

@test "FAILING FIXTURE: a run with no budget or no run number cannot start" {
  list neo4j-password > "$TMP/classes.yaml"
  PATH="$TMP/bin:$PATH" ROTATION_RUN=1 run env -u ROTATION_BUDGET_S "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 2 ]
  PATH="$TMP/bin:$PATH" ROTATION_BUDGET_S=15000 run env -u ROTATION_RUN "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 2 ]
  PATH="$TMP/bin:$PATH" ROTATION_BUDGET_S=15000 ROTATION_RUN=2 run "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 2 ]
  [[ "$output" == *"the plan has 1 runs"* ]]
}

@test "FAILING FIXTURE: a class with a test and no bound is not started, and its line says why" {
  # The copy sits where the script sits, so it finds scripts/lib.
  mkdir -p "$TMP/tree/test/rotation"
  ln -s "$REPO_ROOT/scripts" "$TMP/tree/scripts"
  sed '/^    neo4j-password) /d' "$TEST" > "$TMP/tree/test/rotation/nobound.sh"
  chmod +x "$TMP/tree/test/rotation/nobound.sh"
  list neo4j-password > "$TMP/classes.yaml"
  cd "$REPO_ROOT"
  PATH="$TMP/bin:$PATH" ROTATION_BUDGET_S=15000 ROTATION_RUN=1 run "$TMP/tree/test/rotation/nobound.sh" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 1 ]
  run grep -c "$(printf '^neo4j-password\tfail\tnot started: the class declares no time bound')" "$TMP/results.tsv"
  [ "$output" -eq 1 ] || { cat "$TMP/results.tsv"; false; }
}

# redis_class WAIT: the redis class up to its wait, with redis_rotation_wait
# giving WAIT seconds.
redis_class() {
  python3 - "$TEST" "$TMP/redis.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
out = [re.search(r"^REDIS_TICK_S=.*$", text, re.M).group(0), re.search(r"^REDIS_WAIT_MAX_S=.*$", text, re.M).group(0)]
m = re.search(r"^class_redis_password\(\) \{.*?^\}\n", text, re.M | re.S)
out.append(m.group(0))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY
  mkdir -p "$TMP/charts/scripts"; printf '#!/bin/sh\n' > "$TMP/charts/scripts/baseline-set-secret.sh"
  chmod +x "$TMP/charts/scripts/baseline-set-secret.sh"
  run env D="$TMP" WAIT="$1" bash -c '
    NS=gibson RELEASE=gibson CHARTS_ROOT="$D/charts"
    miss() { echo "miss: $*"; return 1; }
    kubectl() {
      case "$*" in
        "-n gibson get externalsecrets -o json") echo "{\"items\":[{\"metadata\":{\"name\":\"gibson-redis-stack\"},\"spec\":{\"data\":[{\"remoteRef\":{\"key\":\"gibson-redis-password\"}}]}}]}" ;;
        "-n gibson get externalsecret gibson-redis-stack -o jsonpath={.spec.target.name}") echo gibson-redis-stack ;;
        "-n gibson get secret gibson-redis-rotation-state") return 0 ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    redis_rotation_wait() { echo "$WAIT"; }
    . "$1"; class_redis_password' _ "$TMP/redis.sh"
}

@test "FAILING FIXTURE: a redis rotation that may take longer than the bound allows is refused before the class writes" {
  redis_class 2500
  [ "$status" -ne 0 ]
  [[ "$output" == *"a rotation may take 2500s, past the 1980s of the time bound of the class"* ]] || { echo "$output"; false; }
}

# --- the run count in each copy (review of hosted#807) -----------------------

# runs_agree WORKFLOW PLAN_SCRIPT: ROTATION_RUNS of PLAN_SCRIPT is the count
# of each copy of the run list: the dispatch options of WORKFLOW, and the
# runs that PLAN_SCRIPT accepts. The rotation step name carries the run
# number. A drill runs only on dispatch, so no cron line holds a run.
runs_agree() {
  python3 - "$1" "$2" <<'EOPY'
import re, subprocess, sys, yaml
wf_path, plan_path = sys.argv[1:]
plan = open(plan_path).read()
want = int(re.search(r"^ROTATION_RUNS=(\d+)$", plan, re.M).group(1))
runs = [str(k) for k in range(1, want + 1)]
bad = []
w = yaml.safe_load(open(wf_path))
on = w.get("on", w.get(True))
opts = on["workflow_dispatch"]["inputs"]["rotation_run"]["options"]
if [str(o) for o in opts] != runs:
    bad.append(f"the dispatch input rotation_run offers {opts}, not {runs}")
for k in runs + [str(want + 1)]:
    r = subprocess.run(["bash", plan_path, "workflow_dispatch", "", "true", k], capture_output=True, text=True)
    ok = r.returncode == 0 and f"rotation_run={k}" in r.stdout
    if (k in runs) != ok:
        bad.append(f"drill-plan.sh {'refuses' if k in runs else 'accepts'} the rotation run {k}")
step = next(s for s in w["jobs"]["rotation"]["steps"] if s.get("id") == "rotation")
if "${{ needs.up.outputs.rotation_run }}" not in step["name"]:
    bad.append(f"the rotation step is named {step['name']!r}, with no run number")
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
EOPY
}

@test "each copy of the run list has ROTATION_RUNS entries" {
  run runs_agree "$WF" "$PLAN"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a dispatch option that is missing is refused" {
  sed 's/options: \["1", "2", "3"\]/options: ["1", "2"]/' "$WF" > "$TMP/drill.yml"
  run grep -c 'options: \["1", "2", "3"\]' "$TMP/drill.yml"
  [ "$output" -eq 0 ]
  run runs_agree "$TMP/drill.yml" "$PLAN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the dispatch input rotation_run offers"* ]]
}

@test "FAILING FIXTURE: a ROTATION_RUNS with no dispatch option is refused" {
  sed 's/^ROTATION_RUNS=3$/ROTATION_RUNS=4/' "$PLAN" > "$TMP/plan.sh"
  run runs_agree "$WF" "$TMP/plan.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the dispatch input rotation_run offers"* ]]
}

@test "FAILING FIXTURE: a rotation step name with no run number is refused" {
  sed 's/- name: Rotate the classes of rotation run .*/- name: Rotate each credential class, and prove its path/' "$WF" > "$TMP/drill.yml"
  run runs_agree "$TMP/drill.yml" "$PLAN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"with no run number"* ]]
}

# --- the postgres rollout counts against the class deadline ------------------

# pg_run SCRIPT ROTATION_WAIT: class_postgres_role_passwords of SCRIPT up to
# the first rollout, which the stub records and fails. The class deadline is
# 2 x ROTATION_WAIT after the start of a fake clock that does not move.
pg_run() {
  python3 - "$1" "$TMP/pg.sh" <<'EOPY'
import re, sys
text = open(sys.argv[1]).read()
out = [re.search(r'^POSTGRES_LOGINS="[^"]*"\n', text, re.M).group(0),
       re.search(r"^PG_ROLLOUT_S=\d+", text, re.M).group(0),
       re.search(r"^class_postgres_role_passwords\(\) \{.*?^\}\n", text, re.M | re.S).group(0)]
open(sys.argv[2], "w").write("\n".join(out) + "\n")
EOPY
  echo 100000 > "$TMP/clock"; : > "$TMP/rollout"
  run env D="$TMP" W="$2" bash -c '
    NS=gibson ROTATION_WAIT="$W"
    date() { if [ "${1:-}" = +%s ]; then cat "$D/clock"; else command date "$@"; fi; }
    sleep() { echo $(( $(cat "$D/clock") + $1 )) > "$D/clock"; }
    ok() { echo "ok: $*"; }
    miss() { echo "miss: $*"; return 1; }
    secret_value() { if [ -e "$D/forced.$1" ]; then echo "v-new-$1"; else echo "v-old-$1"; fi; }
    pg_su() { echo 1; }
    kubectl() {
      case "$*" in
        "-n gibson annotate externalsecret "*" force-sync="*" --overwrite") touch "$D/forced.$5"; return 0 ;;
        "-n gibson rollout status deployment/gibson-dashboard --timeout="*) printf "%s\n" "$*" | sed "s/.*--timeout=//" > "$D/rollout"; return 1 ;;
        *) echo "kubectl stub: undeclared call: $*" >&2; return 1 ;;
      esac
    }
    . "$1"; class_postgres_role_passwords' _ "$TMP/pg.sh"
}

@test "a postgres rollout with less of the class deadline left than PG_ROLLOUT_S gets only the time left" {
  pg_run "$TEST" 50
  [ "$status" -ne 0 ]
  [ "$(cat "$TMP/rollout")" = "100s" ] || { echo "$output"; cat "$TMP/rollout"; false; }
}

@test "FAILING FIXTURE: with no cap, the rollout gets PG_ROLLOUT_S and runs past the class deadline" {
  python3 - "$TEST" "$TMP/nocap.sh" <<'EOPY'
import sys
text = open(sys.argv[1]).read()
cap = '      [ "$left" -le "$PG_ROLLOUT_S" ] || left="$PG_ROLLOUT_S"\n'
if cap not in text:
    sys.exit("the cap of the postgres rollout is not in the script")
open(sys.argv[2], "w").write(text.replace(cap, '      left="$PG_ROLLOUT_S"\n', 1))
EOPY
  pg_run "$TMP/nocap.sh" 50
  [ "$(cat "$TMP/rollout")" = "600s" ]
  run test "$(cat "$TMP/rollout")" = "100s"
  [ "$status" -ne 0 ]
}

@test "with more of the deadline left than PG_ROLLOUT_S, the rollout gets PG_ROLLOUT_S" {
  pg_run "$TEST" 1500
  [ "$(cat "$TMP/rollout")" = "600s" ] || { echo "$output"; cat "$TMP/rollout"; false; }
}

@test "FAILING FIXTURE: a tested class that names no run is not started in run 1, and its line says why" {
  list neo4j-password:- > "$TMP/classes.yaml"
  PATH="$TMP/bin:$PATH" ROTATION_BUDGET_S=15000 ROTATION_RUN=1 run "$TEST" "$TMP/classes.yaml" "$TMP/results.tsv"
  [ "$status" -eq 1 ]
  run grep -c "$(printf '^neo4j-password\tfail\tnot started: the class names no run')" "$TMP/results.tsv"
  [ "$output" -eq 1 ] || { cat "$TMP/results.tsv"; false; }
}
