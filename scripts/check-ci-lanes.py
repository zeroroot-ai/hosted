#!/usr/bin/env python3
"""check-ci-lanes.py: the merge gate keeps its split (hosted merge gate budget).

.github/workflows/ci.yml runs the gate in parallel jobs, and one aggregator
job, `ci-required`, gives the verdict that the ruleset requires. The aggregator
is the only check that blocks a merge, so it must not pass by accident. The
rules, on the workflow file:

  1. The workflow runs on pull_request, merge_group and push. A required check
     that never runs in one lane stalls it.
  2. The job `ci-required` exists, `needs` every other job of the workflow, and
     has `if: always()`. Without `always()` a failed job skips it, and a
     skipped required check reads as a pass in some lanes.
  3. The aggregator tests the result of each needed job, through an env value
     of `needs.<job>.result`, as `[ "$VAR" = success ]`, one test for each job,
     joined with `&&`. A `||` in the step makes one passing job enough, so it
     fails the rule. Any result but success fails: failure, skipped and
     cancelled alike.
  4. Each other job has a timeout-minutes of at most 12, so the gate stays
     inside its budget.
  5. The jobs run `make check-verbs-a`, `make check-verbs-b` and
     `make -o check-verbs check` between them, so each guard runs once.

Usage:  scripts/check-ci-lanes.py [--selftest]
Exit:   0 clean, 1 a rule breaks, 2 the self-test is broken
The fixtures are in scripts/testdata/ci-lanes/.
"""
from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "ci-lanes"
LANES = ("pull_request", "merge_group", "push")


def findings(path: pathlib.Path) -> list[str]:
    w = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    out = []
    on = w.get(True, w.get("on")) or {}  # YAML reads a bare `on` as True
    for lane in LANES:
        if lane not in on:
            out.append(f"{path.name}: the workflow does not run on {lane}")
    jobs = w.get("jobs") or {}
    agg = jobs.get("ci-required")
    if not isinstance(agg, dict):
        return out + [f"{path.name}: there is no job ci-required"]
    others = sorted(j for j in jobs if j != "ci-required")
    needs = agg.get("needs") or []
    needs = [needs] if isinstance(needs, str) else list(needs)
    for j in others:
        if j not in needs:
            out.append(f"{path.name}: ci-required does not need {j}, so it can pass while {j} fails")
    if "always()" not in str(agg.get("if", "")):
        out.append(f"{path.name}: ci-required has no `if: always()`, so a failed job skips it")
    # Which env value of the aggregator carries the result of which job.
    var_of = {}
    for name, value in (agg.get("env") or {}).items():
        m = re.search(r"needs\.([\w-]+)\.result", str(value))
        if m:
            var_of[m.group(1)] = name
    run = "\n".join(str(s.get("run", "")) for s in (agg.get("steps") or []))
    tested = set(re.findall(r'\[\s*"?\$\{?(\w+)\}?"?\s*=\s*success\s*\]', run))
    for j in others:
        if j not in var_of:
            out.append(f"{path.name}: no env value of ci-required reads needs.{j}.result")
        elif var_of[j] not in tested:
            out.append(f"{path.name}: ci-required does not test the result of {j} against success")
    if "||" in run:
        out.append(f"{path.name}: a step of ci-required joins its tests with ||, so one passing job is enough")
    for j in others:
        t = (jobs[j] or {}).get("timeout-minutes")
        if not isinstance(t, int) or t > 12:
            out.append(f"{path.name}: job {j} has timeout-minutes {t!r}, over the 12 of the gate")
    runs = "\n".join(str(s.get("run", "")) for j in others for s in ((jobs[j] or {}).get("steps") or []))
    for want in (r"make\s+check-verbs-a\b", r"make\s+check-verbs-b\b", r"make\s+-o\s+check-verbs\s+check\b"):
        if not re.search(want, runs):
            out.append(f"{path.name}: no job runs `{want}`")
    return out


def expected(path: pathlib.Path) -> str:
    """The text a finding must hold, from the first line: `# expect: text`."""
    m = re.match(r"#\s*expect:\s*(.+)$", path.read_text(encoding="utf-8").split("\n", 1)[0])
    return m.group(1).strip() if m else ""


def selftest() -> int:
    bads = sorted(FIXTURES.glob("bad-*.yml"))
    goods = sorted(FIXTURES.glob("good-*.yml"))
    if len(bads) < 8 or not goods:
        print("check-ci-lanes: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for b in bads:
        want, got = expected(b), findings(b)
        if not want:
            print(f"check-ci-lanes: selftest: {b.name} has no `# expect:` line", file=sys.stderr)
            return 2
        if not any(want in g for g in got):
            print(f"check-ci-lanes: selftest: {b.name} gave {got}, none holds {want!r}", file=sys.stderr)
            return 2
    for g in goods:
        if findings(g):
            print(f"check-ci-lanes: selftest: {g.name} gave {findings(g)}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bads)} broken gates are refused with their message, {len(goods)} sound one passes")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    got = findings(ROOT / ".github" / "workflows" / "ci.yml")
    if got:
        print("❌ the merge gate lost its split:", *got, sep="\n   ", file=sys.stderr)
        return 1
    print("✅ the merge gate runs in parallel jobs on three lanes, and ci-required needs each and passes only on success")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
