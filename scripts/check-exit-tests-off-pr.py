#!/usr/bin/env python3
"""check-exit-tests-off-pr.py — exit tests never run on a pull request (ADR-0080).

An exit test measures state on `main` for the launch scorecard. On a PR it is
40 minutes of cluster-shaped work that gates nothing (the merge gate is the
ten-minute set in ci.yml) and that found no defect the workstation had not
already found. This guard fails any `.github/workflows/exit-test-*.yml` whose
`on:` carries `pull_request`, and proves it can fail with --selftest.

Usage: scripts/check-exit-tests-off-pr.py            # the guard
       scripts/check-exit-tests-off-pr.py --selftest # prove it can fail
Exit:  0 clean · 1 an exit test runs on pull_request · 2 self-test broken
"""
from __future__ import annotations

import glob
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent


def offenders(paths: list[pathlib.Path]) -> list[str]:
    bad = []
    for p in paths:
        doc = yaml.safe_load(p.read_text())
        on = doc.get("on") if isinstance(doc, dict) else None
        if on is None and isinstance(doc, dict):
            on = doc.get(True)  # PyYAML parses a bare `on:` key as boolean True
        triggers = on if isinstance(on, dict) else {k: None for k in (on or [])}
        if "pull_request" in triggers or "pull_request_target" in triggers:
            bad.append(str(p.relative_to(ROOT)))
        if not any(k in triggers for k in ("push", "workflow_dispatch")):
            bad.append(f"{p.relative_to(ROOT)}: no push or dispatch trigger, so nothing would ever run it")
    return bad


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d) / "exit-test-fixture.yml"
            f.write_text("name: x\non:\n  pull_request: {}\n  push:\n    branches: [main]\njobs: {}\n")
            try:
                bad = offenders([f])
            except ValueError:
                bad = ["fixture"]
        if not bad:
            print("GUARD BROKEN: an exit test with pull_request was accepted", file=sys.stderr)
            return 2
        print("✅ self-test: an exit test carrying pull_request is rejected")
        return 0
    paths = [pathlib.Path(p) for p in sorted(glob.glob(str(ROOT / ".github/workflows/exit-test-*.yml")))]
    bad = offenders(paths)
    if bad:
        print("❌ exit tests must never run on a pull request (ADR-0080):")
        for b in bad:
            print("   ", b)
        return 1
    print(f"✅ {len(paths)} exit-test workflows run on main or dispatch only")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
