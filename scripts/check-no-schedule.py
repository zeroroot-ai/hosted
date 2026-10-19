#!/usr/bin/env python3
"""check-no-schedule.py: no workflow of hosted runs on a schedule.

The owner ordered it on 2026-10-19: no zeroroot-ai workflow runs on a
schedule. Each workflow runs on a push, a pull request, a merge group or a
dispatch. A `schedule:` trigger spends runner minutes on runs that nobody
asked for, and a scheduled run of an exit test or a drill changes a live
environment with no person at hand.

The guard parses the `on:` key of each file in .github/workflows/ and fails
on a `schedule` trigger in any of its three forms: a mapping key, a list item
or the one string. A comment or a step that names the word does not count.

Usage:  scripts/check-no-schedule.py [--selftest]
Exit:   0 clean, 1 a workflow has a schedule, 2 the self-test is broken or
        no workflow was read
The fixtures are in scripts/testdata/no-schedule/.
"""
from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "no-schedule"


def triggers(path: pathlib.Path) -> list[str]:
    doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    # PyYAML reads a bare `on:` key as the boolean True.
    on = doc.get("on", doc.get(True)) if isinstance(doc, dict) else None
    if isinstance(on, dict):
        return [str(k) for k in on]
    if isinstance(on, list):
        return [str(k) for k in on]
    if isinstance(on, str):
        return [on]
    return []


def offenders(paths: list[pathlib.Path]) -> list[str]:
    return [str(p) for p in paths if "schedule" in triggers(p)]


def selftest() -> int:
    bads = sorted(FIXTURES.glob("bad-*.yml"))
    good = FIXTURES / "good.yml"
    if len(bads) < 3 or not good.is_file():
        print("check-no-schedule: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for b in bads:
        if offenders([b]) != [str(b)]:
            print(f"check-no-schedule: selftest: {b.name} was not refused", file=sys.stderr)
            return 2
    if offenders([good]):
        print("check-no-schedule: selftest: good.yml was refused", file=sys.stderr)
        return 2
    print(f"✅ self-test: {len(bads)} workflows with a schedule are refused, and one without passes")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    paths = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))
    if not paths:
        print("check-no-schedule: no workflow was read", file=sys.stderr)
        return 2
    bad = offenders(paths)
    if bad:
        print("❌ these workflows run on a schedule, and no workflow may (owner order, 2026-10-19):", file=sys.stderr)
        for b in bad:
            print(f"   {pathlib.Path(b).relative_to(ROOT)}", file=sys.stderr)
        return 1
    print(f"✅ {len(paths)} workflows, none with a schedule")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
