#!/usr/bin/env python3
"""Fail when the newest successful `drill` run is too old (hosted#427, ADR-0095).

With --rotation, fail when the newest successful run whose rotation step
passed is too old (drill sweep row 22). The monthly rotation run is one
scheduled run of 30 or 31 days. A month with no green rotation run must open
an issue, and the daily check cannot see it: a daily green run does no
rotation.

The `drill` workflow runs each day and opens an issue for each failed stage.
When the schedule stops, no run exists and no issue opens. A `drill` that does
not run looks the same as a green `drill`. This check reads the time of the
newest successful run and fails when it is older than the limit.

Input: the JSON that this command prints, from a file or from stdin:

    gh run list --workflow drill.yml --status success --limit 5 \\
      --json databaseId,conclusion,updatedAt

With --rotation, each run also carries "rotation": the conclusion of the
step "Rotate each credential class, and prove its path" of that run, or ""
when the run has no such step. drill-watch.yml writes that field.

Usage:
    scripts/check-drill-freshness.py runs.json            # the check
    scripts/check-drill-freshness.py --rotation runs.json # the rotation check
    scripts/check-drill-freshness.py - < runs.json
    scripts/check-drill-freshness.py --selftest           # prove that it can fail
Options:
    --max-age-hours N   the limit (default 36, or 840 = 35 days with --rotation)
    --now ISO-TIME      the time to compare with (default: the current time)
Exit:
    0 a successful run is inside the limit
    1 the newest successful run is older than the limit, or no successful run exists
    2 the input cannot be read, or the self-test is broken

The fixtures are in scripts/testdata/drill-freshness/.
"""

from __future__ import annotations

import datetime as dt
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "drill-freshness"
DEFAULT_MAX_AGE_HOURS = 36
ROTATION_MAX_AGE_HOURS = 35 * 24


def parse_time(text: str) -> dt.datetime:
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))


def verdict(runs: object, now: dt.datetime, max_age_hours: float,
            rotation: bool = False) -> tuple[int, str]:
    if not isinstance(runs, list):
        return 2, "the input is not a JSON list of runs"
    what = "drill run with a passed rotation step" if rotation else "drill run"
    times = []
    for r in runs:
        if not isinstance(r, dict) or r.get("conclusion") != "success":
            continue
        if rotation and "rotation" not in r:
            return 2, f"run {r.get('databaseId')} carries no rotation field"
        if rotation and r.get("rotation") != "success":
            continue
        try:
            times.append(parse_time(str(r.get("updatedAt", ""))))
        except ValueError:
            return 2, f"a run holds a time that cannot be read: {r.get('updatedAt')!r}"
    if not times:
        return 1, f"no successful {what} exists in the input"
    newest = max(times)
    age = (now - newest).total_seconds() / 3600
    if age > max_age_hours:
        return 1, (f"the newest successful {what} ended {age:.1f} hours ago "
                   f"({newest.isoformat()}), and the limit is {max_age_hours:g} hours")
    return 0, (f"the newest successful {what} ended {age:.1f} hours ago, "
               f"inside the limit of {max_age_hours:g} hours")


def selftest() -> int:
    now = parse_time("2026-10-05T12:00:00Z")
    cases = {
        "fresh.json": 0,
        "stale.json": 1,
        "no-success.json": 1,
        "empty.json": 1,
        "not-a-list.json": 2,
    }
    for name, want in cases.items():
        f = FIXTURES / name
        if not f.is_file():
            print(f"check-drill-freshness: selftest: the fixture {name} is missing", file=sys.stderr)
            return 2
        got, why = verdict(json.loads(f.read_text()), now, DEFAULT_MAX_AGE_HOURS)
        if got != want:
            print(f"check-drill-freshness: selftest: {name} gave {got} ({why}), wanted {want}", file=sys.stderr)
            return 2
    rotation_cases = {
        "rotation-fresh.json": 0,
        "rotation-stale.json": 1,
        "rotation-none.json": 1,
        "rotation-no-field.json": 2,
    }
    for name, want in rotation_cases.items():
        f = FIXTURES / name
        if not f.is_file():
            print(f"check-drill-freshness: selftest: the fixture {name} is missing", file=sys.stderr)
            return 2
        got, why = verdict(json.loads(f.read_text()), now, ROTATION_MAX_AGE_HOURS, rotation=True)
        if got != want:
            print(f"check-drill-freshness: selftest: {name} gave {got} ({why}), wanted {want}", file=sys.stderr)
            return 2
    print("✅ self-test: a run of 37 hours ago, a list with no successful run and an empty list "
          "each fail; a run of 20 hours ago passes; an input that is not a list is refused")
    print("✅ self-test --rotation: a passed rotation of 40 days ago fails, green runs with no "
          "rotation fail, a passed rotation of 30 days ago passes, a run with no rotation field is refused")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    rotation = "--rotation" in argv
    max_age = float(ROTATION_MAX_AGE_HOURS if rotation else DEFAULT_MAX_AGE_HOURS)
    now = dt.datetime.now(dt.timezone.utc)
    paths: list[str] = []
    it = iter(argv)
    for a in it:
        if a == "--rotation":
            continue
        if a == "--max-age-hours":
            max_age = float(next(it))
        elif a == "--now":
            now = parse_time(next(it))
        else:
            paths.append(a)
    if len(paths) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        text = sys.stdin.read() if paths[0] == "-" else pathlib.Path(paths[0]).read_text()
        runs = json.loads(text)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"check-drill-freshness: the input cannot be read: {exc}", file=sys.stderr)
        return 2
    code, why = verdict(runs, now, max_age, rotation=rotation)
    print(("✅ " if code == 0 else "❌ ") + why, file=sys.stdout if code == 0 else sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
