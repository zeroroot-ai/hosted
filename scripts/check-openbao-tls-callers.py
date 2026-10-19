#!/usr/bin/env python3
"""check-openbao-tls-callers.py: no script or test calls OpenBao over plain HTTP (hosted#536).

charts#540 made the OpenBao listener serve TLS only. The openbao container sets
BAO_ADDR=https://127.0.0.1:8200 and BAO_CACERT. A script that sets its own
BAO_ADDR=http://... replaces the TLS address, and each `bao` call then fails
against the chart. The restore drill library did that (test/dr/lib).

WHAT IT MEASURES
----------------
Each file that git tracks under test/, tests/ and scripts/, except the fixtures
of this guard, is read as text. A line fails when it sets BAO_ADDR or
VAULT_ADDR to an http:// address, or names an http:// address on the OpenBao
port 8200. A comment counts too: a comment is copied into code.

Usage: scripts/check-openbao-tls-callers.py            # the guard
       scripts/check-openbao-tls-callers.py --selftest # prove it can fail
Exit:  0 no plain-HTTP caller · 1 a caller found · 2 could not run
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIRS = ("test/", "tests/", "scripts/")
FIXTURES = "scripts/testdata/openbao-tls/"
FIXTURE = ROOT / FIXTURES / "plain-http.sh"
PLAIN = re.compile(r"(?:BAO_ADDR|VAULT_ADDR)\s*[=:]\s*[\"']?http://|http://[^\s\"'/]*:8200\b")


def tracked_files() -> list[str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", *DIRS],
                         check=True, capture_output=True).stdout.decode()
    return [p for p in out.split("\0") if p]


def audit(paths: list[str], skip_fixtures: bool = True) -> list[str]:
    failures: list[str] = []
    for rel in paths:
        if skip_fixtures and rel.startswith(FIXTURES):
            continue
        if rel == "scripts/check-openbao-tls-callers.py":
            continue
        path = ROOT / rel
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if PLAIN.search(line):
                failures.append(f"{rel}:{number}: {line.strip()}")
    return failures


def selftest() -> int:
    rel = str(FIXTURE.relative_to(ROOT))
    found = audit([rel], skip_fixtures=False)
    want = sum(1 for line in FIXTURE.read_text().splitlines() if line and not line.startswith("#"))
    if len(found) != want:
        print(f"selftest: the fixture has {want} plain-HTTP lines, the guard found {len(found)}: {found}")
        return 1
    clean = ["sh -c 'read -r T; BAO_TOKEN=\"$T\" bao status'", "BAO_ADDR=https://127.0.0.1:8200 bao status"]
    if any(PLAIN.search(line) for line in clean):
        print("selftest: a TLS call failed the guard")
        return 1
    print(f"selftest: {want} plain-HTTP lines fail, TLS calls pass")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    try:
        failures = audit(tracked_files())
    except (OSError, subprocess.CalledProcessError) as err:
        print(f"check-openbao-tls-callers: could not list files: {err}")
        return 2
    for f in failures:
        print(f"::error::{f} (OpenBao serves TLS only, charts#540: keep the container BAO_ADDR and BAO_CACERT)")
    if failures:
        return 1
    print("OK: no script or test calls OpenBao over plain HTTP")
    return 0


if __name__ == "__main__":
    sys.exit(main())
