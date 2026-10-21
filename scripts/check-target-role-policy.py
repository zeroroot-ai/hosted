#!/usr/bin/env python3
"""check-target-role-policy.py: the instance role of a target node is as narrow
as the node needs.

A target node (targets/<name>/) is meant to be broken into, and a break-out
reaches the instance role. So the policy that the role will carry must not
read parameters by a wildcard, must not grant a KMS action, and must not grant
every action.

The guard judges the rendered policy, not text. Each target root defines
`local.instance_role_policy`, one JSON value built from variables only.
`terraform console` evaluates it for each envs/<env>.tfvars, with no AWS
credential, and the rules below read the JSON statements:

  1. No Allow statement grants an SSM parameter read (ssm:GetParameter,
     ssm:GetParameters, ssm:GetParametersByPath, ssm:GetParameterHistory, or a
     wildcard action that covers one) on a resource that holds a wildcard. That
     includes "*" in any statement, and an ARN that ends in "*".
  2. No Allow statement grants an action of KMS.
  3. No Allow statement grants "*" or "service:*" for ssm or kms.
  4. A target root attaches no managed policy: no aws_iam_role_policy_attachment
     resource and no managed_policy_arns attribute.

Usage: scripts/check-target-role-policy.py [--selftest]
Exit:  0 clean, 1 a rule is broken, 2 the self-test is broken or no target was read
The fixtures are in scripts/testdata/target-role-policy/.
"""
from __future__ import annotations

import fnmatch
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts/testdata/target-role-policy"
PARAM_READS = ("ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory")


def as_list(v) -> list:
    return v if isinstance(v, list) else [v]


def covers(action: str, target: str) -> bool:
    return fnmatch.fnmatchcase(target.lower(), action.lower())


def violations(policy: dict) -> list[str]:
    bad: list[str] = []
    for i, st in enumerate(as_list(policy.get("Statement", []))):
        if st.get("Effect") != "Allow":
            continue
        sid = st.get("Sid") or f"#{i}"
        actions = [str(a) for a in as_list(st.get("Action", []))]
        resources = [str(r) for r in as_list(st.get("Resource", []))]
        for a in actions:
            if a == "*" or a.lower() in ("ssm:*", "kms:*"):
                bad.append(f"statement {sid}: the action {a} grants a whole service")
            if a.lower().startswith("kms:"):
                bad.append(f"statement {sid}: the action {a} is a KMS action")
        reads = [t for t in PARAM_READS if any(covers(a, t) for a in actions)]
        wild = [r for r in resources if "*" in r]
        if reads and wild:
            bad.append(f"statement {sid}: {', '.join(reads)} on a resource with a wildcard: {', '.join(wild)}")
    return bad


def managed_policy_findings(tf_text: str, name: str) -> list[str]:
    code = "\n".join(line.split("#", 1)[0] for line in tf_text.splitlines())
    out = []
    if re.search(r'resource\s+"aws_iam_role_policy_attachment"', code):
        out.append(f"{name}: attaches a managed policy (aws_iam_role_policy_attachment)")
    if re.search(r"^\s*managed_policy_arns\s*=", code, re.M):
        out.append(f"{name}: attaches managed policies (managed_policy_arns)")
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
    if not good or len(bads) < 6:
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
    if not managed_policy_findings('resource "aws_iam_role_policy_attachment" "x" {}\n', "t") \
            or not managed_policy_findings("  managed_policy_arns = []\n", "t") \
            or managed_policy_findings("# resource \"aws_iam_role_policy_attachment\" \"x\" {}\n", "t"):
        print("check-target-role-policy: selftest: the managed policy rule is broken", file=sys.stderr)
        return 2
    print(f"✅ self-test: {len(bads)} wide policies are refused, {len(good)} minimal policy passes")
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
        bad += managed_policy_findings("\n".join(f.read_text() for f in t.glob("*.tf")), t.name)
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
    print(f"✅ {rendered} rendered instance role policies: no wildcard parameter read, no KMS action, no managed policy")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
