#!/usr/bin/env python3
"""check-keyring-secret.py: the keyring secret has exactly two principals
(ADR-0083 amendment of 2026-10-13).

The secret zeroroot-ai/<env>/keyring (substrate/gibson-bootstrap/
keyring-secret.tf) holds the bringup keyring of each environment. Two roles read and
write it, and no other: eks-bringup (each drill job and the rotation), and
OrganizationAccountAccessRole (the operator role that runs
`make substrate ENV=drill` and writes the first value).

What fails, keyed by content:

  1. the default of var.keyring_principal_role_names (variables.tf) is not
     exactly those two roles;
  2. an envs/<env>.tfvars sets keyring_principal_role_names to another list;
  3. keyring-secret.tf takes its principals from anything but that variable.

Usage:  scripts/check-keyring-secret.py [--selftest]
Exit:   0 clean, 1 a rule is broken, 2 the self-test is broken or a file is missing
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TF = ROOT / "substrate" / "gibson-bootstrap"
WANT = ["OrganizationAccountAccessRole", "eks-bringup"]


def strings(block: str) -> list[str]:
    return sorted(re.findall(r'"([^"]+)"', block))


def var_findings(variables: str) -> list[str]:
    m = re.search(r'variable\s+"keyring_principal_role_names"\s*\{(.*?)\n\}', variables, re.S)
    if not m:
        return ["variables.tf declares no keyring_principal_role_names"]
    d = re.search(r"default\s*=\s*\[(.*?)\]", m.group(1), re.S)
    if not d or strings(d.group(1)) != WANT:
        return [f"the default of keyring_principal_role_names is not exactly {WANT}"]
    return []


def tfvars_findings(text: str, name: str) -> list[str]:
    m = re.search(r"^\s*keyring_principal_role_names\s*=\s*\[(.*?)\]", text, re.S | re.M)
    if m and strings(m.group(1)) != WANT:
        return [f"{name} sets keyring_principal_role_names to {strings(m.group(1))}, not {WANT}"]
    return []


def tf_findings(text: str) -> list[str]:
    code = "\n".join(l.split("#", 1)[0] for l in text.splitlines())
    ids = re.findall(r"identifiers\s*=\s*(\[[^\]]*\])", code)
    if not ids or any("data.aws_iam_role.keyring" not in i for i in ids if i.strip() != '["*"]'):
        return ["keyring-secret.tf takes a principal from something other than var.keyring_principal_role_names"]
    if "var.keyring_principal_role_names" not in code:
        return ["keyring-secret.tf does not read var.keyring_principal_role_names"]
    return []


def selftest() -> int:
    good_var = 'variable "keyring_principal_role_names" {\n  type = list(string)\n  default = ["eks-bringup", "OrganizationAccountAccessRole"]\n}\n'
    good_tf = ('for_each = toset(var.keyring_principal_role_names)\n'
               'identifiers = [for r in data.aws_iam_role.keyring : r.arn]\nidentifiers = ["*"]\n')
    bad = [
        (var_findings, good_var.replace('"OrganizationAccountAccessRole"', '"OrganizationAccountAccessRole", "ci-reader"'), "not exactly"),
        (var_findings, good_var.replace('"eks-bringup", ', ''), "not exactly"),
        (lambda s: tfvars_findings(s, "envs/drill.tfvars"), 'keyring_principal_role_names = ["eks-bringup", "x"]\n', "sets keyring_principal_role_names"),
        (tf_findings, good_tf + 'identifiers = ["arn:aws:iam::1:role/x"]\n', "something other than"),
    ]
    if var_findings(good_var) or tf_findings(good_tf) or tfvars_findings("environment = \"drill\"\n", "x"):
        print("check-keyring-secret: selftest: a good fixture failed", file=sys.stderr)
        return 2
    for fn, text, want in bad:
        got = fn(text)
        if not any(want in g for g in got):
            print(f"check-keyring-secret: selftest: a bad fixture did not raise {want!r}: {got}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bad)} bad fixtures each raise their rule; the good ones pass")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    try:
        got = var_findings((TF / "variables.tf").read_text(encoding="utf-8"))
        got += tf_findings((TF / "keyring-secret.tf").read_text(encoding="utf-8"))
        for f in sorted((TF / "envs").glob("*.tfvars")):
            got += tfvars_findings(f.read_text(encoding="utf-8"), f"envs/{f.name}")
    except OSError as exc:
        print(f"check-keyring-secret: {exc}", file=sys.stderr)
        return 2
    if got:
        print("check-keyring-secret:", *got, sep="\n  ", file=sys.stderr)
        return 1
    print(f"✅ the keyring secret has exactly two principals: {WANT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
