#!/usr/bin/env python3
"""check-spiffe-literal.py: no tracked file holds the SaaS trust domain as a
SPIFFE ID literal (ADR-0164, hosted#435).

WHY THIS GUARD EXISTS
---------------------
ADR-0164: each install has its own SPIFFE trust domain. One config value
names it, `global.spire.trustDomain`, and the chart builds each SPIFFE ID
from that value and a path. Before hosted#435 this repo held 18 lines with
a full SPIFFE ID in the SaaS domain: IDs in each env values file, a default in
the entitlements-svc template, a test overlay and a smoke script. Each one
is a second place that names the domain, and each one silently disagrees
with an install that uses another domain.

WHAT IT MEASURES
----------------
Every file that git tracks, except Markdown and the fixtures of this guard,
is read as text. A line that holds the spiffe scheme followed by the SaaS
domain is a failure. A comment counts too: a comment that holds a full ID is
copied into code.

Usage: scripts/check-spiffe-literal.py            # the guard
       scripts/check-spiffe-literal.py --selftest # prove it can fail
Exit:  0 no literal · 1 a literal found · 2 could not run
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = "scripts/testdata/spiffe-literal/"
FIXTURE = ROOT / FIXTURES / "literal-id.values.yaml"
# Built from two parts, so this file does not hold the literal it forbids.
LITERAL = re.compile(re.escape("spiffe://" + "zeroroot.ai"))


def tracked_files() -> list[str]:
    """Return the paths that git tracks, relative to the repo root."""
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"],
        check=True, capture_output=True,
    ).stdout.decode()
    return [p for p in out.split("\0") if p]


def audit(paths: list[str], skip_fixtures: bool = True) -> list[str]:
    """Report one line per literal, as path:line: text."""
    failures: list[str] = []
    for rel in paths:
        if rel.endswith(".md") or (skip_fixtures and rel.startswith(FIXTURES)):
            continue
        path = ROOT / rel
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if LITERAL.search(line):
                failures.append(f"{rel}:{number}: {line.strip()}")
    return failures


def selftest() -> int:
    """The fixture must fail. The guard file itself must pass."""
    fixture_rel = str(FIXTURE.relative_to(ROOT))
    hits = audit([fixture_rel], skip_fixtures=False)
    if not hits:
        print(f"selftest FAIL: the guard did not report the literal in {fixture_rel}")
        return 1
    if audit(["scripts/check-spiffe-literal.py"]):
        print("selftest FAIL: the guard reports its own source")
        return 1
    print(f"selftest ok: the guard reports {fixture_rel} ({len(hits)} line)")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(__doc__)
        return 2
    try:
        paths = tracked_files()
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"could not list the tracked files: {exc}")
        return 2
    failures = audit(paths)
    if failures:
        print("A SPIFFE ID holds the trust domain as a literal (ADR-0164).")
        print("Use global.spire.trustDomain and build the ID from it and a path:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print(f"check-spiffe-literal: no SPIFFE ID literal in {len(paths)} tracked files")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
