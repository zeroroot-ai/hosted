#!/usr/bin/env python3
"""check-verb-workflows.py — the verb workflows keep the ADR-0083 contract.

Each bringup verb is one make target and one GitHub workflow with the same
name and inputs (docs/bringup.md § The verbs). This guard keeps the three
workflow files honest, keyed by content, never by line number:

  1. preflight.yml, teardown.yml and recreate.yml exist and run on
     workflow_dispatch ONLY. A verb on a schedule or a push is an
     unattended teardown.
  2. The `env` input is a required choice. preflight offers staging|prod.
     teardown and recreate offer prod only: no workflow tears staging down
     or rebuilds it (ADR-0095, hosted#403). No verb input
     declares a `default`, anywhere: a verb that picks an environment or a
     mode by omission is how the wrong estate gets touched (ADR-0083), and
     a defaulted `mode` is how a preserve teardown silently becomes a wipe.
  3. teardown.yml has the required choice input `mode` with exactly
     wipe|preserve. recreate.yml has the optional string input
     `restore_from` (ADR-0083: restore only a named backup).
  4. Every job runs on `environment: ${{ inputs.env }}`, so the GitHub
     environment protection rule (prod: one named reviewer) gates the run.
  5. Workflow-level concurrency groups on the env input with
     cancel-in-progress false, so two verbs cannot race one environment
     and a running teardown is never cancelled half-way.
  7. A job that runs a verb (`make preflight|teardown|recreate`) holds no
     write token: its effective permissions (the job's, else the
     workflow's) have no `contents: write` and no `pull-requests: write`.
     Only the catch-up job of a restore writes, and it runs no verb (D91,
     hosted#687).
  6. The keyring comes from Secrets Manager (ADR-0083, amendment of
     2026-10-22). No workflow reads `secrets.BRINGUP_KEYRING`,
     `vars.SUBSTRATE_ENV_FILE`, `KEYRING_APP_ID` or `KEYRING_APP_PRIVATE_KEY`:
     the GitHub environments hold no keyring, and there is no GitHub App for it.

Usage: scripts/check-verb-workflows.py            # the guard
       scripts/check-verb-workflows.py --selftest # prove it can fail
Exit:  0 clean · 1 a rule is broken · 2 self-test broken
"""
from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW_DIR = ROOT / ".github/workflows"
FIXTURES = ROOT / "scripts/testdata/verb-workflows"

VERBS = ("preflight", "teardown", "recreate", "rotate-credentials")
# preflight reads and proves; it changes nothing, so it can name staging.
# teardown and recreate cannot (ADR-0095, hosted#403).
ENV_OPTIONS = {
    "preflight": ["staging", "prod"],
    "teardown": ["prod"],
    "recreate": ["prod"],
    "rotate-credentials": ["staging", "prod"],
}
ENV_EXPR = re.compile(r"^\$\{\{\s*inputs\.env\s*\}\}$")
# What a workflow may not read. A comment line is not a read.
KEYRING_FROM_GITHUB = re.compile(
    r"secrets\.BRINGUP_KEYRING|vars\.SUBSTRATE_ENV_FILE|KEYRING_APP_ID|KEYRING_APP_PRIVATE_KEY"
)
VERB_RUN = re.compile(r"\bmake\s+(preflight|teardown|recreate)\b")
WRITE_SCOPES = ("contents", "pull-requests")


def _on(doc: dict):
    on = doc.get("on")
    if on is None:
        on = doc.get(True)  # PyYAML parses a bare `on:` key as boolean True
    if isinstance(on, dict):
        return on
    if isinstance(on, list):
        return {k: None for k in on}
    if isinstance(on, str):
        return {on: None}
    return {}


def _walk_inputs(doc: dict) -> dict:
    dispatch = _on(doc).get("workflow_dispatch") or {}
    return dispatch.get("inputs") or {}


def check_workflow(path: pathlib.Path, verb: str) -> list[str]:
    rel = path.name
    if not path.is_file():
        return [f"{rel}: missing — every verb is one make target AND one workflow (ADR-0083)"]
    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        return [f"{rel}: does not parse: {exc}"]
    if not isinstance(doc, dict):
        return [f"{rel}: not a workflow mapping"]
    bad: list[str] = []

    triggers = _on(doc)
    if set(triggers) != {"workflow_dispatch"}:
        bad.append(f"{rel}: triggers must be workflow_dispatch only, got {sorted(map(str, triggers))}")

    inputs = _walk_inputs(doc)
    env = inputs.get("env")
    if not isinstance(env, dict):
        bad.append(f"{rel}: no `env` input")
    else:
        if env.get("required") is not True:
            bad.append(f"{rel}: the `env` input must be required")
        if env.get("type") != "choice" or env.get("options") != ENV_OPTIONS[verb]:
            bad.append(f"{rel}: the `env` input must be a choice of {ENV_OPTIONS[verb]}")
    for name, spec in inputs.items():
        if isinstance(spec, dict) and "default" in spec:
            bad.append(f"{rel}: input `{name}` declares a default — no verb input may (ADR-0083)")

    if verb == "teardown":
        mode = inputs.get("mode")
        if not isinstance(mode, dict):
            bad.append(f"{rel}: no `mode` input — MODE=wipe|preserve is required with no default")
        else:
            if mode.get("required") is not True:
                bad.append(f"{rel}: the `mode` input must be required")
            if mode.get("type") != "choice" or mode.get("options") != ["wipe", "preserve"]:
                bad.append(f"{rel}: the `mode` input must be a choice of ['wipe', 'preserve']")
    if verb == "recreate":
        rf = inputs.get("restore_from")
        if not isinstance(rf, dict):
            bad.append(f"{rel}: no `restore_from` input (ADR-0083)")
        elif rf.get("required") is True:
            bad.append(f"{rel}: `restore_from` must be optional — an empty value means bootstrap empty (ADR-0083)")

    conc = doc.get("concurrency")
    if not isinstance(conc, dict) or "inputs.env" not in str(conc.get("group", "")):
        bad.append(f"{rel}: workflow-level concurrency must group on the env input")
    elif conc.get("cancel-in-progress") is not False:
        bad.append(f"{rel}: concurrency cancel-in-progress must be false — never cancel a running verb")

    jobs = doc.get("jobs") or {}
    if not jobs:
        bad.append(f"{rel}: no jobs")
    wf_perms = doc.get("permissions") if isinstance(doc.get("permissions"), dict) else {}
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        runs_verb = any(isinstance(s, dict) and isinstance(s.get("run"), str) and VERB_RUN.search(s["run"])
                        for s in job.get("steps") or [])
        perms = job.get("permissions") if isinstance(job.get("permissions"), dict) else wf_perms
        writes = [k for k in WRITE_SCOPES if str(perms.get(k, "")).strip() == "write"]
        if runs_verb and writes:
            bad.append(f"{rel}: job `{job_id}` runs a verb and holds a write token ({', '.join(writes)}): "
                       "the bringup role and a write token never share a job (D91, hosted#687)")
        environment = job.get("environment")
        if isinstance(environment, dict):
            environment = environment.get("name")
        if not (isinstance(environment, str) and ENV_EXPR.match(environment.strip())):
            bad.append(f"{rel}: job `{job_id}` must run on `environment: ${{{{ inputs.env }}}}` so the protection rule gates it")
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue

    # The keyring is not read from GitHub, wherever it is mentioned in code.
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        m = KEYRING_FROM_GITHUB.search(line)
        if m:
            bad.append(f"{rel}:{n}: reads {m.group(0)}: the keyring comes from Secrets Manager, not from GitHub")
    return bad


def run_guard() -> int:
    bad: list[str] = []
    for verb in VERBS:
        bad += check_workflow(WORKFLOW_DIR / f"{verb}.yml", verb)
    if bad:
        print("verb workflows break the ADR-0083 contract:", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        return 1
    print(f"✅ {', '.join(v + '.yml' for v in VERBS)}: dispatch-only, required un-defaulted inputs, environment-gated, "
          "keyring read from Secrets Manager, never from GitHub, no verb job holds a write token")
    return 0


def selftest() -> int:
    def broken(msg: str) -> int:
        print(f"GUARD BROKEN: {msg}", file=sys.stderr)
        return 2

    cases = [  # fixture file, verb to check it as, reason substring the guard must name
        ("teardown-defaulted-mode.yml", "teardown", "declares a default"),
        ("teardown-missing-mode.yml", "teardown", "no `mode` input"),
        ("teardown-echoes-keyring.yml", "teardown", "reads secrets.BRINGUP_KEYRING"),
        ("recreate-reads-substrate-env-var.yml", "recreate", "reads vars.SUBSTRATE_ENV_FILE"),
        ("rotate-uses-github-app.yml", "rotate-credentials", "reads KEYRING_APP_ID"),
        ("preflight-no-environment.yml", "preflight", "must run on `environment:"),
        ("recreate-on-schedule.yml", "recreate", "workflow_dispatch only"),
        ("recreate-write-token.yml", "recreate", "holds a write token"),
    ]
    for name, verb, needle in cases:
        f = FIXTURES / name
        if not f.is_file():
            return broken(f"fixture {f.relative_to(ROOT)} is missing — no fixture, no guard")
        bad = check_workflow(f, verb)
        if not any(needle in b for b in bad):
            return broken(f"fixture {name} was not rejected for '{needle}' (got {bad})")
    good = FIXTURES / "teardown-good.yml"
    bad = check_workflow(good, "teardown")
    if bad:
        return broken(f"the clean fixture was rejected: {bad}")
    # The guard must also fail on an absent file, never pass silently.
    if not check_workflow(FIXTURES / "does-not-exist.yml", "teardown"):
        return broken("a missing workflow was accepted")
    print("✅ self-test: 8 bad fixtures rejected for the right reason, the clean fixture passes, a missing file fails")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    return run_guard()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
