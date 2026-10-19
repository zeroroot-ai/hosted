#!/usr/bin/env python3
"""check-blocker1-root.py — blocker 1 plans the root each environment really
builds (ADR-0095, hosted#159).

There are two stage 1 roots. Staging builds `bootstrap/ec2/gibson` and
production builds `bootstrap/eks/gibson`. If `exit-test-terraform.yml` plans
the other one, the scorecard reports an estate nobody stands up, and it reports
it GREEN.

Three assertions:

  1. The exit test's stage 1 directory follows the environment, and names
     exactly the roots the Makefile's recreate rows build.
  2. Its Terraform state key follows the environment too. A plan against the
     wrong state file measures a different estate than it names.
  3. Every root the exit test can select exists.

Run:  scripts/check-blocker1-root.py [--selftest]
"""
from __future__ import annotations

import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = pathlib.Path(".github/workflows/exit-test-terraform.yml")
MAKEFILE = pathlib.Path("Makefile")

# The recreate script each environment runs, and the stage 1 root that script
# applies. This is the pairing the guard holds the workflow to.
SCRIPT_ROOT = {
    "recreate-ec2.sh": "bootstrap/ec2/gibson",
    "recreate-aws.sh": "bootstrap/eks/gibson",
}


def recreate_roots(makefile: str) -> dict[str, str]:
    """environment -> the stage 1 root its recreate row builds."""
    out: dict[str, str] = {}
    for env, script in re.findall(r"^RECREATE_UP_(\w+)\s*:=\s*scripts/(\S+)", makefile, re.M):
        if script in SCRIPT_ROOT:
            out[env] = SCRIPT_ROOT[script]
    return out


def workflow_roots(workflow: str) -> tuple[dict[str, str], str | None]:
    """(environment -> root it is planned as, the root every OTHER env gets).

    The expression is `<cond> == 'prod' && 'A' || 'B'`: A for prod, B for
    everything else. The second half is a DEFAULT, not a row for staging, and
    reading it as a row for staging is what broke when `drill` arrived
    (ADR-0095). Three environments now build a stage 1 root and the workflow
    covers all three with two branches, so the model has to carry a default
    rather than a dict of exactly two.
    """
    m = re.search(r"^\s*STAGE1_DIR:\s*(.+)$", workflow, re.M)
    if not m:
        return {}, None
    expr = m.group(1)
    q = re.findall(r"'([^']+)'", expr)
    roots = [v for v in q if v.startswith("bootstrap/")]
    if len(roots) != 2 or "prod" not in q:
        return {}, None
    return {"prod": roots[0]}, roots[1]


def offenders(root: pathlib.Path) -> list[str]:
    try:
        workflow = (root / WORKFLOW).read_text()
        makefile = (root / MAKEFILE).read_text()
    except FileNotFoundError as e:
        return [f"GUARD BROKEN: {e.filename} is missing — the tree moved"]

    built = recreate_roots(makefile)
    if not built:
        return ["GUARD BROKEN: no RECREATE_UP_ row names a known recreate script — the tree moved"]

    planned, default_root = workflow_roots(workflow)
    if not planned or default_root is None:
        return [f"{WORKFLOW}: the plan job does not select a stage 1 root per environment, "
                "so it measures one root for every environment (ADR-0095)"]

    bad: list[str] = []
    for env, want in built.items():
        got = planned.get(env, default_root)
        if got != want:
            bad.append(
                f"{WORKFLOW}: environment {env} builds {want}, and blocker 1 plans {got}. "
                "The scorecard would report an estate nobody stands up"
            )
        if got and not (root / got).is_dir():
            bad.append(f"{WORKFLOW}: the exit test can select {got}, which does not exist")

    key = re.search(r"^\s*STATE_KEY:\s*(.+)$", workflow, re.M)
    if not key:
        bad.append(f"{WORKFLOW}: the plan job pins one Terraform state key for every environment, "
                   "so a plan reads a different estate than it names")
    else:
        keys = [v for v in re.findall(r"'([^']+)'", key.group(1)) if v.startswith("tfstate/")]
        if len(set(keys)) < 2:
            bad.append(f"{WORKFLOW}: the state key does not follow the environment ({keys})")
    return bad


CLEAN_WORKFLOW = """\
jobs:
  plan:
    env:
      STAGE1_DIR: ${{ (github.event.inputs.env || 'staging') == 'prod' && 'bootstrap/eks/gibson' || 'bootstrap/ec2/gibson' }}
      STATE_KEY: ${{ (github.event.inputs.env || 'staging') == 'prod' && 'tfstate/eks-gibson/terraform.tfstate' || 'tfstate/ec2-gibson/terraform.tfstate' }}
"""
CLEAN_MAKEFILE = """\
RECREATE_UP_staging := scripts/recreate-ec2.sh $(SUBSTRATE_ENV_staging) staging
RECREATE_UP_drill   := scripts/recreate-ec2.sh $(SUBSTRATE_ENV_drill) drill
RECREATE_UP_prod    := scripts/recreate-aws.sh $(SUBSTRATE_ENV_prod) prod
"""


def write_fixture(d: pathlib.Path, workflow: str = CLEAN_WORKFLOW, makefile: str = CLEAN_MAKEFILE) -> None:
    (d / WORKFLOW).parent.mkdir(parents=True, exist_ok=True)
    (d / WORKFLOW).write_text(workflow)
    (d / MAKEFILE).write_text(makefile)
    for r in ("bootstrap/ec2/gibson", "bootstrap/eks/gibson"):
        (d / r).mkdir(parents=True, exist_ok=True)


def selftest() -> int:
    def broken(msg: str) -> int:
        print(f"GUARD BROKEN: {msg}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        write_fixture(d)
        if offenders(d):
            return broken(f"a clean fixture was rejected: {offenders(d)}")

        # The roots swapped: staging would be planned as EKS.
        swapped = CLEAN_WORKFLOW.replace(
            "'bootstrap/eks/gibson' || 'bootstrap/ec2/gibson'",
            "'bootstrap/ec2/gibson' || 'bootstrap/eks/gibson'")
        write_fixture(d, workflow=swapped)
        if not any("blocker 1 plans" in g for g in offenders(d)):
            return broken(f"a swapped pairing was accepted (got {offenders(d)})")

        # One root for every environment, the shape before hosted#159.
        write_fixture(d, workflow="jobs:\n  plan:\n    env:\n      ENV: staging\n")
        if not any("does not select a stage 1 root per environment" in g for g in offenders(d)):
            return broken("a single-root plan job was accepted")

        # One state key for every environment.
        one_key = CLEAN_WORKFLOW.replace(
            "'tfstate/eks-gibson/terraform.tfstate' || 'tfstate/ec2-gibson/terraform.tfstate'",
            "'tfstate/eks-gibson/terraform.tfstate' || 'tfstate/eks-gibson/terraform.tfstate'")
        write_fixture(d, workflow=one_key)
        if not any("state key does not follow the environment" in g for g in offenders(d)):
            return broken("one state key for every environment was accepted")

        # A selectable root that is not in the tree.
        write_fixture(d)
        import shutil
        shutil.rmtree(d / "bootstrap/ec2/gibson")
        if not any("does not exist" in g for g in offenders(d)):
            return broken("a selectable root that is absent was accepted")

    print("✅ self-test: a swapped pairing, a single-root plan job, one shared state key "
          "and a selectable root that is absent are all rejected")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    bad = offenders(ROOT)
    if any(b.startswith("GUARD BROKEN") for b in bad):
        for b in bad:
            print(b, file=sys.stderr)
        return 2
    if bad:
        print("❌ blocker 1 would measure a root the environment does not build (ADR-0095):")
        for b in bad:
            print("   ", b)
        return 1
    print("✅ blocker 1 plans the root each environment builds, from that environment's own state")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
