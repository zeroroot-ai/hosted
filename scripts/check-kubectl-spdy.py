#!/usr/bin/env python3
"""check-kubectl-spdy.py: a workflow job that runs kubectl sets
KUBECTL_REMOTE_COMMAND_WEBSOCKETS=false (hosted#10).

The WebSocket transport of kubectl drops stream bytes, and the exec still
exits 0 (a canary marker of 0 bytes in drill runs 39171920065 and
39175834377, lost stdout on kind in #253). Each make verb exports the
variable (Makefile). A job that runs kubectl outside make does not get it,
so it needs one of these places:

  - `env:` at workflow level or at job level with the value false;
  - a step that uses ./.github/actions/install-cluster-tools or
    ./.github/actions/stage0-setup, which write the variable to GITHUB_ENV.
    GITHUB_ENV reaches only later steps, so that step comes before the first
    step that runs kubectl.

A job "runs kubectl" when a run step calls kubectl exec, cp or attach (the
only verbs that the variable changes, also after a line continuation), runs a
script under test/ or scripts/ (not with --selftest, not scripts/check-*), or
uses an action that does (demo-enrollment-install,
smoke-prereqs, edge-harness). A job that only calls make has the Makefile.

The action install-cluster-tools must write the variable to GITHUB_ENV, or
the second place is empty.

Usage:  scripts/check-kubectl-spdy.py [--selftest]
Exit:   0 clean, 1 a job breaks the rule, 2 the self-test is broken or no
        workflow was read
The fixtures are in scripts/testdata/kubectl-spdy/.
"""
from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "kubectl-spdy"
VAR = "KUBECTL_REMOTE_COMMAND_WEBSOCKETS"
# A stream verb of kubectl (the variable changes only these), or a script
# under test/ or scripts/ that may run one. A script run with --selftest
# touches no cluster, and the guards (scripts/check-*) and scripts/install-bats.sh
# never exec. A line continuation is joined before the match, so a verb on the
# next line is seen.
RUNS_KUBECTL = re.compile(
    r"\bkubectl\b[^\n]*\s(?:exec|cp|attach)\s"
    r"|(?:^[ \t]*|[;&|(][ \t]*|\b(?:bash|sh)[ \t]+)(?:\./)?"
    r"(?:test/[\w./-]+\.sh|scripts/(?!check-|install-bats\.sh)[\w./-]+\.sh)\b(?![^\n]*--selftest)",
    re.M,
)
KUBECTL_ACTIONS = ("demo-enrollment-install", "smoke-prereqs", "edge-harness")
SETTER_ACTIONS = ("install-cluster-tools", "stage0-setup")


def uses(step: dict, names: tuple[str, ...]) -> bool:
    u = step.get("uses")
    return isinstance(u, str) and any(u.rstrip("/").endswith("/" + n) for n in names)


def step_runs_kubectl(step: dict) -> bool:
    text = re.sub(r"\\[ \t]*\n[ \t]*", " ", step.get("run") or "")
    return bool(RUNS_KUBECTL.search(text)) or uses(step, KUBECTL_ACTIONS)


def runs_kubectl(job: dict) -> bool:
    return any(step_runs_kubectl(s) for s in job.get("steps") or [])


def is_false(env: object) -> bool:
    return isinstance(env, dict) and str(env.get(VAR, "")).strip().lower() == "false"


def has_place(job: dict, workflow: dict) -> bool:
    """The variable is set before the first kubectl step.

    GITHUB_ENV reaches only the steps after the step that writes it, so a
    setter action counts only when it comes first.
    """
    if is_false(workflow.get("env")) or is_false(job.get("env")):
        return True
    for step in job.get("steps") or []:
        if uses(step, SETTER_ACTIONS):
            return True
        if step_runs_kubectl(step):
            # A step env reaches that step only. The next kubectl step needs
            # its own place.
            if is_false(step.get("env")):
                continue
            return False
    return True


def findings(path: pathlib.Path) -> list[str]:
    w = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    out = []
    for name, job in (w.get("jobs") or {}).items():
        if isinstance(job, dict) and runs_kubectl(job) and not has_place(job, w):
            out.append(f"{path.name} job {name}: runs kubectl and sets {VAR}=false in no place")
    return out


def setter_action_ok() -> list[str]:
    p = ROOT / ".github" / "actions" / "install-cluster-tools" / "action.yml"
    text = p.read_text(encoding="utf-8")
    if not re.search(rf"{VAR}=false.*GITHUB_ENV", text):
        return [f"{p.relative_to(ROOT)}: does not write {VAR}=false to GITHUB_ENV"]
    return []


def selftest() -> int:
    bads = sorted(FIXTURES.glob("bad-*.yml"))
    goods = sorted(FIXTURES.glob("good-*.yml"))
    if len(bads) < 7 or len(goods) < 3:
        print("check-kubectl-spdy: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for b in bads:
        if len(findings(b)) != 1:
            print(f"check-kubectl-spdy: selftest: {b.name} gave {findings(b)}, want one finding", file=sys.stderr)
            return 2
    for g in goods:
        if findings(g):
            print(f"check-kubectl-spdy: selftest: {g.name} gave {findings(g)}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bads)} jobs that run kubectl on WebSocket are refused, {len(goods)} others pass")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    paths = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))
    if not paths:
        print("check-kubectl-spdy: no workflow was read", file=sys.stderr)
        return 2
    bad = setter_action_ok() + [f for p in paths for f in findings(p)]
    if bad:
        print(f"❌ a job that runs kubectl must set {VAR}=false (hosted#10):", file=sys.stderr)
        for b in bad:
            print(f"   {b}", file=sys.stderr)
        return 1
    n = sum(1 for p in paths for j in ((yaml.safe_load(p.read_text()) or {}).get("jobs") or {}).values()
            if isinstance(j, dict) and runs_kubectl(j))
    if n == 0:
        print("check-kubectl-spdy: no job runs kubectl, so the scan read nothing", file=sys.stderr)
        return 1
    print(f"✅ {n} jobs run kubectl, each with {VAR}=false")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
