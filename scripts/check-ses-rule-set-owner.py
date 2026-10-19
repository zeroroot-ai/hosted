#!/usr/bin/env python3
"""check-ses-rule-set-owner.py — the one SES receipt rule set belongs to
substrate/apex-zone, and no environment can create, change or destroy it
(hosted#647).

SES keeps ONE active receipt rule set per account and region, and staging,
drill and prod share one account and region. substrate/apex-zone owns the set
and its activation. Each environment's stage 0 adds only its own rule to it.
A teardown of one environment must never touch the set: the inbox of every
other environment hangs off it.

What fails, keyed by content:

  1. A Terraform root other than substrate/apex-zone declares an
     aws_ses_receipt_rule_set or an aws_ses_active_receipt_rule_set.
  2. substrate/apex-zone declares no rule set, or no activation.
  3. --plan <plan.json>: a plan (`terraform show -json`) of any root other
     than substrate/apex-zone that creates, updates or deletes either kind.
     substrate.sh and the teardown verbs can run it on the plan they apply.

Usage:
  scripts/check-ses-rule-set-owner.py                 # the source guard
  scripts/check-ses-rule-set-owner.py --plan p.json   # one plan
  scripts/check-ses-rule-set-owner.py --selftest      # prove it can fail
Exit: 0 clean, 1 a rule is broken, 2 the self-test is broken or nothing was read
"""
from __future__ import annotations

import json
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OWNER = pathlib.Path("substrate") / "apex-zone"
KINDS = ("aws_ses_receipt_rule_set", "aws_ses_active_receipt_rule_set")
RESOURCE = re.compile(r'^\s*resource\s+"(aws_ses_receipt_rule_set|aws_ses_active_receipt_rule_set)"\s+"([^"]+)"', re.M)


def source_findings(root: pathlib.Path) -> list[str]:
    out, owner_kinds, scanned = [], set(), 0
    for tf in sorted(root.rglob("*.tf")):
        rel = tf.relative_to(root)
        if ".terraform" in rel.parts or ".worktrees" in rel.parts or rel.parts[0] == "tests":
            continue
        scanned += 1
        text = "\n".join(line.split("#", 1)[0] for line in tf.read_text(encoding="utf-8").splitlines())
        for kind, name in RESOURCE.findall(text):
            if rel.parent == OWNER:
                owner_kinds.add(kind)
            else:
                out.append(f"{rel} declares {kind}.{name}. The one rule set of the account belongs to "
                           f"{OWNER}; an environment adds only an aws_ses_receipt_rule (hosted#647)")
    if scanned == 0:
        return [f"{root}: no .tf file was read, so the check did not look at anything"]
    for kind in KINDS:
        if kind not in owner_kinds:
            out.append(f"{OWNER} declares no {kind}. The inbox rules of every environment need it (hosted#647)")
    return out


def plan_findings(plan: dict, label: str) -> list[str]:
    out = []
    for rc in plan.get("resource_changes", []):
        if rc.get("type") in KINDS:
            actions = rc.get("change", {}).get("actions", [])
            if actions and actions != ["no-op"] and actions != ["read"]:
                out.append(f"{label}: the plan would {'/'.join(actions)} {rc.get('address')}. "
                           f"Only {OWNER} changes the rule set of the account (hosted#647)")
    return out


def selftest() -> int:
    with tempfile.TemporaryDirectory() as t:
        r = pathlib.Path(t)
        owner = r / OWNER
        owner.mkdir(parents=True)
        (owner / "inbox.tf").write_text(
            'resource "aws_ses_receipt_rule_set" "inbox" {}\nresource "aws_ses_active_receipt_rule_set" "inbox" {}\n')
        env = r / "substrate" / "gibson-bootstrap"
        env.mkdir(parents=True)
        (env / "inbox.tf").write_text('resource "aws_ses_receipt_rule" "inbox" {}\n')
        if source_findings(r):
            print("check-ses-rule-set-owner: selftest: a good tree failed", file=sys.stderr)
            return 2
        (env / "bad.tf").write_text('resource "aws_ses_receipt_rule_set" "mine" {}\n')
        if not source_findings(r):
            print("check-ses-rule-set-owner: selftest: an environment rule set passed", file=sys.stderr)
            return 2
        (env / "bad.tf").unlink()
        (owner / "inbox.tf").write_text('resource "aws_ses_receipt_rule_set" "inbox" {}\n')
        if not source_findings(r):
            print("check-ses-rule-set-owner: selftest: an owner with no activation passed", file=sys.stderr)
            return 2
    destroy = {"resource_changes": [{"address": "aws_ses_receipt_rule_set.inbox",
                                     "type": "aws_ses_receipt_rule_set",
                                     "change": {"actions": ["delete"]}}]}
    if not plan_findings(destroy, "teardown"):
        print("check-ses-rule-set-owner: selftest: a teardown plan that destroys the rule set passed", file=sys.stderr)
        return 2
    rule = {"resource_changes": [{"address": "aws_ses_receipt_rule.inbox", "type": "aws_ses_receipt_rule",
                                  "change": {"actions": ["delete"]}}]}
    if plan_findings(rule, "teardown"):
        print("check-ses-rule-set-owner: selftest: a plan that removes only the env rule failed", file=sys.stderr)
        return 2
    print("✅ self-test: an environment rule set, an owner with no activation, and a plan that destroys the set are each rejected")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    if "--plan" in argv:
        path = pathlib.Path(argv[argv.index("--plan") + 1])
        got = plan_findings(json.loads(path.read_text(encoding="utf-8")), str(path))
    else:
        got = source_findings(ROOT)
    if got:
        for g in got:
            print(f"check-ses-rule-set-owner: {g}", file=sys.stderr)
        return 1
    print("✅ the one SES receipt rule set belongs to substrate/apex-zone, and no environment changes it")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
