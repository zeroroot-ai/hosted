#!/usr/bin/env bash
# check-edge-exit-tests-run.sh — every edge exit test runs somewhere, and the
# edge-exit-tests aggregator says which ones it cannot run.
#
# THE SHAPE THAT HID
#
# test/edge/ holds four exit-test scripts. Three run on the Docker edge harness
# and are aggregated by `make edge-exit-tests`. The
# fourth, exit-test-substrate.sh, needs a REAL cluster and a kubeconfig, so it
# cannot run on that harness and is correctly absent from the aggregator.
#
# Nothing said so. Comparing `ls test/edge/exit-test-*.sh` against the
# aggregator showed three of four, and a reader cannot tell a decision from an
# omission. That is the same ambiguity that lets a FIFTH script be added to one
# place and not the other: its own workflow but no aggregator coverage, or the
# aggregator but nothing that runs it on main.
#
# TWO ASSERTIONS
#
#   1. Every exit-test script is named by a workflow under .github/workflows/.
#      An exit test with no workflow is not an exit test (CLAUDE.md): it runs
#      only when somebody runs it by hand.
#
#   2. Every exit-test script is either in the `edge-exit-tests` aggregator, or
#      declared below as needing a cluster, with the reason. Checked in BOTH
#      directions: a declared script that IS in the aggregator fails, so the
#      declaration cannot outlive the thing it excused.
#
#   check-edge-exit-tests-run.sh             exit 1 on a script that runs nowhere
#   check-edge-exit-tests-run.sh --selftest  prove each assertion fails on a fixture
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'

# Scripts the Docker edge harness cannot run, with the reason. The aggregator is
# harness-only, so a script that needs a cluster belongs here and nowhere else.
needs_a_cluster() {
  case "$1" in
    exit-test-substrate.sh)
      echo "it asserts the Client-IP contract through the SUBSTRATE's own load balancer, which means a real cluster and a kubeconfig (kind or EKS) rather than the Docker harness — ADR-0079 Substrate proof level"
      ;;
    *) return 1 ;;
  esac
}

# judge <edge dir> <workflows dir> <makefile> — the failures, as text.
judge() {
  local edge="$1" workflows="$2" makefile="$3" s base reason agg wf out=()
  [ -d "$edge" ] || { echo "no edge test directory at ${edge}"; return 0; }
  agg="$(sed -n '/^edge-exit-tests:/,/^$/p' "$makefile" 2>/dev/null)"
  [ -n "$agg" ] || out+=("${makefile} has no edge-exit-tests target, so nothing aggregates the harness tests")

  for s in "$edge"/exit-test-*.sh; do
    [ -e "$s" ] || continue
    base="$(basename "$s")"
    wf="$(grep -rl -- "$base" "$workflows" 2>/dev/null | head -1)"
    [ -n "$wf" ] || out+=("${base} is named by no workflow under ${workflows#"$ROOT"/}: it runs only when somebody runs it by hand, so it is not an exit test")

    if reason="$(needs_a_cluster "$base")"; then
      if printf '%s' "$agg" | grep -q -- "$base"; then
        out+=("${base} is declared as needing a cluster, but the edge-exit-tests aggregator names it. One of the two is wrong — delete the declaration if the Docker harness can run it. It was declared because ${reason}")
      fi
    elif ! printf '%s' "$agg" | grep -q -- "$base"; then
      out+=("${base} is not in the edge-exit-tests aggregator, so \`make edge-exit-tests\` never runs it. Add it, or declare it in needs_a_cluster() with the reason the Docker harness cannot")
    fi
  done
  printf '%s\n' "${out[@]+"${out[@]}"}"
}

selftest() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/edge" "$tmp/wf"

  # a clean tree: one harness test, in a workflow and in the aggregator
  : > "$tmp/edge/exit-test-alpha.sh"
  echo "name: x
      run: test/edge/exit-test-alpha.sh" > "$tmp/wf/alpha.yml"
  printf 'edge-exit-tests:\n\ttest/edge/exit-test-alpha.sh\n\n' > "$tmp/Makefile"
  [ -z "$(judge "$tmp/edge" "$tmp/wf" "$tmp/Makefile")" ] \
    || { echo "SELFTEST FAIL: a script in a workflow and in the aggregator must pass"; return 1; }

  # 1. in the aggregator, in no workflow
  : > "$tmp/edge/exit-test-beta.sh"
  printf 'edge-exit-tests:\n\ttest/edge/exit-test-alpha.sh test/edge/exit-test-beta.sh\n\n' > "$tmp/Makefile"
  judge "$tmp/edge" "$tmp/wf" "$tmp/Makefile" | grep -q "exit-test-beta.sh is named by no workflow" \
    || { echo "SELFTEST FAIL: a script no workflow names must fail"; return 1; }

  # 2. in a workflow, in neither the aggregator nor the declaration
  echo "      run: test/edge/exit-test-beta.sh" >> "$tmp/wf/alpha.yml"
  printf 'edge-exit-tests:\n\ttest/edge/exit-test-alpha.sh\n\n' > "$tmp/Makefile"
  judge "$tmp/edge" "$tmp/wf" "$tmp/Makefile" | grep -q "exit-test-beta.sh is not in the edge-exit-tests aggregator" \
    || { echo "SELFTEST FAIL: a script the aggregator skips must fail"; return 1; }

  # 3. a stale declaration: declared as cluster-only AND in the aggregator
  : > "$tmp/edge/exit-test-substrate.sh"
  echo "      run: test/edge/exit-test-substrate.sh" >> "$tmp/wf/alpha.yml"
  printf 'edge-exit-tests:\n\ttest/edge/exit-test-alpha.sh test/edge/exit-test-beta.sh test/edge/exit-test-substrate.sh\n\n' > "$tmp/Makefile"
  judge "$tmp/edge" "$tmp/wf" "$tmp/Makefile" | grep -q "declared as needing a cluster, but the edge-exit-tests aggregator names it" \
    || { echo "SELFTEST FAIL: a declaration with nothing to excuse must fail"; return 1; }

  # 4. no aggregator at all
  printf 'other:\n\ttrue\n' > "$tmp/Makefile"
  judge "$tmp/edge" "$tmp/wf" "$tmp/Makefile" | grep -q "has no edge-exit-tests target" \
    || { echo "SELFTEST FAIL: a missing aggregator must fail"; return 1; }

  local live; live="$(judge "$ROOT/test/edge" "$ROOT/.github/workflows" "$ROOT/Makefile")"
  [ -z "$live" ] || { printf "SELFTEST FAIL: the tree is not clean:\n  %s\n" "$live"; return 1; }
  echo "OK: a script with no workflow, one the aggregator skips, a declaration with nothing to excuse and a missing aggregator all fail; the tree is clean"
}

case "${1:-}" in
  --selftest) selftest ;;
  *)
    bad="$(judge "$ROOT/test/edge" "$ROOT/.github/workflows" "$ROOT/Makefile")"
    if [ -n "$bad" ]; then
      printf "${RED}✗${NC} edge exit tests that run nowhere:\n" >&2
      printf '  %s\n' "$bad" >&2
      exit 1
    fi
    n=$(ls "$ROOT"/test/edge/exit-test-*.sh 2>/dev/null | wc -l)
    printf "${GREEN}✓${NC} check-edge-exit-tests-run: all %s edge exit test(s) run on main, and edge-exit-tests runs every one the Docker harness can\n" "$n"
    ;;
esac
