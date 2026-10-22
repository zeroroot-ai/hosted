#!/usr/bin/env python3
"""check-role-callers.py — each workflow that assumes a pinned AWS role is trusted by it, and only it (hosted#656).

The trust policy of each role below pins job_workflow_ref to a list of
workflow files in bootstrap/eks/aws-org. A workflow that assumes the role
and is not in its list fails at "Configure AWS credentials" with "Not
authorized to perform sts:AssumeRoleWithWebIdentity". exit-test-monitoring
failed that way every day from 2026-10-08, and exit-test-setec-cpu-template
from its first run, on the administrator role eks-bringup.

For each role, the guard compares two sets, both ways:
  - a workflow that assumes the role and is not in the list cannot run;
  - a listed file that does not assume the role is trust with no caller.

Usage: scripts/check-role-callers.py            # the guard
       scripts/check-role-callers.py --selftest # prove it can fail
Exit:  0 clean · 1 the sets differ · 2 self-test broken or a list not found
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github/workflows"
TF_DIR = ROOT / "bootstrap/eks/aws-org"
# The key rotation role of stage 0 (rotation-role.tf). Its trust pins
# job_workflow_ref to full refs, one for each workflow file.
# (variable of the environment that holds the role ARN, Terraform file, local with the list)
STAGE0_ROLES = [
    ("KEY_ROTATION_ROLE_ARN", ROOT / "substrate/gibson-bootstrap/rotation-role.tf", "rotation_job_workflow_refs"),
    ("KEYRING_READER_ROLE_ARN", ROOT / "substrate/gibson-bootstrap/keyring-reader-role.tf", "keyring_reader_job_workflow_refs"),
]

# (repository variable that holds the role ARN, Terraform local with the list)
ROLES = [
    ("EKS_BRINGUP_ROLE_ARN", "gh_bringup_job_workflow_refs"),
    ("EXIT_TEST_NODE_ROLE_ARN", "gh_exit_test_node_job_workflow_refs"),
]


def trusted(tf_text: str, local: str) -> set[str]:
    m = re.search(local + r"\s*=\s*\[\s*for\s+\w+\s+in\s+\[(?P<body>[^\]]*)\]", tf_text, re.S)
    if m is None:
        raise ValueError(f"{local} list not found")
    return set(re.findall(r'"([^"]+\.ya?ml)"', m.group("body")))


def callers(workflows: dict[str, str], var: str) -> set[str]:
    use = re.compile(r"\$\{\{\s*vars\." + re.escape(var) + r"\s*\}\}")
    out = set()
    for name, text in workflows.items():
        # A comment that names the variable is not a caller.
        code = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
        if use.search(code):
            out.add(name)
    return out


def problems(tf_text: str, workflows: dict[str, str], roles=ROLES) -> list[str]:
    bad = []
    for var, local in roles:
        t, c = trusted(tf_text, local), callers(workflows, var)
        bad += [f"{w}: assumes {var}, and {local} does not name it" for w in sorted(c - t)]
        bad += [f"{w}: named in {local}, and no workflow of that name assumes {var}" for w in sorted(t - c)]
    return bad


def stage0_trusted(tf_text: str, local: str) -> set[str]:
    m = re.search(local + r"\s*=\s*\[(?P<body>[^\]]*)\]", tf_text, re.S)
    if m is None:
        raise ValueError(f"{local} list not found")
    return set(re.findall(r"\.github/workflows/([\w.-]+\.ya?ml)@refs/heads/main", m.group("body")))


def stage0_problems(tf_text: str, workflows: dict[str, str], var: str, local: str) -> list[str]:
    t, c = stage0_trusted(tf_text, local), callers(workflows, var)
    bad = [f"{w}: assumes {var}, and {local} does not name it" for w in sorted(c - t)]
    bad += [f"{w}: named in {local}, and no workflow of that name assumes {var}" for w in sorted(t - c)]
    return bad


def selftest() -> int:
    rtf = 'rotation_job_workflow_refs = [\n  "o/r/.github/workflows/rotate-credentials.yml@refs/heads/main",\n]\n'
    ruse = "steps:\n  - with:\n      role-to-assume: ${{ vars.KEY_ROTATION_ROLE_ARN }}\n"
    for label, wfs, want_bad in (
        ("a rotation caller that the trust does not name", {"rotate-credentials.yml": ruse, "other.yml": ruse}, True),
        ("a rotation file with no caller", {"rotate-credentials.yml": "steps: []\n"}, True),
        ("the rotation sets match", {"rotate-credentials.yml": ruse}, False),
    ):
        if bool(stage0_problems(rtf, wfs, "KEY_ROTATION_ROLE_ARN", "rotation_job_workflow_refs")) != want_bad:
            print(f"GUARD BROKEN: {label} gave the wrong result", file=sys.stderr)
            return 2
    roles = [("ROLE_A", "list_a"), ("ROLE_B", "list_b")]
    tf = ('list_a = [\n  for w in [\n    "recreate.yml",\n  ] :\n'
          'list_b = [\n  for w in [\n    "exit-test-x.yml",\n  ] :\n')
    use_a = "steps:\n  - with:\n      role-to-assume: ${{ vars.ROLE_A }}\n"
    use_b = "steps:\n  - with:\n      role-to-assume: ${{ vars.ROLE_B }}\n"
    comment = "# role-to-assume: ${{ vars.ROLE_A }}\nsteps: []\n"
    cases = [
        ("a caller on the wrong role", {"recreate.yml": use_a, "exit-test-x.yml": use_a}, True),
        ("a trusted file with no caller", {"recreate.yml": comment, "exit-test-x.yml": use_b}, True),
        ("the sets match", {"recreate.yml": use_a, "exit-test-x.yml": use_b, "other.yml": comment}, False),
    ]
    for label, wfs, want_bad in cases:
        if bool(problems(tf, wfs, roles)) != want_bad:
            print(f"GUARD BROKEN: {label} gave the wrong result", file=sys.stderr)
            return 2
    try:
        trusted("no list here", "list_a")
    except ValueError:
        pass
    else:
        print("GUARD BROKEN: a missing list was accepted", file=sys.stderr)
        return 2
    print("✅ self-test: a caller on the wrong role and a trusted file with no caller are rejected")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    wfs = {p.name: p.read_text() for p in sorted(WORKFLOWS.glob("*.y*ml"))}
    tf = "\n".join(p.read_text() for p in sorted(TF_DIR.glob("*.tf")))
    try:
        bad = problems(tf, wfs)
        for var, path, local in STAGE0_ROLES:
            bad += stage0_problems(path.read_text(), wfs, var, local)
    except ValueError as e:
        print(f"❌ {TF_DIR.relative_to(ROOT)}: {e}", file=sys.stderr)
        return 2
    if bad:
        print("❌ a pinned role and its callers differ (hosted#656):")
        for b in bad:
            print("   ", b)
        return 1
    for var, _ in ROLES + [(v, l) for v, _, l in STAGE0_ROLES]:
        print(f"✅ {len(callers(wfs, var))} workflows assume {var}, and its trust names each one")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
