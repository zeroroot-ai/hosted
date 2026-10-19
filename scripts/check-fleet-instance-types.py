#!/usr/bin/env python3
"""Guard: each sandbox fleet node type exposes /dev/kvm (hosted#446, ADR-0083).

Every sandbox is a Firecracker machine, so each fleet node needs /dev/kvm. On
AWS that is a c8i, m8i or r8i type with nested virtualization, or a metal type.
An m6a node (the old staging type) runs no sandbox, and a bringup on it looks
healthy until the first sandbox.

WHAT IT CHECKS
    Each fleet instance type that this repo names:
      bootstrap/ec2/gibson/variables.tf        the default of instance_type
      bootstrap/ec2/gibson/envs/*.tfvars       instance_type
      bootstrap/ec2/gibson/envs/*.instance-types   each listed type
      bootstrap/eks/gibson/variables.tf        the default of workload_instance_types
      bootstrap/eks/gibson/modules/cluster/variables.tf  the same
      bootstrap/eks/gibson/envs/*.tfvars       workload_instance_types
    Each must be a known KVM type. The system node group (arm64) is not the
    fleet and is not checked.

Usage:
    scripts/check-fleet-instance-types.py             # the guard
    scripts/check-fleet-instance-types.py --selftest  # prove that it can fail
Exit: 0 clean · 1 a type with no /dev/kvm · 2 the self-test is broken

The fixtures are in tests/guards/fleet-instance-types/.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "guards" / "fleet-instance-types"

KVM_TYPE = re.compile(r"^((c8i|m8i|r8i)\.[0-9a-z]+|[0-9a-z]+\.metal(-[0-9a-z]+)?)$")
TYPE = r"[a-z0-9]+\.[a-z0-9-]+"
SCALAR = re.compile(r'^\s*instance_type\s*=\s*"(' + TYPE + r')"', re.M)
LIST = re.compile(r'^\s*workload_instance_types\s*=\s*\[([^\]]*)\]', re.M)
VAR_DEFAULT = re.compile(
    r'variable\s+"(instance_type|workload_instance_types)"\s*\{(.*?)\n\}', re.S)


def types_in(path: pathlib.Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
    if path.name.endswith(".instance-types"):
        return [l.strip() for l in text.splitlines() if l.strip()]
    if path.name == "variables.tf":
        out: list[str] = []
        for _, body in VAR_DEFAULT.findall(text):
            m = re.search(r'default\s*=\s*(\[[^\]]*\]|"[^"]*")', body)
            if m:
                out += re.findall(r'"(' + TYPE + r')"', m.group(1))
        return out
    out = SCALAR.findall(text)
    for body in LIST.findall(text):
        out += re.findall(r'"(' + TYPE + r')"', body)
    return out


def files(root: pathlib.Path) -> list[pathlib.Path]:
    ec2 = root / "bootstrap" / "ec2" / "gibson"
    eks = root / "bootstrap" / "eks" / "gibson"
    out = [ec2 / "variables.tf", eks / "variables.tf", eks / "modules" / "cluster" / "variables.tf"]
    out += sorted((ec2 / "envs").glob("*.tfvars")) + sorted((ec2 / "envs").glob("*.instance-types"))
    out += sorted((eks / "envs").glob("*.tfvars"))
    return [f for f in out if f.is_file()]


def findings(paths: list[pathlib.Path], base: pathlib.Path) -> tuple[list[str], int]:
    bad: list[str] = []
    seen = 0
    for f in paths:
        for t in types_in(f):
            seen += 1
            if not KVM_TYPE.match(t):
                bad.append(f"{f.relative_to(base)}: {t} exposes no /dev/kvm. Use c8i, m8i, r8i or a metal type")
    return bad, seen


def selftest() -> int:
    bad = sorted((FIXTURES / "bad").iterdir())
    good = sorted((FIXTURES / "good").iterdir())
    if len(bad) < 3 or not good:
        print("check-fleet-instance-types: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for f in bad:
        got, seen = findings([f], FIXTURES)
        if len(got) != 1:
            print(f"check-fleet-instance-types: selftest: {f.name} gave {got} ({seen} seen)", file=sys.stderr)
            return 2
    got, seen = findings(good, FIXTURES)
    if got or seen < 3:
        print(f"check-fleet-instance-types: selftest: the good fixtures gave {got} ({seen} seen)", file=sys.stderr)
        return 2
    print(f"✅ self-test: {len(bad)} fleet types with no /dev/kvm are each rejected, "
          "m8i, r8i and metal types pass")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    paths = files(ROOT)
    bad, seen = findings(paths, ROOT)
    if seen < 4:
        print(f"check-fleet-instance-types: only {seen} instance types were found, so the scan did not look at stage 1",
              file=sys.stderr)
        return 1
    if bad:
        print("check-fleet-instance-types: a sandbox fleet node type has no /dev/kvm (hosted#446):", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        return 1
    print(f"✅ each of {seen} sandbox fleet instance types exposes /dev/kvm")
    return 0


if __name__ == "__main__":
    sys.exit(main())
