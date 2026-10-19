#!/usr/bin/env python3
"""Guard: each ToolHive operator install reads the one values file (hosted#454).

Each tenant namespace enforces the restricted Pod Security level (ADR-0165).
bootstrap/toolhive/values.yaml makes the proxy pods of ToolHive meet it. An
install that does not pass the file still succeeds, and each connector pod is
refused later, in a tenant namespace, with no link to the install.

WHAT IT CHECKS
    1. The values file sets OPERATOR_OPENSHIFT=true in operator.env.
    2. Each `helm upgrade --install toolhive-operator` command in a consumer
       passes --values "$REPO/bootstrap/toolhive/values.yaml".
    3. Each consumer holds one such command.

Usage:
    scripts/check-toolhive-install.py             # the guard
    scripts/check-toolhive-install.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 a rule is broken · 2 the self-test is broken

The fixtures are in tests/guards/toolhive-install/.
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
VALUES = ROOT / "bootstrap" / "toolhive" / "values.yaml"
FIXTURES = ROOT / "tests" / "guards" / "toolhive-install"
CONSUMERS = (
    "scripts/recreate-kind.sh",
    "scripts/lib/bringup-after-cluster.sh",
)
VALUES_ARG = '--values "$REPO/bootstrap/toolhive/values.yaml"'
INSTALL = re.compile(r"^helm upgrade --install toolhive-operator \\$", re.M)


def check_values(path: pathlib.Path) -> list[str]:
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as e:
        return [f"{path}: cannot read: {e}"]
    env = (doc.get("operator") or {}).get("env") or []
    if not isinstance(env, list):
        return [f"{path}: operator.env must be a list of name/value pairs"]
    for item in env:
        if isinstance(item, dict) and item.get("name") == "OPERATOR_OPENSHIFT" and str(item.get("value")) == "true":
            return []
    return [f"{path}: operator.env does not set OPERATOR_OPENSHIFT=true"]


def install_commands(text: str) -> list[str]:
    """Each install command, from its first line to the first line with no
    trailing backslash."""
    out = []
    for m in INSTALL.finditer(text):
        lines = []
        for line in text[m.start():].splitlines():
            lines.append(line)
            if not line.rstrip().endswith("\\"):
                break
        out.append("\n".join(lines))
    return out


def check_consumer(path: pathlib.Path, name: str) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as e:
        return [f"{name}: cannot read: {e}"]
    cmds = install_commands(text)
    if len(cmds) != 1:
        return [f"{name}: holds {len(cmds)} toolhive-operator install commands, expected 1"]
    if VALUES_ARG not in cmds[0]:
        return [f"{name}: the toolhive-operator install does not pass {VALUES_ARG}"]
    return []


def run(values: pathlib.Path, consumers: list[tuple[pathlib.Path, str]]) -> list[str]:
    errs = check_values(values)
    for path, name in consumers:
        errs += check_consumer(path, name)
    return errs


def selftest() -> int:
    good = FIXTURES / "good"
    cases = [
        ("good", run(good / "values.yaml", [(good / "install.sh", "good/install.sh")]), 0),
        ("no env", run(FIXTURES / "bad-values" / "values.yaml", [(good / "install.sh", "good/install.sh")]), 1),
        ("no --values", run(good / "values.yaml", [(FIXTURES / "bad-install" / "install.sh", "bad-install/install.sh")]), 1),
        ("no install", run(good / "values.yaml", [(FIXTURES / "no-install" / "install.sh", "no-install/install.sh")]), 1),
    ]
    ok = True
    for label, errs, want in cases:
        if want == 0 and errs:
            print(f"SELFTEST FAIL: {label}: {errs}")
            ok = False
        if want > 0 and not errs:
            print(f"SELFTEST FAIL: {label}: the guard passed a broken fixture")
            ok = False
    if not ok:
        return 2
    print("✅ self-test: a values file with no OPERATOR_OPENSHIFT, an install with no --values and a file with no install each fail; the good fixture passes")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    errs = run(VALUES, [(ROOT / c, c) for c in CONSUMERS])
    if errs:
        for e in errs:
            print(f"✗ {e}")
        return 1
    print(f"✅ check-toolhive-install: {len(CONSUMERS)} install(s) read bootstrap/toolhive/values.yaml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
