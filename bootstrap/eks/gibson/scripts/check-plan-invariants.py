#!/usr/bin/env python3
"""Assert the two invariants that launch blocker 1 is measured by.

deploy#1588 reported two defects in the `bootstrap/eks/gibson` workspace:

  1. An untargeted `terraform plan` exited 1 with `Error: Cycle:` — a loop
     spanning kms -> s3 -> network -> cluster that closed through a *destroy*
     node, so the apply could never finish.
  2. Every `-target`ed plan wanted to REPLACE the audit and backups buckets,
     because the bucket name interpolates an account id that Terraform defers
     under `-target`, and an unknown bucket name forces replacement.

Both were properties of the live state at the time, not of the configuration
(the module graph is a DAG, and a local reproduction of the same shape refused
to cycle). Live state is not something a reviewer can read, so the only honest
way to keep these fixed is to measure them on every run.

This script is that measurement. It reads `terraform show -json <planfile>`
and fails when either invariant breaks:

  - any resource in the replace set (`delete`+`create` in either order), with
    S3 buckets called out first because they hold the append-only audit log
    and the only OpenBao KEK archive;
  - `terraform plan` having failed at all, which is how a dependency cycle
    surfaces — a cycle aborts the plan, so no plan JSON is ever written. Pass
    the captured plan output with --plan-log to name the cycle explicitly
    instead of reporting a generic "no JSON" error;
  - the plan having had NOTHING TO MEASURE. A plan against an empty workspace
    creates everything and changes nothing, so it cannot contain a replace set
    and cannot contain a cycle through a destroy node. Passing on one proves
    the opposite of what blocker 1 claims.

The third invariant is the one that was missing. Stage 1 in staging was torn
down from 2026-08-16, so every scheduled run planned against an empty state
and reported `113 to add, 0 to change, 0 to destroy`. The exit test was green
on 09-10, 09-12, 09-13 and twice on 09-14 and measured nothing on any of them.
It went red within hours of real state existing again, on a defect that had
been in the configuration the whole time (hosted#100). A test that can only
pass is not a test.

Exit 0 means: the plan is clean, and blocker 1's exit test passes.

Usage:
  terraform plan -out=tf.plan ... && terraform show -json tf.plan > plan.json
  python3 scripts/check-plan-invariants.py plan.json [--plan-log plan.txt]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

# A resource is replaced when Terraform both destroys and creates it in one
# step. Terraform emits the pair in either order depending on whether the
# resource sets create_before_destroy.
REPLACE_ACTIONS = ({"delete", "create"},)

# Types whose replacement is data loss rather than churn. Replacing one of
# these is the catastrophe deploy#1588 was filed for.
PROTECTED_TYPES = {
    "aws_s3_bucket": "holds the append-only audit log and the OpenBao KEK archive",
    "aws_dynamodb_table": "holds terraform state locks",
    "aws_kms_key": "decrypts every object written under it",
}

CYCLE_RE = re.compile(r"^\s*Error: Cycle:", re.M)


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def load_plan(path: pathlib.Path) -> dict:
    if not path.is_file():
        fail(
            f"{path} does not exist. `terraform show -json` writes it only after "
            f"a plan succeeds, so a missing file usually means the plan itself "
            f"failed — re-run with --plan-log to see why."
        )
    try:
        plan = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(f"{path} is not valid JSON ({exc}). Expected `terraform show -json` output.")
    if "resource_changes" not in plan:
        # A reach floor: an unrecognised shape must fail, never silently pass.
        fail(
            f"GUARD BROKEN: {path} has no `resource_changes` key. Either the plan "
            f"is empty or the `terraform show -json` schema changed "
            f"(format_version={plan.get('format_version', 'absent')})."
        )
    return plan


def check_cycle(log_path: pathlib.Path | None) -> None:
    """A dependency cycle aborts the plan, so it is only visible in the log."""
    if log_path is None:
        return
    if not log_path.is_file():
        fail(f"--plan-log {log_path} does not exist")
    text = log_path.read_text()
    if CYCLE_RE.search(text):
        cycle = "\n".join(
            line for line in text.splitlines() if "Cycle:" in line or line.startswith("module.")
        )
        fail(
            "terraform plan hit a dependency cycle — this is deploy#1588 defect 1, "
            f"and the full apply cannot complete while it holds:\n{cycle}"
        )


def check_replacements(plan: dict) -> None:
    replaced = [
        change
        for change in plan["resource_changes"]
        if set(change.get("change", {}).get("actions", [])) in REPLACE_ACTIONS
    ]
    if not replaced:
        return

    protected = [c for c in replaced if c["type"] in PROTECTED_TYPES]
    lines = []
    for change in protected:
        lines.append(f"  {change['address']}  — {PROTECTED_TYPES[change['type']]}")
    for change in replaced:
        if change not in protected:
            lines.append(f"  {change['address']}")

    detail = "\n".join(lines)
    if protected:
        fail(
            "the plan REPLACES resources that hold data which cannot be "
            "recreated — this is deploy#1588 defect 2. Do not apply:\n"
            f"{detail}"
        )
    fail(f"the plan replaces {len(replaced)} resource(s):\n{detail}")


# Actions that can only appear when the workspace already manages something.
# `create` alone cannot: it is what an empty workspace plans for every resource.
# `read` alone cannot either: that is a data source, which is resolved on every
# plan whether or not any resource exists.
PRE_EXISTING_ACTIONS = {"no-op", "update", "delete"}


def check_measurable(plan: dict) -> None:
    """Refuse to pass a plan that had nothing to measure.

    A replace is a `delete` and a `create` on one address. A workspace with no
    prior state has nothing to delete, so `check_replacements` is satisfied by
    construction and the run is green without having tested anything.
    """
    changes = plan["resource_changes"]
    pre_existing = [
        c
        for c in changes
        if PRE_EXISTING_ACTIONS & set(c.get("change", {}).get("actions", []))
    ]
    if pre_existing:
        return

    creates = sum(1 for c in changes if c["change"]["actions"] == ["create"])
    fail(
        f"the plan manages no existing resource ({creates} to add, 0 to change, "
        f"0 to destroy), so it PROVED NOTHING. A replace set needs something to "
        f"replace, so this plan could not have failed whatever the configuration "
        f"says. Blocker 1 is not passing — it is unmeasured.\n"
        f"  Stage 1 is torn down, or this plan ran against the wrong backend. "
        f"Stand stage 1 up, or point the exit test at a workspace that has state."
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan_json", type=pathlib.Path, help="`terraform show -json` output")
    parser.add_argument(
        "--plan-log",
        type=pathlib.Path,
        default=None,
        help="captured stdout+stderr of `terraform plan`, so a cycle can be named",
    )
    args = parser.parse_args()

    check_cycle(args.plan_log)
    plan = load_plan(args.plan_json)
    # Order matters: prove the plan could have failed before reporting that it
    # did not.
    check_measurable(plan)
    check_replacements(plan)

    changes = plan["resource_changes"]
    actions = [c["change"]["actions"] for c in changes]
    creates = sum(1 for a in actions if a == ["create"])
    updates = sum(1 for a in actions if a == ["update"])
    deletes = sum(1 for a in actions if a == ["delete"])
    buckets = sum(1 for c in changes if c["type"] == "aws_s3_bucket")
    noops = sum(1 for a in actions if a == ["no-op"])
    print(
        f"OK — plan is clean: {creates} to add, {updates} to change, {deletes} to "
        f"destroy, 0 to replace. {buckets} S3 bucket(s) present, none in the "
        f"replace set. {noops + updates + deletes} existing resource(s) in the "
        f"plan, so a replacement was possible and did not happen."
    )


if __name__ == "__main__":
    main()
