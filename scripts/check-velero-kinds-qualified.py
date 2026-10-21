#!/usr/bin/env python3
"""check-velero-kinds-qualified.py: kubectl names a Velero kind with its group
(drill run 39461957621).

The cluster holds two kinds that kubectl reads as `backup`: the Velero Backup
(backups.velero.io) and the CloudNativePG Backup (backups.postgresql.cnpg.io).
A bare `kubectl get backup NAME` reads the first group that the API server
lists, and that group is not the same on each cluster. In drill run
39461957621 the read gave no phase for a Velero Backup that the Velero server
ran, and the rotation check said that the server never picked it up.

A call of kubectl get, describe, delete, wait, edit or patch names each
backup, backups, restore and restores resource with its group, for example
backups.velero.io. A name with a dot passes.

Usage:  scripts/check-velero-kinds-qualified.py [--selftest]
Exit:   0 clean, 1 a call names a bare kind, 2 the self-test is broken or the
        scan read no file
The fixtures are in scripts/testdata/velero-kinds/.
"""
from __future__ import annotations

import pathlib
import re
import shlex
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "velero-kinds"
VERBS = {"get", "describe", "delete", "wait", "edit", "patch", "annotate", "label"}
BARE = {"backup", "backups", "restore", "restores"}
# Flags that take their value as the next word.
VALUE_FLAGS = {"-n", "--namespace", "-o", "--output", "-l", "--selector", "-f", "--filename",
               "--context", "--kubeconfig", "-c", "--container", "--timeout", "--for",
               "-p", "--patch", "--type", "--field-selector", "-L", "--label-columns"}
SCAN_DIRS = ("scripts", "test", ".github")
SUFFIXES = {".sh", ".yml", ".yaml", ".bash"}


def logical_lines(text: str):
    """Yield each line with its continuation joined, and comments cut."""
    text = re.sub(r"\\[ \t]*\n[ \t]*", " ", text)
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        yield line


def bare_kinds(line: str) -> list[str]:
    out: list[str] = []
    # A line can hold several commands: split at the shell separators, then
    # at each kubectl word.
    for seg in re.split(r"[|;&(){}`]|\$\(", line):
        if "kubectl" not in seg:
            continue
        try:
            words = shlex.split(seg, comments=False, posix=True)
        except ValueError:
            words = seg.split()
        if "kubectl" not in words:
            continue
        words = words[words.index("kubectl") + 1:]
        i = 0
        verb = None
        while i < len(words):
            w = words[i]
            if w.startswith("-"):
                i += 2 if (w in VALUE_FLAGS and "=" not in w) else 1
                continue
            if verb is None:
                if w in VERBS:
                    verb = w
                    i += 1
                    continue
                break
            # The first word after the verb is the resource list.
            for kind in w.split("/")[0].split(","):
                if kind in BARE:
                    out.append(kind)
            break
    return out


def findings(path: pathlib.Path, rel: str) -> list[str]:
    out = []
    text = path.read_text(encoding="utf-8", errors="replace")
    for line in logical_lines(text):
        for kind in bare_kinds(line):
            out.append(f"{rel}: kubectl names the bare kind {kind!r}: {line.strip()[:110]}")
    return out


def scan_files() -> list[pathlib.Path]:
    files = []
    for d in SCAN_DIRS:
        for p in sorted((ROOT / d).rglob("*")):
            if p.is_file() and p.suffix in SUFFIXES and "testdata" not in p.parts:
                files.append(p)
    return files


def selftest() -> int:
    bads = sorted(FIXTURES.glob("bad-*.sh"))
    goods = sorted(FIXTURES.glob("good-*.sh"))
    if len(bads) < 4 or len(goods) < 1:
        print("check-velero-kinds-qualified: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for b in bads:
        got = findings(b, b.name)
        if len(got) != 1:
            print(f"check-velero-kinds-qualified: selftest: {b.name} gave {got}, want one finding", file=sys.stderr)
            return 2
    for g in goods:
        got = findings(g, g.name)
        if got:
            print(f"check-velero-kinds-qualified: selftest: {g.name} gave {got}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bads)} bare kinds are refused, {len(goods)} qualified files pass")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    files = scan_files()
    if not files:
        print("check-velero-kinds-qualified: no file was read", file=sys.stderr)
        return 2
    bad = [f for p in files for f in findings(p, str(p.relative_to(ROOT)))]
    if bad:
        print("❌ kubectl must name Backup and Restore with a group (backups.velero.io):", file=sys.stderr)
        for b in bad:
            print(f"   {b}", file=sys.stderr)
        return 1
    print(f"✅ {len(files)} files name each Backup and Restore with its group")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
