#!/usr/bin/env python3
"""Guard: each tested credential class has a rotation test, and each test has a class (hosted#444).

credential-classes.yaml is the one list of credential classes. The monthly
rotation test, test/rotation/exit-test-rotation.sh, calls the function
class_<test> for each class with `status: tested`. It records the other
classes as untested.

WHAT IT CHECKS
    1. Each class has a name, a lifetime, a source, a rotation path,
       revokes_old (true or false), a status and a test. No two classes
       share a name. The status is tested, no-test or no-rotation-path.
    2. A class with status tested names a test, and the script has the
       function class_<test> (dashes become underscores).
    3. A class with another status has `test: none` and a `gap` that says why
       no test proves it.
    4. Each class_* function of the script belongs to a tested class. A
       function that no tested class names never runs, and it reads as
       coverage.

Usage:
    scripts/check-rotation-classes.py             # the guard
    scripts/check-rotation-classes.py --selftest  # prove that it can fail
Exit: 0 clean · 1 the list and the test differ · 2 the self-test is broken

The fixtures are in tests/guards/rotation-classes/.
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "guards" / "rotation-classes"
LIST = "credential-classes.yaml"
SCRIPT = "exit-test-rotation.sh"
FIELDS = ("name", "lifetime", "source", "rotation", "revokes_old", "status", "test")
STATUSES = ("tested", "no-test", "no-rotation-path")
FUNC = re.compile(r"^class_([a-z0-9_]+)\s*\(\)\s*\{", re.M)


def functions(script: pathlib.Path) -> set[str]:
    text = "\n".join(l for l in script.read_text(encoding="utf-8").splitlines()
                     if not l.lstrip().startswith("#"))
    return set(FUNC.findall(text))


def findings(classes_file: pathlib.Path, script: pathlib.Path) -> tuple[list[str], int]:
    doc = yaml.safe_load(classes_file.read_text(encoding="utf-8")) or {}
    classes = doc.get("classes") or []
    funcs = functions(script)
    bad: list[str] = []
    seen: set[str] = set()
    used: set[str] = set()
    for i, c in enumerate(classes):
        name = c.get("name") or f"entry {i + 1}"
        for f in FIELDS:
            if c.get(f) in (None, ""):
                bad.append(f"{name}: the field `{f}` is missing")
        if not isinstance(c.get("revokes_old"), bool):
            bad.append(f"{name}: revokes_old is {c.get('revokes_old')!r}, not true or false")
        if name in seen:
            bad.append(f"{name}: two classes have this name")
        seen.add(name)
        test = c.get("test")
        status = c.get("status")
        if status not in STATUSES:
            bad.append(f"{name}: status is {status!r}, not one of {', '.join(STATUSES)}")
        elif status == "tested":
            if not test or test == "none":
                bad.append(f"{name}: the class is marked tested and names no test")
            else:
                fn = str(test).replace("-", "_")
                used.add(fn)
                if fn not in funcs:
                    bad.append(f"{name}: the class is marked tested, and {SCRIPT} has no class_{fn}")
        else:
            if test != "none":
                bad.append(f"{name}: the status is {status} and the test is {test!r}, not none")
            if not str(c.get("gap") or "").strip():
                bad.append(f"{name}: the status is {status} and the class has no `gap`. Say why no test proves it")
    for fn in sorted(funcs - used):
        bad.append(f"{SCRIPT}: class_{fn} belongs to no tested class on the list, so it never runs")
    return bad, len(classes)


def selftest() -> int:
    cases = sorted(p for p in FIXTURES.iterdir() if p.is_dir())
    bads = [p for p in cases if p.name.startswith("bad-")]
    good = FIXTURES / "good"
    if len(bads) < 7 or not good.is_dir():
        print("check-rotation-classes: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for case in bads:
        got, _ = findings(case / LIST, case / SCRIPT)
        if len(got) != 1:
            print(f"check-rotation-classes: selftest: {case.name} gave {got}, want one finding", file=sys.stderr)
            return 2
    got, n = findings(good / LIST, good / SCRIPT)
    if got or n < 2:
        print(f"check-rotation-classes: selftest: the good fixture gave {got} ({n} classes)", file=sys.stderr)
        return 2
    print(f"✅ self-test: {len(bads)} lists that differ from the test are each rejected, the good list passes")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    script = ROOT / "test" / "rotation" / SCRIPT
    bad, n = findings(ROOT / LIST, script)
    tested = len(functions(script))
    if n < 2 or tested < 1:
        print(f"check-rotation-classes: {n} classes and {tested} tests were found, so the scan read nothing",
              file=sys.stderr)
        return 1
    if bad:
        print("check-rotation-classes: the credential class list and the rotation test differ (hosted#444):",
              file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        return 1
    print(f"✅ {n} credential classes, {tested} tested, each with a rotation test, and each class_* function is on the list")
    return 0


if __name__ == "__main__":
    sys.exit(main())
