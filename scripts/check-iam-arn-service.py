#!/usr/bin/env python3
"""check-iam-arn-service.py: each ARN in an IAM policy names a literal service,
and each policy template fits the IAM size limit.

IAM refuses a policy whose Resource or NotResource ARN has a wildcard in the
service segment ("arn:aws:*:..."): MalformedPolicyDocument, "Resource vendor
must be fully qualified and cannot contain regexes". terraform plan, the IAM
policy simulator and Access Analyzer validate-policy all accept such a policy,
so the error shows only at apply (PB-DrillBringup, hosted#106).

The guard reads every *.tf, *.json and *.json.tftpl file under bootstrap/ and
substrate/ and fails on each string that starts an ARN with a wildcard service.

It also renders each policy template under bootstrap/eks/aws-org/policies/
(*.json.tftpl) with a 12-digit account, the longest region name and a zone
name, and fails when the compact JSON (no whitespace) reaches MAX_CHARS. IAM
refuses a managed policy over 6144 characters, also only at apply. MAX_CHARS
keeps a margin under that limit.

Usage: scripts/check-iam-arn-service.py [--selftest]
Exit:  0 clean, 1 a wildcard service or a template too large, 2 the self-test is broken
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIRS = [ROOT / "bootstrap", ROOT / "substrate"]
TEMPLATES = ROOT / "bootstrap/eks/aws-org/policies"
IAM_LIMIT = 6144
MAX_CHARS = 5800
# The longest values that a template can get: a 12-digit account, the longest
# region name, and a zone name longer than any that drill uses.
SAMPLE = {"account_id": "123456789012", "region": "ap-southeast-4", "drill_zone_name": "drill.example-zone-name.ai"}
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


def render(template: str) -> str:
    """The compact JSON of a template, as Terraform templatefile renders it."""
    text = re.sub(r"\$\{(\w+)\}", lambda m: SAMPLE[m.group(1)], template)
    return json.dumps(json.loads(text), separators=(",", ":"))


def size_findings(template: str, name: str) -> list[str]:
    try:
        n = len(render(template))
    except (KeyError, ValueError) as exc:
        return [f"{name}: does not render to JSON with {sorted(SAMPLE)}: {exc}"]
    if n >= MAX_CHARS:
        return [f"{name}: renders to {n} characters, and the limit of this guard is {MAX_CHARS} (IAM refuses over {IAM_LIMIT})"]
    return []


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
    small = '{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"s3:*","Resource":"arn:aws:s3:::${drill_zone_name}"}]}'
    large = small.replace('"s3:*"', "[" + ",".join(f'"s3:Get{i:04d}"' for i in range(600)) + "]")
    if size_findings(small, "small") or not size_findings(large, "large") or not size_findings('{"x": "${nope}"}', "unknown"):
        print("check-iam-arn-service: selftest: the size check gave the wrong result", file=sys.stderr)
        return 2
    print(f"✅ self-test: {len(bad)} ARNs with a wildcard service fail; {len(good)} good lines pass; "
          "a template over the size limit and a template with an unknown variable fail")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    got = []
    for d in DIRS:
        for p in sorted(list(d.rglob("*.tf")) + list(d.rglob("*.json")) + list(d.rglob("*.json.tftpl"))):
            if ".terraform" in p.parts:
                continue
            got += findings(p.read_text(encoding="utf-8", errors="replace"), str(p.relative_to(ROOT)))
    sizes = []
    for p in sorted(TEMPLATES.glob("*.json.tftpl")):
        name = str(p.relative_to(ROOT))
        got += size_findings(p.read_text(encoding="utf-8"), name)
        try:
            sizes.append(f"{p.name} {len(render(p.read_text(encoding='utf-8')))}")
        except (KeyError, ValueError):
            pass
    if got:
        print("check-iam-arn-service: IAM refuses these at apply:", *got, sep="\n  ", file=sys.stderr)
        return 1
    print("✅ every ARN under bootstrap/ and substrate/ names a literal service; "
          f"each policy template is under {MAX_CHARS} characters ({', '.join(sizes)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
