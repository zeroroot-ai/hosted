#!/usr/bin/env python3
"""check-rotation-writeback.py: the keyring write-back of rotate-credentials.yml
runs on any end of the job (ADR-0083, amendment of 2026-10-21).

The cluster may hold the new keyring before the job ends. The environment must
then hold it too, also after a cancel, a timeout or a failed step between the
Rotate step and the write-back. So:

  1. The steps "Decide the write-back" and "Write the keyring and
     substrate.env back to the environment" exist and their `if` holds
     always().
  2. The deciding step tests the marker file .cluster-keyring-pushed on the
     disk, with `-e`.
  3. No `if` of these steps reads steps.rotate.outputs. A step output is not
     there after a cancel or a timeout.
  4. The Result step has always(), so a failed job still says what happened.

Usage: scripts/check-rotation-writeback.py [--selftest]
Exit:  0 clean, 1 a rule is broken, 2 the self-test is broken
The fixtures are in scripts/testdata/rotation-writeback/.
"""
from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/rotate-credentials.yml"
FIXTURES = ROOT / "scripts/testdata/rotation-writeback"
DECIDE = "Decide the write-back"
WRITE_STEPS = (DECIDE, "Write the keyring and substrate.env back to the environment")
MARKER = ".cluster-keyring-pushed"


def problems(doc: dict) -> list[str]:
    bad: list[str] = []
    steps = [s for j in (doc.get("jobs") or {}).values() for s in (j.get("steps") or [])]
    by_name = {s.get("name"): s for s in steps if isinstance(s, dict)}
    for name in WRITE_STEPS + ("Result",):
        step = by_name.get(name)
        if step is None:
            bad.append(f"no step named '{name}'")
            continue
        cond = str(step.get("if", ""))
        if "always()" not in cond:
            bad.append(f"step '{name}' has no always() in its `if`, so a cancel or a failed step before it skips it")
        if name in WRITE_STEPS and "steps.rotate.outputs" in cond:
            bad.append(f"step '{name}' reads steps.rotate.outputs in its `if`: the output is missing after a cancel or a timeout")
    decide = by_name.get(DECIDE)
    if decide is not None:
        run = str(decide.get("run", ""))
        if f"-e \"$state/{MARKER}\"" not in run and f"-e \"${{state}}/{MARKER}\"" not in run:
            bad.append(f"step '{DECIDE}' does not test the file {MARKER} on the disk with -e")
    return bad


def load(path: pathlib.Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def selftest() -> int:
    good = sorted(FIXTURES.glob("good-*.yml"))
    bads = sorted(FIXTURES.glob("bad-*.yml"))
    if not good or len(bads) < 5:
        print("check-rotation-writeback: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for g in good:
        if problems(load(g)):
            print(f"check-rotation-writeback: selftest: {g.name} gave {problems(load(g))}", file=sys.stderr)
            return 2
    for b in bads:
        if not problems(load(b)):
            print(f"check-rotation-writeback: selftest: {b.name} was accepted", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bads)} broken write-backs are refused, {len(good)} passes")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    bad = problems(load(WORKFLOW))
    if bad:
        print("❌ the keyring write-back of rotate-credentials.yml can be skipped:", file=sys.stderr)
        for b in bad:
            print(f"   {b}", file=sys.stderr)
        return 1
    print("✅ the keyring write-back of rotate-credentials.yml runs on any end of the job, and reads the marker from the disk")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
