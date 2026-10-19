#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# drill-plan.sh — which half does this drill run do? (hosted#443, hosted#444)
#
#   drill-plan.sh <event> <restore-input> <rotation-input>
#
# Prints two lines, for $GITHUB_OUTPUT: `restore=true|false` and
# `rotation=true|false`.
#
# A DRILL RUNS ONLY ON DISPATCH (owner order of 2026-10-19: no workflow runs
# on a schedule). A dispatch follows its inputs. An empty restore input means
# true, an empty rotation input means false. Both true runs the restore half,
# then the rotation test on the restored cluster: the two halves never share
# a job, and the rotation job runs after the restore job (coordinator
# decision of 2026-10-13).
#
# Any other event is refused, so a trigger added to drill.yml by mistake
# does not run a drill with a plan nobody chose.
# ---------------------------------------------------------------------------
set -euo pipefail

EVENT="${1:-}"
RESTORE_INPUT="${2:-}"
ROTATION_INPUT="${3:-}"

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
    rotation="$(bool rotation "$ROTATION_INPUT" false)" || exit 2 ;;
  *) echo "drill-plan: the event '${EVENT}' cannot start a drill run: a drill runs only on dispatch" >&2; exit 2 ;;
esac
echo "restore=${restore}"
echo "rotation=${rotation}"
