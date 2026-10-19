#!/usr/bin/env python3
"""Guard: exactly two SCPs attach to the workload account (ADR-0073, hosted#418).

The org workspace (bootstrap/eks/aws-org/scps.tf) defines the service control
policies. Two of them attach directly to the workload account:
DenyRootUserActions and DenyRegionsExceptUSEast1. Two more policies existed
and attached only to an organizational unit that holds no account. The owner
deleted them on 2026-10-05.

WHAT IT CHECKS
    1. The policies that attach to aws_organizations_account.prod are exactly
       DenyRootUserActions and DenyRegionsExceptUSEast1.
    2. Each aws_organizations_policy resource has an attachment. A policy
       that attaches to nothing is refused.
    3. Each policy reads a JSON file that exists, and no JSON file of an SCP
       under policies/ is left with no policy that reads it.

It reads the Terraform text. It needs no AWS credential, so it runs in the
merge gate and in the guards job of exit-test-terraform.

Usage:
    scripts/check-scp-attachments.py             # the guard
    scripts/check-scp-attachments.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 a rule is broken · 2 the self-test is broken

The fixtures are in tests/guards/scp-attachments/.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ORG_DIR = ROOT / "bootstrap" / "eks" / "aws-org"
FIXTURES = ROOT / "tests" / "guards" / "scp-attachments"

ACCOUNT_TARGET = "aws_organizations_account.prod.id"
EXPECTED_ON_ACCOUNT = frozenset({"DenyRootUserActions", "DenyRegionsExceptUSEast1"})
# A JSON file under policies/ that is not an SCP body. An IAM policy reads it.
NOT_AN_SCP = frozenset({"permission-boundary-operator.json"})

BLOCK = re.compile(r'^resource\s+"(aws_organizations_policy(?:_attachment)?)"\s+"([^"]+)"\s*\{(.*?)^\}', re.S | re.M)


def strip_comments(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def parse(org_dir: pathlib.Path):
    """-> (policies {tf name: (SCP name, json file)}, attachments [(tf policy name, target)])."""
    policies: dict[str, tuple[str, str]] = {}
    attachments: list[tuple[str, str]] = []
    for tf in sorted(org_dir.glob("*.tf")):
        text = strip_comments(tf.read_text(encoding="utf-8"))
        for kind, name, body in BLOCK.findall(text):
            if kind == "aws_organizations_policy":
                scp = re.search(r'^\s*name\s*=\s*"([^"]+)"', body, re.M)
                src = re.search(r'policies/([A-Za-z0-9_.-]+\.json)', body)
                policies[name] = (scp.group(1) if scp else "", src.group(1) if src else "")
            else:
                pol = re.search(r'policy_id\s*=\s*aws_organizations_policy\.([A-Za-z0-9_]+)\.id', body)
                tgt = re.search(r'target_id\s*=\s*([A-Za-z0-9_.\[\]"]+)', body)
                attachments.append((pol.group(1) if pol else "", tgt.group(1) if tgt else ""))
    return policies, attachments


def findings(org_dir: pathlib.Path) -> list[str]:
    out: list[str] = []
    policies, attachments = parse(org_dir)
    if not policies:
        return [f"{org_dir}: no aws_organizations_policy resource was found, so the check did not look at anything"]

    on_account = {policies[p][0] for p, t in attachments if t == ACCOUNT_TARGET and p in policies}
    if on_account != EXPECTED_ON_ACCOUNT:
        out.append(
            "the policies that attach to the workload account are "
            f"{sorted(on_account)}, and ADR-0073 states {sorted(EXPECTED_ON_ACCOUNT)}"
        )
    account_rows = [p for p, t in attachments if t == ACCOUNT_TARGET]
    if len(account_rows) != len(set(account_rows)):
        out.append("a policy attaches to the workload account two times")

    attached = {p for p, _ in attachments}
    for tf_name, (scp, _) in sorted(policies.items()):
        if tf_name not in attached:
            out.append(f"the policy {scp or tf_name} attaches to nothing. Attach it or delete it")
    for p, _ in attachments:
        if p not in policies:
            out.append(f"an attachment names the policy {p or '<none>'}, which no resource defines")

    read = {src for _, src in policies.values() if src}
    pol_dir = org_dir / "policies"
    for tf_name, (scp, src) in sorted(policies.items()):
        if not src or not (pol_dir / src).is_file():
            out.append(f"the policy {scp or tf_name} reads policies/{src or '<none>'}, which does not exist")
    if pol_dir.is_dir():
        for f in sorted(pol_dir.glob("*.json")):
            if f.name not in read and f.name not in NOT_AN_SCP:
                out.append(f"policies/{f.name} is the body of no policy. Delete it")
    return out


def selftest() -> int:
    cases = {
        "good": 0,
        "bad-third-on-account": 1,
        "bad-attaches-to-nothing": 1,
        "bad-orphan-json": 1,
        "bad-one-on-account": 1,
    }
    for name, want in cases.items():
        d = FIXTURES / name
        if not d.is_dir():
            print(f"check-scp-attachments: selftest: the fixture {name} is missing", file=sys.stderr)
            return 2
        got = findings(d)
        if (len(got) > 0) != (want > 0):
            print(f"check-scp-attachments: selftest: {name} gave {got}", file=sys.stderr)
            return 2
    print("✅ self-test: a third policy on the account, one policy on the account, "
          "a policy that attaches to nothing and a JSON body with no policy are each rejected")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    got = findings(ORG_DIR)
    if got:
        print("check-scp-attachments: bootstrap/eks/aws-org breaks ADR-0073:", file=sys.stderr)
        for g in got:
            print(f"  {g}", file=sys.stderr)
        return 1
    policies, attachments = parse(ORG_DIR)
    print(f"✅ exactly two SCPs attach to the workload account: {sorted(EXPECTED_ON_ACCOUNT)}. "
          f"{len(policies)} policies, {len(attachments)} attachments, none attaches to nothing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
