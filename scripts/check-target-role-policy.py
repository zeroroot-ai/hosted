#!/usr/bin/env python3
"""check-target-role-policy.py: the instance role of a target node is as narrow
as the node needs.

A target node (targets/<name>/) is meant to be broken into, and a break-out
reaches the instance role. So the policy that the role will carry must not
read parameters by a wildcard, must not grant a KMS action, and must not grant
every action.

The guard is an allowlist, and it judges the rendered policy, not text. Each
target root defines `local.instance_role_policy`, one JSON value built from
variables only. `terraform console` evaluates it for each envs/<env>.tfvars,
with no AWS credential, and the rules below read the JSON statements:

  1. An Allow statement grants only these actions: the Session Manager agent
     actions (ssm:UpdateInstanceInformation and the four ssmmessages channel
     actions) and ssm:GetParameters. Any other action fails, a wildcard action
     included.
  2. ssm:GetParameters names exactly one resource, an SSM parameter ARN, with
     no "*" and no "?" in it.
  3. No statement uses NotAction or NotResource.
  4. In a target root, every aws_iam_role_policy has `policy =
     local.instance_role_policy`, and no root has a policy attachment, a
     managed_policy_arns attribute or an inline_policy block. So no second
     policy escapes the render.

Usage: scripts/check-target-role-policy.py [--selftest]
Exit:  0 clean, 1 a rule is broken, 2 the self-test is broken or no target was read
The fixtures are in scripts/testdata/target-role-policy/.
"""
from __future__ import annotations

import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts/testdata/target-role-policy"
SESSION_ACTIONS = frozenset(a.lower() for a in (
    "ssm:UpdateInstanceInformation",
    "ssmmessages:CreateControlChannel",
    "ssmmessages:CreateDataChannel",
    "ssmmessages:OpenControlChannel",
    "ssmmessages:OpenDataChannel",
))
TOKEN_READ = "ssm:getparameters"
ALLOWED_ACTIONS = SESSION_ACTIONS | {TOKEN_READ}
POLICY_LOCAL = "local.instance_role_policy"


def as_list(v) -> list:
    return v if isinstance(v, list) else [v]


def violations(policy: dict) -> list[str]:
    bad: list[str] = []
    for i, st in enumerate(as_list(policy.get("Statement", []))):
        sid = st.get("Sid") or f"#{i}"
        for key in ("NotAction", "NotResource"):
            if key in st:
                bad.append(f"statement {sid}: {key} is refused")
        if st.get("Effect") != "Allow":
            continue
        actions = [str(a) for a in as_list(st.get("Action", []))]
        resources = [str(r) for r in as_list(st.get("Resource", []))]
        if not actions:
            bad.append(f"statement {sid}: an Allow statement with no Action")
        for a in actions:
            if a.lower() not in ALLOWED_ACTIONS:
                bad.append(f"statement {sid}: the action {a} is not in the allowlist")
        if TOKEN_READ in [a.lower() for a in actions]:
            wild = [r for r in resources if "*" in r or "?" in r]
            if wild:
                bad.append(f"statement {sid}: ssm:GetParameters on a resource with a wildcard: {', '.join(wild)}")
            if len(resources) != 1 or not re.fullmatch(r"arn:aws:ssm:[a-z0-9-]+:[0-9]{12}:parameter/[^*?]+", resources[0] if resources else ""):
                bad.append(f"statement {sid}: ssm:GetParameters must name exactly one SSM parameter ARN, got {resources}")
    return bad


def _blocks(code: str, kind: str) -> list[tuple[str, str]]:
    """(name, body) of each `resource "<kind>" "<name>" { ... }`, by brace depth."""
    out = []
    for m in re.finditer(r'resource\s+"%s"\s+"([^"]+)"\s*\{' % re.escape(kind), code):
        depth, i = 1, m.end()
        while i < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[i], 0)
            i += 1
        out.append((m.group(1), code[m.end():i - 1]))
    return out


def policy_resource_findings(tf_text: str, name: str) -> list[str]:
    code = "\n".join(line.split("#", 1)[0] for line in tf_text.splitlines())
    out = []
    for kind in ("aws_iam_role_policy_attachment", "aws_iam_policy_attachment"):
        if re.search(r'resource\s+"%s"' % kind, code):
            out.append(f"{name}: has a policy attachment ({kind})")
    if re.search(r"^\s*managed_policy_arns\s*=", code, re.M):
        out.append(f"{name}: attaches managed policies (managed_policy_arns)")
    if re.search(r"^\s*inline_policy\s*\{", code, re.M):
        out.append(f"{name}: has an inline_policy block on a role")
    for rname, body in _blocks(code, "aws_iam_role_policy"):
        if not re.search(r"^\s*policy\s*=\s*%s\s*$" % re.escape(POLICY_LOCAL), body, re.M):
            out.append(f"{name}: aws_iam_role_policy.{rname} does not use {POLICY_LOCAL}, so its policy escapes the render")
    return out


def render(target: pathlib.Path, tfvars: pathlib.Path) -> dict:
    """The rendered instance role policy of one target and one env."""
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp) / "t"
        shutil.copytree(target, work, ignore=shutil.ignore_patterns(".terraform", "*.tfstate*"))
        (work / "backend_override.tf").write_text(
            'terraform {\n  backend "local" {\n    path = "%s/s.tfstate"\n  }\n}\n' % tmp)
        init = subprocess.run(["terraform", f"-chdir={work}", "init", "-input=false", "-no-color"],
                              capture_output=True, text=True)
        if init.returncode != 0:
            raise RuntimeError(f"terraform init failed for {target.name}: {init.stderr.strip()[:300]}")
        out = subprocess.run(["terraform", f"-chdir={work}", "console", "-no-color", f"-var-file={tfvars.relative_to(target)}"],
                             input="local.instance_role_policy\n", capture_output=True, text=True)
        text = out.stdout.strip()
        if out.returncode != 0 or not text.startswith('"'):
            raise RuntimeError(f"{target.name} {tfvars.name}: local.instance_role_policy did not render ({text[:120]} {out.stderr.strip()[:200]})")
        return json.loads(json.loads(text))


def selftest() -> int:
    good = sorted(FIXTURES.glob("good-*.json"))
    bads = sorted(FIXTURES.glob("bad-*.json"))
    if not good or len(bads) < 12:
        print("check-target-role-policy: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for g in good:
        v = violations(json.loads(g.read_text()))
        if v:
            print(f"check-target-role-policy: selftest: {g.name} gave {v}", file=sys.stderr)
            return 2
    for b in bads:
        if not violations(json.loads(b.read_text())):
            print(f"check-target-role-policy: selftest: {b.name} was accepted", file=sys.stderr)
            return 2
    tgood = sorted(FIXTURES.glob("good-*.tf"))
    tbads = sorted(FIXTURES.glob("bad-*.tf"))
    if not tgood or len(tbads) < 4:
        print("check-target-role-policy: selftest: the Terraform fixtures are missing", file=sys.stderr)
        return 2
    for g in tgood:
        v = policy_resource_findings(g.read_text(), g.name)
        if v:
            print(f"check-target-role-policy: selftest: {g.name} gave {v}", file=sys.stderr)
            return 2
    for b in tbads:
        if not policy_resource_findings(b.read_text(), b.name):
            print(f"check-target-role-policy: selftest: {b.name} was accepted", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(bads)} policies and {len(tbads)} roots are refused, {len(good)} policy and {len(tgood)} root pass")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    targets = sorted(p for p in (ROOT / "targets").glob("*/") if (p / "main.tf").exists())
    if not targets:
        print("check-target-role-policy: no target root was read", file=sys.stderr)
        return 2
    bad: list[str] = []
    rendered = 0
    for t in targets:
        bad += policy_resource_findings("\n".join(f.read_text() for f in t.glob("*.tf")), t.name)
        for tfvars in sorted((t / "envs").glob("*.tfvars")):
            try:
                policy = render(t, tfvars)
            except RuntimeError as e:
                bad.append(str(e))
                continue
            rendered += 1
            bad += [f"{t.name} {tfvars.name}: {v}" for v in violations(policy)]
    if rendered == 0 and not bad:
        print("check-target-role-policy: no policy was rendered, so the scan read nothing", file=sys.stderr)
        return 2
    if bad:
        print("❌ the instance role of a target node is wider than the node needs:", file=sys.stderr)
        for b in bad:
            print(f"   {b}", file=sys.stderr)
        return 1
    print(f"✅ {rendered} rendered instance role policies: only the allowlisted actions, one parameter ARN, no second policy")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
