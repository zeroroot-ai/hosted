#!/usr/bin/env python3
"""check-keyring-secret.py: only the intended roles reach a keyring secret
(ADR-0083, amendment of 2026-10-22).

The secret zeroroot-ai/<env>/keyring (substrate/gibson-bootstrap/
keyring-secret.tf) holds the bringup keyring of an environment. Staging, prod
and drill share one AWS account. The bringup role (eks-bringup) trusts the
GitHub environments of staging and prod, and staging has no required reviewer,
so no bringup role may reach the keyring of staging or prod. Who may reach it:

  - the operator role OrganizationAccountAccessRole, read and write;
  - the drill role drill-bringup, for drill only (envs/drill.tfvars);
  - the key rotation role of the environment, read and write, from
    rotate-credentials.yml only (rotation-role.tf);
  - the keyring reader role of the environment, read only, from preflight.yml,
    recreate.yml and teardown.yml only (keyring-reader-role.tf).

What fails, keyed by content:

  1. the default of var.keyring_principal_role_names (variables.tf) is not
     exactly [OrganizationAccountAccessRole];
  2. an envs/<env>.tfvars other than drill sets keyring_principal_role_names, or
     drill sets it to something but the two roles;
  3. keyring-secret.tf takes a principal from anything but that variable;
  4. a trust policy of the rotation or reader role names a `sub` other than the
     one GitHub environment of its own environment (var.environment), uses a
     wildcard condition, does not pin the ref to main, or names another set of
     workflow files than its own;
  5. a file of the stage 0 root other than rotation-role.tf and
     keyring-reader-role.tf grants secretsmanager:GetSecretValue or
     secretsmanager:PutSecretValue on the keyring secret or on "*" (the edge
     certificate secret has its own grant), a grant in those two is on anything
     but this environment's keyring secret, or the reader role grants a write.

Usage:  scripts/check-keyring-secret.py [--selftest]
Exit:   0 clean, 1 a rule is broken, 2 the self-test is broken or a file is missing
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TF = ROOT / "substrate" / "gibson-bootstrap"
OPERATOR = "OrganizationAccountAccessRole"
DRILL_WANT = sorted([OPERATOR, "drill-bringup"])
WORKFLOWS = {
    "rotation-role.tf": ("rotation_job_workflow_refs", ["rotate-credentials.yml"]),
    "keyring-reader-role.tf": ("keyring_reader_job_workflow_refs", ["preflight.yml", "recreate.yml", "teardown.yml"]),
}
SUB = 'repo:${var.github_repository}:environment:${var.environment}'
SECRET_ACTIONS = re.compile(r"secretsmanager:(Get|Put)SecretValue|secretsmanager:\*", re.I)


def strip(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def strings(block: str) -> list[str]:
    return sorted(re.findall(r'"([^"]+)"', block))


def var_findings(variables: str) -> list[str]:
    m = re.search(r'variable\s+"keyring_principal_role_names"\s*\{(.*?)\n\}', variables, re.S)
    if not m:
        return ["variables.tf declares no keyring_principal_role_names"]
    d = re.search(r"default\s*=\s*\[(.*?)\]", m.group(1), re.S)
    if not d or strings(d.group(1)) != [OPERATOR]:
        return [f"the default of keyring_principal_role_names is not exactly [{OPERATOR!r}]"]
    return []


def tfvars_findings(text: str, name: str) -> list[str]:
    m = re.search(r"^\s*keyring_principal_role_names\s*=\s*\[(.*?)\]", strip(text), re.S | re.M)
    if not m:
        return []
    if name != "envs/drill.tfvars":
        return [f"{name} sets keyring_principal_role_names: only drill may add a role, its own drill-bringup"]
    if strings(m.group(1)) != DRILL_WANT:
        return [f"{name} sets keyring_principal_role_names to {strings(m.group(1))}, not {DRILL_WANT}"]
    return []


def tf_findings(text: str) -> list[str]:
    code = strip(text)
    ids = re.findall(r"identifiers\s*=\s*(\[[^\]]*\])", code)
    if not ids or any("data.aws_iam_role.keyring" not in i for i in ids if i.strip() != '["*"]'):
        return ["keyring-secret.tf takes a principal from something other than var.keyring_principal_role_names"]
    if "var.keyring_principal_role_names" not in code:
        return ["keyring-secret.tf does not read var.keyring_principal_role_names"]
    return []


def trust_findings(text: str, name: str) -> list[str]:
    """The trust policy of the rotation role or the reader role."""
    code = strip(text)
    out = []
    # Each condition block: test, variable, values.
    conds = re.findall(r'condition\s*\{\s*test\s*=\s*"([^"]+)"\s*variable\s*=\s*"([^"]+)"\s*values\s*=\s*(\[[^\]]*\])', code, re.S)
    by_var = {}
    for test, var, values in conds:
        by_var.setdefault(var.rsplit(":", 1)[-1], []).append((test, strings(values)))
    sub = by_var.get("sub", [])
    if len(sub) != 1 or sub[0][0] != "StringEquals" or sub[0][1] != [SUB]:
        out.append(f"{name}: the sub condition is not one StringEquals on {SUB}, so another environment could assume the role")
    ref = by_var.get("ref", [])
    if len(ref) != 1 or ref[0][0] != "StringEquals" or ref[0][1] != ["refs/heads/main"]:
        out.append(f"{name}: the ref condition is not StringEquals refs/heads/main")
    if any(t.startswith("StringLike") or t == "ForAnyValue:StringLike" for t, _, _ in conds):
        out.append(f"{name}: a trust condition uses StringLike (a wildcard)")
    local, want = WORKFLOWS[name]
    m = re.search(local + r"\s*=\s*\[(.*?)\]", code, re.S)
    got = sorted(re.findall(r"/\.github/workflows/([\w.-]+\.ya?ml)@refs/heads/main", m.group(1))) if m else None
    if got != sorted(want):
        out.append(f"{name}: {local} names {got}, not {sorted(want)}")
    if "job_workflow_ref" not in code or local not in code:
        out.append(f"{name}: the trust policy does not pin job_workflow_ref to {local}")
    return out


def grant_findings(files: dict[str, str]) -> list[str]:
    """Who may grant a read or a write of a secret value."""
    out = []
    for name, text in files.items():
        code = strip(text)
        if not SECRET_ACTIONS.search(code):
            continue
        if name not in WORKFLOWS:
            if name == "keyring-secret.tf":
                continue
            for m in re.finditer(r"statement\s*\{(.*?)\n  \}", code, re.S):
                body = m.group(1)
                res = re.search(r"resources\s*=\s*(\[[^\]]*\])", body, re.S)
                # A resource policy (a statement with principals) is about its own secret.
                if "principals" in body:
                    continue
                if SECRET_ACTIONS.search(body) and res and ("keyring" in res.group(1) or '"*"' in res.group(1)):
                    out.append(f"{name}: grants a secret value action on the keyring secret or on every secret, and only rotation-role.tf and keyring-reader-role.tf may")
            continue
        for m in re.finditer(r"statement\s*\{(.*?)\n  \}", code, re.S):
            body = m.group(1)
            if not SECRET_ACTIONS.search(body):
                continue
            res = re.search(r"resources\s*=\s*(\[[^\]]*\])", body, re.S)
            if not res or [r.strip() for r in re.findall(r"[^\s\[\],]+", res.group(1))] != ["aws_secretsmanager_secret.keyring.arn"]:
                out.append(f"{name}: a secret value grant is on something other than aws_secretsmanager_secret.keyring.arn")
        if name == "keyring-reader-role.tf" and re.search(r"PutSecretValue|secretsmanager:\*", code):
            out.append(f"{name}: the reader role grants a write")
    return out


def selftest() -> int:
    good_var = 'variable "keyring_principal_role_names" {\n  type = list(string)\n  default = ["OrganizationAccountAccessRole"]\n}\n'
    good_tf = ('for_each = toset(var.keyring_principal_role_names)\n'
               'identifiers = [for r in data.aws_iam_role.keyring : r.arn]\nidentifiers = ["*"]\n')
    good_trust = '''
  condition {
    test     = "StringEquals"
    variable = "token.actions.githubusercontent.com:sub"
    values   = ["repo:${var.github_repository}:environment:${var.environment}"]
  }
  condition {
    test     = "StringEquals"
    variable = "token.actions.githubusercontent.com:ref"
    values   = ["refs/heads/main"]
  }
  condition {
    test     = "StringEquals"
    variable = "token.actions.githubusercontent.com:job_workflow_ref"
    values   = local.rotation_job_workflow_refs
  }
locals {
  rotation_job_workflow_refs = [
    "${var.github_repository}/.github/workflows/rotate-credentials.yml@refs/heads/main",
  ]
}
'''
    good_grant = '''
  statement {
    sid       = "ReadAndWriteTheKeyring"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.keyring.arn]
  }
'''
    rot = "rotation-role.tf"
    bad = [
        ("a bringup role in the default", lambda: var_findings(good_var.replace('["OrganizationAccountAccessRole"]', '["eks-bringup", "OrganizationAccountAccessRole"]')), "not exactly"),
        ("no operator role in the default", lambda: var_findings(good_var.replace('"OrganizationAccountAccessRole"', '"x"')), "not exactly"),
        ("staging adds the bringup role", lambda: tfvars_findings('keyring_principal_role_names = ["OrganizationAccountAccessRole", "eks-bringup"]\n', "envs/staging.tfvars"), "only drill may"),
        ("prod sets the list", lambda: tfvars_findings('keyring_principal_role_names = ["eks-bringup"]\n', "envs/prod.tfvars"), "only drill may"),
        ("drill sets another list", lambda: tfvars_findings('keyring_principal_role_names = ["drill-bringup", "x"]\n', "envs/drill.tfvars"), "not ["),
        ("drill adds the bringup role of staging and prod", lambda: tfvars_findings('keyring_principal_role_names = ["OrganizationAccountAccessRole", "eks-bringup"]\n', "envs/drill.tfvars"), "not ["),
        ("another principal in the secret policy", lambda: tf_findings(good_tf + 'identifiers = ["arn:aws:iam::1:role/x"]\n'), "something other than"),
        ("a sub that names another environment", lambda: trust_findings(good_trust.replace("${var.environment}", "staging"), rot), "sub condition"),
        ("a sub with a wildcard", lambda: trust_findings(good_trust.replace('"StringEquals"\n    variable = "token.actions.githubusercontent.com:sub"', '"StringLike"\n    variable = "token.actions.githubusercontent.com:sub"'), rot), "sub condition"),
        ("two sub values", lambda: trust_findings(good_trust.replace('environment:${var.environment}"]', 'environment:${var.environment}", "repo:x:environment:prod"]'), rot), "sub condition"),
        ("a ref that is not main", lambda: trust_findings(good_trust.replace("refs/heads/main\"]\n  }\n  condition {\n    test     = \"StringEquals\"\n    variable = \"token.actions.githubusercontent.com:job", "refs/heads/dev\"]\n  }\n  condition {\n    test     = \"StringEquals\"\n    variable = \"token.actions.githubusercontent.com:job"), rot), "ref condition"),
        ("another workflow file in the list", lambda: trust_findings(good_trust.replace("rotate-credentials.yml@", "drill.yml@"), rot), "names"),
        ("a grant in another file", lambda: grant_findings({"inbox.tf": good_grant}), "only rotation-role.tf"),
        ("a grant on every secret", lambda: grant_findings({rot: good_grant.replace("aws_secretsmanager_secret.keyring.arn", '"*"')}), "other than"),
        ("a reader that writes", lambda: grant_findings({"keyring-reader-role.tf": good_grant}), "reader role grants a write"),
    ]
    if (var_findings(good_var) or tf_findings(good_tf) or tfvars_findings('environment = "x"\n', "envs/x.tfvars")
            or tfvars_findings('keyring_principal_role_names = ["OrganizationAccountAccessRole", "drill-bringup"]\n', "envs/drill.tfvars")
            or trust_findings(good_trust, rot) or grant_findings({rot: good_grant})):
        print("check-keyring-secret: selftest: a good fixture failed", file=sys.stderr)
        return 2
    for label, fn, want in bad:
        got = fn()
        if not any(want in g for g in got):
            print(f"check-keyring-secret: selftest: '{label}' did not raise {want!r}: {got}", file=sys.stderr)
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
        for name in WORKFLOWS:
            got += trust_findings((TF / name).read_text(encoding="utf-8"), name)
        got += grant_findings({p.name: p.read_text(encoding="utf-8") for p in sorted(TF.glob("*.tf"))})
    except OSError as exc:
        print(f"check-keyring-secret: {exc}", file=sys.stderr)
        return 2
    if got:
        print("check-keyring-secret:", *got, sep="\n  ", file=sys.stderr)
        return 1
    print("✅ the keyring secret is reached by the operator role, the drill role for drill only, and the two roles of its own environment")
    return 0


if __name__ == "__main__":
    sys.exit(main())
