#!/usr/bin/env python3
"""Guard: in bootstrap/ec2/gibson, Argo CD is destroyed before the path to the API.

The EC2 root (staging and drill) publishes no API port. The bringup verbs reach
the Kubernetes API only through an SSM port forward, and SSM needs the node's
way out. A destroy removes Argo CD through that forward. So module "argocd"
must depend on every resource of the node's way out, or Terraform destroys
that resource in parallel with the Argo CD release and the release delete
fails when the SSM session loses its network.

Measured 2026-10-06 on the staging rebuild: `depends_on` named only the address
association. The destroy removed the egress rule and the route table
association at the same time as the release, and stopped on
"failed to delete release: argocd".

WHAT IT CHECKS
    Each resource of these types that the root declares is in the depends_on
    list of module "argocd":
        aws_eip_association, aws_route, aws_route_table_association,
        aws_vpc_security_group_egress_rule, aws_iam_role_policy_attachment
    The check reads the types from the Terraform text, so a new resource of
    one of these types is covered with no change to this file.

Usage:
    scripts/check-ec2-argocd-depends-on.py             # the guard
    scripts/check-ec2-argocd-depends-on.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 a rule is broken · 2 the self-test is broken or nothing was read

The fixtures are in tests/guards/ec2-argocd-depends-on/.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EC2_DIR = ROOT / "bootstrap" / "ec2" / "gibson"
FIXTURES = ROOT / "tests" / "guards" / "ec2-argocd-depends-on"

PATH_TYPES = (
    "aws_eip_association",
    "aws_route",
    "aws_route_table_association",
    "aws_vpc_security_group_egress_rule",
    "aws_iam_role_policy_attachment",
)

RESOURCE = re.compile(r'^resource\s+"([a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"', re.M)
MODULE = re.compile(r'^module\s+"argocd"\s*\{(.*?)^\}', re.S | re.M)
DEPENDS = re.compile(r'depends_on\s*=\s*\[(.*?)\]', re.S)
REF = re.compile(r'\b([a-z0-9_]+\.[A-Za-z0-9_-]+)\b')


def strip_comments(text: str) -> str:
    out = []
    for line in text.splitlines():
        cut = line.split("#", 1)[0]
        out.append(cut)
    return "\n".join(out)


def findings(root: pathlib.Path) -> list[str]:
    resources: set[str] = set()
    module_bodies: list[str] = []
    for tf in sorted(root.glob("*.tf")):
        text = strip_comments(tf.read_text(encoding="utf-8"))
        for kind, name in RESOURCE.findall(text):
            if kind in PATH_TYPES:
                resources.add(f"{kind}.{name}")
        module_bodies += MODULE.findall(text)

    if not module_bodies:
        return [f"{root}: no module \"argocd\" was found, so the check did not look at anything"]
    if not resources:
        return [f"{root}: no resource of the types {list(PATH_TYPES)} was found, so the check did not look at anything"]

    dep = DEPENDS.search(module_bodies[0])
    listed = set(REF.findall(dep.group(1))) if dep else set()
    return [
        f"module \"argocd\" does not depend on {r}. A destroy can remove it while the "
        "Argo CD release is deleted through the SSM forward. Add it to depends_on"
        for r in sorted(resources - listed)
    ]


def selftest() -> int:
    cases = {"good": 0, "bad-address-only": 1, "bad-no-depends-on": 1}
    for name, want in cases.items():
        d = FIXTURES / name
        if not d.is_dir():
            print(f"check-ec2-argocd-depends-on: selftest: the fixture {name} is missing", file=sys.stderr)
            return 2
        got = findings(d)
        if (len(got) > 0) != (want > 0):
            print(f"check-ec2-argocd-depends-on: selftest: {name} gave {got}", file=sys.stderr)
            return 2
    print("✅ self-test: a depends_on with only the address association, and no depends_on, are each rejected")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    got = findings(EC2_DIR)
    if got:
        print("check-ec2-argocd-depends-on: bootstrap/ec2/gibson:", file=sys.stderr)
        for g in got:
            print(f"  {g}", file=sys.stderr)
        return 1
    print("✅ module \"argocd\" in bootstrap/ec2/gibson depends on each resource of the path to the API")
    return 0


if __name__ == "__main__":
    sys.exit(main())
