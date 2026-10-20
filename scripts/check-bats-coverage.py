#!/usr/bin/env python3
"""check-bats-coverage.py: each tracked bats file is run by exactly one recipe
of `make check`.

A bats file that no recipe names never runs, and nothing says so. A file that
two recipes name runs twice and costs the merge gate time it does not have.
check-verbs-a is an explicit list, and check-verbs-b is every file of
tests/harness that no other recipe names, so a new file falls into b. This
guard reads what `make -n check` would run, which holds every list, variable
and computed set at once, and counts the files of each `bats` command:

  - a tracked .bats file that no command names is refused (it never runs);
  - a tracked .bats file that more than one command names, or one command
    names twice, is refused (it runs twice, and the two halves of check-verbs
    overlap).

The fixtures of this guard under scripts/testdata/ are not counted.

Usage:  scripts/check-bats-coverage.py [--selftest]
Exit:   0 clean, 1 a file runs never or twice, 2 the self-test is broken or
        make could not list the commands
The fixtures are in scripts/testdata/bats-coverage/<case>/ (a Makefile and a
files.txt).
"""
from __future__ import annotations

import collections
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "bats-coverage"


def commands(directory: pathlib.Path) -> list[list[str]]:
    """The bats commands that `make -n check` prints, each a list of files."""
    # -o charts-vendored: the recipe of that target runs $(MAKE) even in a dry
    # run, and it needs the network. It runs no bats file.
    out = subprocess.run(["make", "-n", "-C", str(directory), "-o", "charts-vendored", "check"],
                         capture_output=True, text=True, env={**os.environ, "MAKEFLAGS": ""})
    if out.returncode != 0:
        print(f"check-bats-coverage: make -n check failed in {directory}:\n{out.stderr[-800:]}", file=sys.stderr)
        raise SystemExit(2)
    cmds = []
    for line in out.stdout.splitlines():
        words = line.split()
        if words[:1] == ["bats"]:
            cmds.append([w for w in words[1:] if w.endswith(".bats")])
    return cmds


def findings(directory: pathlib.Path, files: list[str]) -> list[str]:
    seen: collections.Counter[str] = collections.Counter()
    for cmd in commands(directory):
        for f in cmd:
            seen[f] += 1
    out = []
    for f in files:
        if seen[f] == 0:
            out.append(f"{f}: no recipe of make check runs it")
        elif seen[f] > 1:
            out.append(f"{f}: {seen[f]} commands of make check run it")
    return out


def tracked_files() -> list[str]:
    names = subprocess.run(["git", "ls-files", "*.bats"], cwd=ROOT, capture_output=True,
                           text=True, check=True).stdout.split()
    return sorted(n for n in names if not n.startswith("scripts/testdata/"))


def selftest() -> int:
    cases = sorted(p for p in FIXTURES.iterdir() if p.is_dir())
    bads = [c for c in cases if c.name.startswith("bad-")]
    goods = [c for c in cases if c.name.startswith("good-")]
    if len(bads) < 3 or len(goods) < 2:
        print("check-bats-coverage: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for c in cases:
        files = (c / "files.txt").read_text().split()
        want = (c / "expect.txt").read_text().strip() if (c / "expect.txt").exists() else ""
        got = findings(c, files)
        if c.name.startswith("bad-"):
            if not want or not any(want in g for g in got):
                print(f"check-bats-coverage: selftest: {c.name} gave {got}, none holds {want!r}", file=sys.stderr)
                return 2
        elif got:
            print(f"check-bats-coverage: selftest: {c.name} gave {got}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bads)} gaps and overlaps are refused with their message, {len(goods)} sound sets pass")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    files = tracked_files()
    if len(files) < 30:
        print("check-bats-coverage: fewer than 30 tracked bats files, so the scan read nothing", file=sys.stderr)
        return 2
    got = findings(ROOT, files)
    if got:
        print("❌ each bats file must run in exactly one recipe of make check:", *got, sep="\n   ", file=sys.stderr)
        return 1
    print(f"✅ {len(files)} bats files, each run by exactly one recipe of make check")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
