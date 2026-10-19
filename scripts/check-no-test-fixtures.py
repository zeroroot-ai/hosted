#!/usr/bin/env python3
"""check-no-test-fixtures.py: no environment of this repository turns on a test fixture.

The exit-test runner identity (spiffe://<td>/platform/e2e-runner, its
ServiceAccount and its ClusterSPIFFEID) renders only when the chart value
gibson.e2eRunner.enabled is true, and GIBSON_TEST_FIXTURES_ENABLED turns on the
fixtures of the daemon. The charts guard check-fixture-flag-follows-runner.py
holds every values file that the chart ships. The values that an environment
of this repository applies (gitops/, bootstrap/) are outside its reach, so
this guard reads them: a staging, drill or prod value that turns on the runner
or the flag fails the build. The exit tests turn the runner on at dispatch,
in the workflows, never in a committed environment.

  check-no-test-fixtures.py             exit 1 on a finding
  check-no-test-fixtures.py --selftest  prove each finding fails
"""
import os
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRS = ("gitops", "bootstrap")
FLAG = "GIBSON_TEST_FIXTURES_ENABLED"


def walk(node, path=()):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, path + (str(k),))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, path + (str(i),))
    else:
        yield path, node


def judge_text(name: str, text: str) -> list[str]:
    bad = []
    try:
        docs = list(yaml.safe_load_all(text))
    except yaml.YAMLError:
        docs = []
    for doc in docs:
        for path, value in walk(doc):
            joined = ".".join(path)
            if path[-2:] == ("e2eRunner", "enabled") and value is True:
                bad.append(f"{name}: {joined} is true, which renders the exit-test runner identity")
            if path and path[-1] == "name" and value == FLAG:
                bad.append(f"{name}: {joined} names {FLAG}")
            if path and path[-1] == FLAG:
                bad.append(f"{name}: {joined} sets {FLAG}")
    return bad


def audit(root: str) -> tuple[list[str], int]:
    bad, seen = [], 0
    for d in DIRS:
        for dirpath, _, files in os.walk(os.path.join(root, d)):
            for f in files:
                if not f.endswith((".yaml", ".yml")):
                    continue
                p = os.path.join(dirpath, f)
                seen += 1
                with open(p, encoding="utf-8") as fh:
                    bad += judge_text(os.path.relpath(p, root), fh.read())
    return bad, seen


def selftest() -> int:
    clean = "gibson-workloads:\n  gibson:\n    e2eRunner:\n      enabled: false\n"
    if judge_text("clean", clean):
        print("SELFTEST FAIL: a runner that is off must pass")
        return 1
    for what, text in (
        ("the runner on", "gibson-workloads:\n  gibson:\n    e2eRunner:\n      enabled: true\n"),
        ("the flag as an env entry", "env:\n  - name: GIBSON_TEST_FIXTURES_ENABLED\n    value: \"true\"\n"),
        ("the flag as a map key", "extraEnv:\n  GIBSON_TEST_FIXTURES_ENABLED: \"true\"\n"),
    ):
        if len(judge_text(what, text)) != 1:
            print(f"SELFTEST FAIL: {what} must give one finding, got {judge_text(what, text)}")
            return 1
    print("  ✓ selftest: the runner on, the flag as an env entry and the flag as a map key each fail")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        rc = selftest()
        if rc:
            return rc
    bad, seen = audit(ROOT)
    if not seen:
        bad.append("no YAML file under gitops/ or bootstrap/: this check is blind")
    if bad:
        print("an environment turns on a test fixture:", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        return 1
    print(f"  ✓ check-no-test-fixtures: {seen} environment files turn on no test fixture")
    return 0


if __name__ == "__main__":
    sys.exit(main())
