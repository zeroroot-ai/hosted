#!/usr/bin/env python3
"""tagged-survivors.py — count what a teardown left, from the tagging API.

Reads the JSON of `aws resourcegroupstaggingapi get-resources` on stdin and
prints one integer: the resources that carry Environment=<env> and that a
stage 1 teardown should have removed.

Three kinds of tagged resource are NOT survivors. The first live teardown of
staging (2026-10-06) found the first two. The drill of 2026-10-26 found the
third (run 40323162603):

1. Stage 0. The durable bucket and the delegated zone carry
   Environment=<env> too, and a teardown leaves them alone in both modes
   (ADR-0083). Stage 0 tags them Workspace=zeroroot-ai-<env>-substrate.

2. EC2 resources that are already gone. The tagging API keeps returning a
   terminated instance, its deleted volume and the rules of a deleted security
   group for a long time after the delete. The verify measures instances,
   volumes, addresses and VPCs exactly with the describe calls, which know the
   state. So an ARN of those types here is not counted again, and an ARN of a
   type that can exist only inside a VPC is not counted when the VPC count
   was zero.

3. The org root. bootstrap/eks/aws-org tags the permission boundary of the
   drill, PB-DrillBringup, with Environment=drill, so the drill can read its
   own boundary. The org root owns it, not stage 1, and a teardown never
   destroys it. The org root tags it Workspace=aws-org.

Each other ARN is a survivor.

Usage:
    aws resourcegroupstaggingapi get-resources ... --output json \\
      | tagged-survivors.py <env> <vpc count> [--list]
    tagged-survivors.py --selftest
Exit:
    0 the count is printed · 2 the input is not the API's JSON
"""

from __future__ import annotations

import json
import sys

# The Workspace tag of bootstrap/eks/aws-org (locals.tf, common_tags).
ORG_WORKSPACE = "aws-org"
# Measured exactly by the describe calls of ec2-post-destroy-verify.sh.
MEASURED = {"instance", "volume", "elastic-ip", "vpc"}
# A resource of these types cannot exist when its VPC does not.
IN_A_VPC = {
    "subnet", "route-table", "security-group", "security-group-rule",
    "network-interface", "network-acl", "vpc-endpoint",
}


def ec2_type(arn: str) -> str:
    # arn:aws:ec2:<region>:<account>:<type>/<id>
    parts = arn.split(":", 5)
    if len(parts) < 6 or parts[2] != "ec2":
        return ""
    return parts[5].split("/", 1)[0]


def survivors(doc: dict, env: str, vpcs: int) -> list[str]:
    durable = {f"zeroroot-ai-{env}-substrate", ORG_WORKSPACE}
    out = []
    for row in doc.get("ResourceTagMappingList", []):
        tags = {t.get("Key"): t.get("Value") for t in row.get("Tags", [])}
        if tags.get("Workspace") in durable:
            continue
        kind = ec2_type(row.get("ResourceARN", ""))
        if kind in MEASURED:
            continue
        if kind in IN_A_VPC and vpcs == 0:
            continue
        out.append(row.get("ResourceARN", "<no arn>"))
    return out


def row(arn: str, workspace: str) -> dict:
    return {"ResourceARN": arn, "Tags": [{"Key": "Environment", "Value": "staging"},
                                         {"Key": "Workspace", "Value": workspace}]}


def selftest() -> int:
    a = "arn:aws:ec2:us-east-1:1:"
    gone = {"ResourceTagMappingList": [
        row("arn:aws:s3:::zeroroot-ai-staging-durable-1", "zeroroot-ai-staging-substrate"),
        row("arn:aws:route53:::hostedzone/Z1", "zeroroot-ai-staging-substrate"),
        row(a + "instance/i-1", "zeroroot-ai-staging"),
        row(a + "volume/vol-1", "zeroroot-ai-staging"),
        row(a + "security-group-rule/sgr-1", "zeroroot-ai-staging"),
    ]}
    cases = [
        ("stage 0 and stale EC2 entries, no VPC", gone, 0, 0),
        ("a security group rule while a VPC remains", gone, 1, 1),
        ("an IAM role that the destroy missed",
         {"ResourceTagMappingList": gone["ResourceTagMappingList"]
          + [row("arn:aws:iam::1:role/zeroroot-ai-staging-node", "zeroroot-ai-staging")]}, 0, 1),
        ("the drill boundary of the org root",
         {"ResourceTagMappingList": gone["ResourceTagMappingList"]
          + [row("arn:aws:iam::1:policy/PB-DrillBringup", ORG_WORKSPACE)]}, 0, 0),
        ("the drill role and its boundary of the org root",
         {"ResourceTagMappingList": gone["ResourceTagMappingList"]
          + [row("arn:aws:iam::1:policy/PB-DrillBringup", ORG_WORKSPACE),
             row("arn:aws:iam::1:role/drill-bringup", ORG_WORKSPACE)]}, 0, 0),
        ("a missed role with a Workspace that only looks like the org root",
         {"ResourceTagMappingList": [row("arn:aws:iam::1:role/x", ORG_WORKSPACE + "-x")]}, 0, 1),
        ("a policy of stage 1, not of the org root",
         {"ResourceTagMappingList": [row("arn:aws:iam::1:policy/PB-DrillBringup", "zeroroot-ai-staging")]}, 0, 1),
        ("a bucket of stage 1, not stage 0",
         {"ResourceTagMappingList": [row("arn:aws:s3:::x", "zeroroot-ai-staging")]}, 0, 1),
    ]
    for name, doc, vpcs, want in cases:
        got = len(survivors(doc, "staging", vpcs))
        if got != want:
            print(f"tagged-survivors: selftest: {name}: got {got}, want {want}", file=sys.stderr)
            return 2
    print("✅ self-test: stage 0, the org root and stale EC2 entries are not survivors; a missed role, "
          "a stage 1 policy, a stage 1 bucket and a rule in a live VPC are")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:2] == ["--selftest"]:
        return selftest()
    if len(argv) < 3 or not argv[2].isdigit():
        print("usage: tagged-survivors.py <env> <vpc count> [--list]", file=sys.stderr)
        return 2
    try:
        doc = json.load(sys.stdin)
    except ValueError:
        return 2
    if not isinstance(doc, dict) or "ResourceTagMappingList" not in doc:
        return 2
    found = survivors(doc, argv[1], int(argv[2]))
    if "--list" in argv[3:]:
        for arn in found:
            print(arn)
    else:
        print(len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
