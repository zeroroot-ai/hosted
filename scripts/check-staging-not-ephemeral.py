#!/usr/bin/env python3
"""No workflow destroys or rebuilds staging (ADR-0095).

Staging stays up all the time. The destroy-and-recreate tests run against the
`drill` environment, which exists to be thrown away.

This guard reads the workflow files and fails when one of them runs a verb that
would take staging down or stand it back up:

  make teardown ENV=staging      destroys it
  make recreate ENV=staging      rebuilds it, which starts by destroying
  make eks-kubeconfig ENV=staging  asks EKS for a cluster that has not existed
                                   since ADR-0095, so it is always a bug

The from-zero preflight in promote-staging.yml was the one that kept doing it:
`make teardown ENV=staging MODE=wipe`, with the input defaulting to true. Being
a default rather than a flag is why it was easy to miss.

The guard reads each workflow two ways (hosted#403):

  1. Line by line: a verb and `ENV=staging` on one line.
  2. As YAML: the value of ENV that reaches a verb step. The value can come
     from the line, or from the `env` map of the step, the job or the
     workflow. The guard fails when that value is the literal `staging`, when
     it is a dispatch input whose options hold `staging`, and when it is a
     free-text input, which can supply `staging`.

So `teardown.yml` and `recreate.yml` do not offer `staging`. An operator who
must rebuild staging runs the verb from a workstation, with the serverName
pull request first.

  check-staging-not-ephemeral.py --selftest   prove it can still fail

The failing fixtures for the second way are in
scripts/testdata/staging-not-ephemeral/.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
FIXTURES = ROOT / "scripts" / "testdata" / "staging-not-ephemeral"

# A verb and the env on the same line, in either order, which is how make is
# called: `make teardown ENV=staging MODE=wipe` and
# `ENV=staging make recreate` both read the same to the shell.
VERBS = ("teardown", "recreate", "eks-kubeconfig", "eks-smoke", "eks-converge")
PATTERNS = [
    (v, re.compile(r"make\s+[^\n#]*\b%s\b[^\n#]*\bENV\s*[=:]\s*[\"']?staging" % v))
    for v in VERBS
] + [
    (v, re.compile(r"ENV\s*[=:]\s*[\"']?staging[\"']?\s+make\s+[^\n#]*\b%s\b" % v))
    for v in VERBS
]


def scan(text: str, name: str) -> list[str]:
    bad = []
    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        # A comment explaining the rule must not trip it.
        if stripped.startswith("#"):
            continue
        for verb, pat in PATTERNS:
            if pat.search(line):
                bad.append(f"{name}:{i}: `make {verb}` with ENV=staging — {line.strip()[:90]}")
                break
    return bad


# --- the second way: the value of ENV that reaches a verb step ---------------

# The verbs that destroy or rebuild an environment. The eks-* helpers are in
# the line scan only: they are always a bug with staging, never a lifecycle.
FLOW_VERBS = ("teardown", "recreate")
ENV_ON_LINE = re.compile(r"""\bENV=(?P<q>["']?)(?P<v>\$\{\{[^}]*\}\}|[^\s"']+)(?P=q)""")
SELF_REF = re.compile(r"^\$\{?ENV\}?$|^\$\{\{\s*env\.ENV\s*\}\}$")
INPUT_REF = re.compile(r"^\$\{\{\s*(?:github\.event\.)?inputs\.([A-Za-z0-9_-]+)\s*\}\}$")


def _on(doc: dict) -> dict:
    on = doc.get("on")
    if on is None:
        on = doc.get(True)  # PyYAML reads a bare `on:` key as the boolean True
    return on if isinstance(on, dict) else {}


def _inputs(doc: dict) -> dict:
    out: dict = {}
    for trigger in ("workflow_dispatch", "workflow_call"):
        out.update(((_on(doc).get(trigger) or {}).get("inputs")) or {})
    return out


def _goals(line: str) -> list[str]:
    """The make goals on one shell line: the words after `make` that are not
    a variable assignment or a flag, up to the end of that command."""
    goals: list[str] = []
    m = re.search(r"(?:^|[\s;&|(])make\s+(.*)", line)
    if not m:
        return goals
    for word in m.group(1).split():
        if word in ("||", "&&", "|", ";") or word.startswith("#"):
            break
        if "=" in word or word.startswith("-"):
            continue
        goals.append(word.strip("\"'"))
    return goals


def _why(value: str, env: dict, inputs: dict) -> str | None:
    """Why this ENV value can be staging, or None when it cannot."""
    value = value.strip().strip("\"'")
    if SELF_REF.match(value):
        if "ENV" not in env:
            return None
        return _why(str(env["ENV"]), {}, inputs)
    if value == "staging":
        return "ENV is staging for this step"
    m = INPUT_REF.match(value)
    if m:
        spec = inputs.get(m.group(1))
        if not isinstance(spec, dict):
            return None
        if spec.get("type") == "choice":
            if "staging" in [str(o) for o in (spec.get("options") or [])]:
                return f"the input `{m.group(1)}` offers staging"
            return None
        return f"the input `{m.group(1)}` is free text, so it can supply staging"
    return None


def scan_flow(text: str, name: str) -> list[str]:
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError:
        return []
    if not isinstance(doc, dict):
        return []
    inputs = _inputs(doc)
    wf_env = doc.get("env") or {}
    bad: list[str] = []
    for job_name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        job_env = {**wf_env, **(job.get("env") or {})}
        for step in job.get("steps") or []:
            run = step.get("run") if isinstance(step, dict) else None
            if not isinstance(run, str):
                continue
            env = {**job_env, **(step.get("env") or {})}
            for line in run.splitlines():
                if line.lstrip().startswith("#"):
                    continue
                verbs = [g for g in _goals(line) if g in FLOW_VERBS]
                if not verbs:
                    continue
                on_line = ENV_ON_LINE.search(line)
                value = on_line.group("v") if on_line else "${ENV}"
                why = _why(value, env, inputs)
                if why:
                    bad.append(f"{name}: job `{job_name}`: `make {verbs[0]}` can reach staging: {why}")
    return bad


def selftest() -> int:
    cases = [
        ("make teardown ENV=staging MODE=wipe", True),
        ('ENV=staging make recreate', True),
        ("make recreate ENV=\"staging\"", True),
        ("make eks-kubeconfig ENV=staging", True),
        # not violations
        ("# make teardown ENV=staging MODE=wipe is what ADR-0095 forbids", False),
        ("make recreate ENV=drill", False),
        ("make recreate ENV=kind", False),
        ("make with-cluster ENV=staging CMD='kubectl get nodes'", False),
    ]
    ok = True
    for text, should_fail in cases:
        hit = bool(scan(text, "fixture"))
        if hit != should_fail:
            print(f"SELFTEST FAIL: {text!r} -> {hit}, wanted {should_fail}")
            ok = False
    # The second way. Each bad fixture must give one or more findings, and
    # each good fixture none.
    flow_cases = {
        "bad-job-env.yml": True,
        "bad-step-env.yml": True,
        "bad-dispatch-input.yml": True,
        "bad-free-text-input.yml": True,
        "good-drill-job-env.yml": False,
        "good-prod-only-input.yml": False,
    }
    for fixture, should_fail in flow_cases.items():
        f = FIXTURES / fixture
        if not f.is_file():
            print(f"SELFTEST FAIL: the fixture {fixture} is missing")
            ok = False
            continue
        hit = bool(scan_flow(f.read_text(), fixture))
        if hit != should_fail:
            print(f"SELFTEST FAIL: {fixture} -> {hit}, wanted {should_fail}")
            ok = False
    if not ok:
        return 1
    print("✅ self-test: a teardown, a recreate and an eks-kubeconfig against staging each "
          "fail; a comment, the drill env, kind and with-cluster do not. A job-level ENV, "
          "a step-level ENV, a dispatch input that offers staging and a free-text input "
          "each fail; a drill job and a prod-only input do not")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    if not WORKFLOWS.is_dir():
        print(f"❌ no workflows at {WORKFLOWS}")
        return 1
    bad: list[str] = []
    files = sorted(WORKFLOWS.glob("*.yml"))
    if len(files) < 5:
        print(f"❌ only {len(files)} workflow files at {WORKFLOWS}, so the scan did not look at the repo")
        return 1
    for f in files:
        text = f.read_text()
        bad += scan(text, f.name)
        bad += scan_flow(text, f.name)
    if bad:
        print("❌ a workflow destroys or rebuilds staging, which ADR-0095 forbids:\n  "
              + "\n  ".join(bad)
              + "\n\n  Staging stays up. Run destroy-and-recreate tests with ENV=drill, and"
                "\n  reach a permanent staging with `make with-cluster ENV=staging CMD=...`.")
        return 1
    print("✓ staging-not-ephemeral: no workflow tears staging down, rebuilds it, or asks EKS for it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
