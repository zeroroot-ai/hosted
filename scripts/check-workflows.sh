#!/usr/bin/env bash
# check-workflows.sh — the workflow files are valid before they are merged.
#
# WHY THIS EXISTS
#
# A workflow whose EXPRESSIONS are wrong is not rejected when it is written,
# when it is reviewed, or when the merge gate runs. It is rejected by GitHub
# at dispatch time, and the run then reports `failure` with ZERO jobs and no
# log to open. There is nothing to read and nothing to click.
#
# exit-test-published-install.yml shipped that way. Its job-level env block
# said
#
#     SUBSTRATE_DIR: ${{ runner.temp }}/substrate
#
# and the `runner` context does not exist at job level — it is a step-level
# context. Runs 34997930023 and 34998499549 both failed instantly with no
# jobs. The file had lived as a draft PR for days, and a draft never runs on
# main, so nothing had ever evaluated it. The first evaluation was the merge.
#
# actionlint names it exactly:
#
#     context "runner" is not allowed here. available contexts are "github",
#     "inputs", "matrix", "needs", "secrets", "strategy", "vars".
#
# A whole class of workflow defects has that shape: valid YAML, invalid
# workflow. YAML parsing cannot see any of it, which is why this runs a real
# workflow linter rather than another hand-written check.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v actionlint >/dev/null 2>&1; then
  echo "✗ check-workflows: actionlint is not on PATH." >&2
  echo "  Install it (https://github.com/rhysd/actionlint) — this guard must not" >&2
  echo "  silently skip, because the defect it catches is invisible everywhere else." >&2
  exit 2
fi

# --- failing fixture -------------------------------------------------------
# The exact shape that shipped. It runs on every invocation, because a guard
# that cannot fail is worse than no guard — and this one guards a defect whose
# only symptom is a run with no logs.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.github/workflows"
git -C "$WORK" init -q .
cat > "$WORK/.github/workflows/fixture.yml" <<'FIXTURE'
name: fixture
on:
  push:
    branches: [main]
jobs:
  job:
    runs-on: ubuntu-latest
    env:
      # `runner` is a step-level context. Naming it here is rejected at
      # dispatch, with no jobs and no log.
      SOMEWHERE: ${{ runner.temp }}/x
    steps:
      - run: echo "$SOMEWHERE"
FIXTURE
if (cd "$WORK" && actionlint .github/workflows/fixture.yml >"$WORK/out" 2>&1); then
  echo "✗ check-workflows self-test: actionlint accepted a job-level \${{ runner.temp }}, so it would not have caught the defect this guard exists for" >&2
  exit 2
fi
grep -q 'context "runner" is not allowed here' "$WORK/out" || {
  echo "✗ check-workflows self-test: actionlint rejected the fixture for the wrong reason:" >&2
  sed 's/^/      /' "$WORK/out" >&2
  exit 2
}
echo "✅ self-test: a job-level \${{ runner.temp }} is rejected, the way it should have been before it merged"

# --- the check -------------------------------------------------------------
cd "$ROOT"
n=$(find .github/workflows -name '*.yml' -o -name '*.yaml' 2>/dev/null | wc -l)
if ! actionlint; then
  echo "  A workflow that fails this is rejected by GitHub at dispatch: the run" >&2
  echo "  reports failure with no jobs and no log, so it must be caught here." >&2
  exit 1
fi
printf '✅ check-workflows: %d workflow file(s) are valid\n' "$n"
