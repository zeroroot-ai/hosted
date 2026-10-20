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
test is not run by bats. A herestring (`<<<`), a shift (`$(( 1 <<x ))`) and
text inside a quoted string are not heredocs. A heredoc whose terminator never
appears is a finding, because it would hide every later line. A statement that carries `||` or `&&`, and a
condition of `if`, `while` or `until`, are not bare.

Usage:  scripts/check-bats-negation.py [--selftest]
Exit:   0 clean, 1 a bare negation, 2 the self-test is broken or no file was read
The fixtures are in scripts/testdata/bats-negation/.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "bats-negation"
# A heredoc start: `<<` or `<<-`, then a word. Not `<<<` (a herestring), not
# `$(( 1 <<x ))` (a shift), and not text inside a quoted string.
HEREDOC = re.compile(r"(?<![<$(])<<(?![<(])-?\s*\\?['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
BARE = re.compile(r"^\s*!\s+\S")


def in_quotes(line: str, pos: int) -> bool:
    """True when the character at pos sits inside a quoted string."""
    quote = ""
    i = 0
    while i < pos:
        c = line[i]
        if quote == '"' and c == "\\":
            i += 2
            continue
        if quote:
            if c == quote:
                quote = ""
        elif c in "\"'":
            quote = c
        i += 1
    return bool(quote)


def heredoc_start(line: str):
    for m in HEREDOC.finditer(line):
        before = line[: m.start()]
        if in_quotes(line, m.start()) or before.count("((") > before.count("))"):
            continue
        return m
    return None


def findings(path: pathlib.Path) -> list[str]:
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    out, i = [], 0
    while i < len(lines):
        start, logical = i + 1, lines[i]
        while logical.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            logical = logical.rstrip()[:-1] + " " + lines[i].strip()
        i += 1
        if logical.lstrip().startswith("#"):
            continue
        if BARE.match(logical) and not re.search(r"\|\||&&", logical):
            out.append(f"{path.name}:{start}: {logical.strip()[:100]}")
        m = heredoc_start(logical)
        if not m:
            continue
        # Skip the body only when its terminator line really appears. A start
        # with no terminator hides every later line, so it is a finding.
        end = next((j for j in range(i, len(lines)) if lines[j].strip() == m.group(1)), None)
        if end is None:
            out.append(f"{path.name}:{start}: a heredoc with terminator {m.group(1)} that never ends, so the scan cannot see the lines after it")
        else:
            i = end + 1
    return out


def tracked_bats() -> list[pathlib.Path]:
    """Each tracked .bats file, the fixtures of this guard excepted."""
    try:
        names = subprocess.run(["git", "ls-files", "*.bats"], cwd=ROOT, capture_output=True,
                               text=True, check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        names = [str(p.relative_to(ROOT)) for p in ROOT.rglob("*.bats")]
    return sorted(ROOT / n for n in names if not n.startswith("scripts/testdata/"))


def selftest() -> int:
    bads = sorted(FIXTURES.glob("bad-*.bats"))
    goods = sorted(FIXTURES.glob("good-*.bats"))
    if len(bads) < 5 or not goods:
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
    paths = tracked_bats()
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
