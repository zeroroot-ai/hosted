#!/usr/bin/env python3
"""check-iam-arn-service.py: each ARN in an IAM policy names a literal service.

IAM refuses a policy whose Resource or NotResource ARN has a wildcard in the
service segment ("arn:aws:*:..."): MalformedPolicyDocument, "Resource vendor
must be fully qualified and cannot contain regexes". terraform plan, the IAM
policy simulator and Access Analyzer validate-policy all accept such a policy,
so the error shows only at apply (PB-DrillBringup, hosted#106).

The guard reads every *.tf and *.json file under bootstrap/ and substrate/ and
fails on each string that starts an ARN with a wildcard service.

Usage: scripts/check-iam-arn-service.py [--selftest]
Exit:  0 clean, 1 a wildcard service, 2 the self-test is broken
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIRS = [ROOT / "bootstrap", ROOT / "substrate"]
# arn:<partition>:<service>: where the service holds a * or a ?. The partition
# may be a literal or a Terraform interpolation.
BAD = re.compile(r'"arn:(?:aws[a-z-]*|\$\{[^}]*\}):[a-z0-9-]*[*?][a-z0-9*?-]*:')


def findings(text: str, name: str) -> list[str]:
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        code = line.split("#", 1)[0] if name.endswith(".tf") else line
        if BAD.search(code):
            out.append(f"{name}:{n}: an ARN with a wildcard service: {code.strip()}")
    return out


def selftest() -> int:
    bad = [
        '    "arn:aws:*:*:*:*zeroroot-ai-prod*",',
        '  "Resource": "arn:aws:s*:::bucket"',
        '    "arn:${data.aws_partition.current.partition}:*:*:*:x",',
    ]
    good = [
        '    "arn:aws:s3:::zeroroot-ai-drill-*",',
        '    "arn:aws:secretsmanager:*:*:secret:zeroroot-ai/prod/*",',
        '  # "arn:aws:*:*:*:x" in a comment',
        '    "arn:${data.aws_partition.current.partition}:iam::aws:policy/X",',
    ]
    for line in bad:
        if not findings(line, "x.tf"):
            print(f"check-iam-arn-service: selftest: {line!r} passed", file=sys.stderr)
            return 2
    for line in good:
        if findings(line, "x.tf"):
            print(f"check-iam-arn-service: selftest: {line!r} failed", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bad)} ARNs with a wildcard service fail; {len(good)} good lines pass")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    got = []
    for d in DIRS:
        for p in sorted(list(d.rglob("*.tf")) + list(d.rglob("*.json"))):
            if ".terraform" in p.parts:
                continue
            got += findings(p.read_text(encoding="utf-8", errors="replace"), str(p.relative_to(ROOT)))
    if got:
        print("check-iam-arn-service: IAM refuses these at apply:", *got, sep="\n  ", file=sys.stderr)
        return 1
    print("✅ every ARN under bootstrap/ and substrate/ names a literal service")
    return 0


if __name__ == "__main__":
    sys.exit(main())
