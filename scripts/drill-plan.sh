#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# drill-plan.sh — which half does this drill run do? (hosted#443, hosted#444)
#
#   drill-plan.sh <event> <restore-input> <weekday 1-7> <rotation-input> <schedule>
#
# <schedule> is github.event.schedule: the cron line that started a
# scheduled run, empty for a dispatch. Prints two lines, for
# $GITHUB_OUTPUT: `restore=true|false` and `rotation=true|false`.
#
# THE TWO HALVES NEVER SHARE A JOB OR A CLUSTER AT THE SAME TIME. The restore
# half and the rotation test each change the platform that the other one
# measures. Each has its own job in drill.yml, and the rotation job runs after
# the restore job, on the restored cluster (coordinator decision of
# 2026-10-13: one dispatch with both proves the whole release gate). The two
# schedules still select one half each.
#
# THE DAILY SCHEDULE (DAILY below): the restore half on Sunday (weekday 7),
#   and a bringup and teardown only on the other days. So the restore half
#   runs four or five times a month, and a month never passes without one
#   (owner decision of 2026-10-05: at least one time each month). It never
#   does the rotation test.
# THE MONTHLY SCHEDULE (MONTHLY below): the rotation test, and no restore
#   half (owner decision of 2026-10-05: a scheduled test proves each month
#   that a rotated credential still works end to end).
# A DISPATCH follows its inputs. An empty restore input means true, an empty
#   rotation input means false. Both true runs the restore half, then the
#   rotation test on the restored cluster.
#
# A scheduled run has no inputs, so `inputs.restore` is empty there. Before
# this script the restore step read that value, and no scheduled run ever did
# the restore half.
# ---------------------------------------------------------------------------
set -euo pipefail

# The two cron lines of drill.yml. tests/harness/drill-rotation.bats fails
# when drill.yml schedules another line.
DAILY="10 4 * * *"
MONTHLY="10 12 1 * *"

EVENT="${1:-}"
RESTORE_INPUT="${2:-}"
WEEKDAY="${3:-}"
ROTATION_INPUT="${4:-}"
SCHEDULE="${5:-}"

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
  schedule)
    case "$SCHEDULE" in
      "$DAILY")
        rotation=false
        case "$WEEKDAY" in
          7)     restore=true ;;
          [1-6]) restore=false ;;
          *) echo "drill-plan: the weekday is '${WEEKDAY}', not 1 to 7" >&2; exit 2 ;;
        esac ;;
      "$MONTHLY") restore=false; rotation=true ;;
      *) echo "drill-plan: the schedule '${SCHEDULE}' is not one of the two drill schedules" >&2; exit 2 ;;
    esac ;;
  *) echo "drill-plan: the event '${EVENT}' cannot start a drill run" >&2; exit 2 ;;
esac
echo "restore=${restore}"
echo "rotation=${rotation}"
