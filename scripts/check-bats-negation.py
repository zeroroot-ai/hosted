#!/usr/bin/env python3
"""check-bats-negation.py: no bats test asserts with a bare `! command`.

Bash does not stop on a failed `! command`, whatever `set -e` says. So a line
`! grep -q x file` in the middle of a bats test never fails the test. Only the
last command of the test counts. Twelve such lines read as checks and checked
nothing (hosted#12 review). The effective forms are:

    run grep -q x file
    [ "$status" -ne 0 ]

or `! command || { echo why; false; }`, which runs the handler when the
negation fails.

The scan skips the bodies of heredocs, because a stub script written by a
test is not run by bats. A statement that carries `||` or `&&`, and a
condition of `if`, `while` or `until`, are not bare.

Usage:  scripts/check-bats-negation.py [--selftest]
Exit:   0 clean, 1 a bare negation, 2 the self-test is broken or no file was read
The fixtures are in scripts/testdata/bats-negation/.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "bats-negation"
HEREDOC = re.compile(r"<<-?\s*\\?['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
BARE = re.compile(r"^\s*!\s+\S")


def findings(path: pathlib.Path) -> list[str]:
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    out, i, end = [], 0, None
    while i < len(lines):
        line = lines[i]
        if end is not None:
            if line.strip() == end:
                end = None
            i += 1
            continue
        start, logical = i + 1, line
        while logical.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            logical = logical.rstrip()[:-1] + " " + lines[i].strip()
        i += 1
        code = logical.split("#", 1)[0] if logical.lstrip().startswith("#") else logical
        if code.lstrip().startswith("#"):
            continue
        if BARE.match(code) and not re.search(r"\|\||&&", code):
            out.append(f"{path.name}:{start}: {code.strip()[:100]}")
        m = HEREDOC.search(code)
        if m:
            end = m.group(1)
    return out


def selftest() -> int:
    bads = sorted(FIXTURES.glob("bad-*.bats"))
    goods = sorted(FIXTURES.glob("good-*.bats"))
    if len(bads) < 2 or not goods:
        print("check-bats-negation: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for b in bads:
        if len(findings(b)) != 1:
            print(f"check-bats-negation: selftest: {b.name} gave {findings(b)}, want one finding", file=sys.stderr)
            return 2
    for g in goods:
        if findings(g):
            print(f"check-bats-negation: selftest: {g.name} gave {findings(g)}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bads)} bare negations are refused, {len(goods)} effective forms pass")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    paths = sorted(ROOT.glob("tests/**/*.bats")) + sorted(ROOT.glob("test/**/*.bats"))
    if len(paths) < 10:
        print("check-bats-negation: fewer than 10 bats files were read", file=sys.stderr)
        return 2
    bad = [f for p in paths for f in findings(p)]
    if bad:
        print("❌ a bare `! command` never fails a bats test. Use `run command` and check $status:", file=sys.stderr)
        for b in bad:
            print(f"   {b}", file=sys.stderr)
        return 1
    print(f"✅ {len(paths)} bats files, no bare negation")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
