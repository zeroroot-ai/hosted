#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# drill-plan.sh — which half does this drill run do? (hosted#443, hosted#444)
#
#   drill-plan.sh <event> <restore-input> <rotation-input> [<rotation-run-input>]
#
# Prints three lines, for $GITHUB_OUTPUT: `restore=true|false`,
# `rotation=true|false` and `rotation_run=<n>` (0 when the run does no
# rotation test).
#
# A DRILL RUNS ONLY ON DISPATCH (owner order of 2026-10-19: no workflow runs
# on a schedule). A dispatch follows its inputs. An empty restore input means
# true, an empty rotation input means false. Both true runs the restore half,
# then the rotation test on the restored cluster: the two halves never share
# a job, and the rotation job runs after the restore job (coordinator
# decision of 2026-10-13).
#
# THE ROTATION RUNS. The worst-case time of all the tested classes does not
# fit one step of drill.yml, so credential-classes.yaml splits them into
# ROTATION_RUNS runs (the field `run` of each class, review of hosted#805).
# A rotation dispatch names its run with the `rotation_run` input, 1 to
# ROTATION_RUNS; an empty input means run 1. Each run is one dispatch, so a
# person dispatches runs 1 to ROTATION_RUNS to rotate every class.
#
# Any other event is refused, so a trigger added to drill.yml by mistake
# does not run a drill with a plan nobody chose.
# ---------------------------------------------------------------------------
set -euo pipefail

EVENT="${1:-}"
RESTORE_INPUT="${2:-}"
ROTATION_INPUT="${3:-}"
RUN_INPUT="${4:-}"
# The runs of the plan in credential-classes.yaml.
# tests/harness/rotation-budget.bats fails when the plan, the dispatch options
# of drill.yml and this number disagree.
ROTATION_RUNS=3

# bool NAME VALUE DEFAULT: print true or false, or refuse a value that is
# neither.
bool() {
  case "$2" in
    '')         echo "$3" ;;
    true|false) echo "$2" ;;
    *) echo "drill-plan: the $1 input is '$2', not true or false" >&2; return 2 ;;
  esac
}

case "$EVENT" in
  workflow_dispatch)
    restore="$(bool restore "$RESTORE_INPUT" true)" || exit 2
    rotation="$(bool rotation "$ROTATION_INPUT" false)" || exit 2
    run=0
    if [ "$rotation" = true ]; then
      case "${RUN_INPUT:-1}" in
        [1-9]) [ "${RUN_INPUT:-1}" -le "$ROTATION_RUNS" ] && run="${RUN_INPUT:-1}" ;;
      esac
      [ "$run" != 0 ] || { echo "drill-plan: the rotation run input is '${RUN_INPUT}', not 1 to ${ROTATION_RUNS}" >&2; exit 2; }
    fi ;;
  *) echo "drill-plan: the event '${EVENT}' cannot start a drill run: a drill runs only on dispatch" >&2; exit 2 ;;
esac
echo "restore=${restore}"
echo "rotation=${rotation}"
echo "rotation_run=${run}"
