#!/usr/bin/env python3
"""check-target-egress-exemption.py: the tool class exemption names the demo target (gibson#498).

gitops/envs/<env>/values.yaml opens one /32 for the tool SandboxClass
(gibson-workloads.setec.sandboxClasses.specOverrides.tool.egressExemptCIDRs),
so that a tool Sandbox reaches the Kubernetes API of the demo target. The
address of that target is private_ip in targets/kubernetes-goat/envs/<env>.tfvars.

The guard fails when:
  - an env sets the exemption and has no target tfvars with a private_ip;
  - the exemption is not exactly ["<private_ip>/32"];
  - an env with a target tfvars sets an exemption on a class other than tool.

  check-target-egress-exemption.py             exit 1 on a finding, 0 when clean
  check-target-egress-exemption.py --selftest  prove that each fixture fails
"""
from __future__ import annotations

import os
import re
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = "targets/kubernetes-goat/envs"
PRIVATE_IP = re.compile(r'^\s*private_ip\s*=\s*"([0-9.]+)"', re.M)


def overrides(values: dict) -> dict:
    setec = ((values or {}).get("gibson-workloads") or {}).get("setec") or {}
    return ((setec.get("sandboxClasses") or {}).get("specOverrides")) or {}


def findings(root: str) -> list[str]:
    bad = []
    envs = os.path.join(root, "gitops", "envs")
    for env in sorted(os.listdir(envs)):
        path = os.path.join(envs, env, "values.yaml")
        if not os.path.isfile(path):
            continue
        over = overrides(yaml.safe_load(open(path)))
        exempt = {cls: spec.get("egressExemptCIDRs") for cls, spec in over.items()
                  if isinstance(spec, dict) and "egressExemptCIDRs" in spec}
        if not exempt:
            continue
        rel = os.path.relpath(path, root)
        for cls in sorted(exempt):
            if cls != "tool":
                bad.append(f"{rel}: the class {cls!r} has an egress exemption; only the tool class reaches the demo target")
        if "tool" not in exempt:
            continue
        tfvars = os.path.join(root, TARGET, f"{env}.tfvars")
        found = PRIVATE_IP.findall(open(tfvars).read()) if os.path.isfile(tfvars) else []
        if len(found) != 1:
            bad.append(f"{rel}: the tool class has an egress exemption, and {TARGET}/{env}.tfvars names no private_ip")
            continue
        want = [f"{found[0]}/32"]
        if exempt["tool"] != want:
            bad.append(f"{rel}: the tool class exemption is {exempt['tool']}, want {want} (the private_ip of the demo target)")
    return bad


def _tree(values: str, tfvars: str | None) -> str:
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "gitops", "envs", "staging"))
    open(os.path.join(d, "gitops", "envs", "staging", "values.yaml"), "w").write(values)
    if tfvars is not None:
        os.makedirs(os.path.join(d, TARGET))
        open(os.path.join(d, TARGET, "staging.tfvars"), "w").write(tfvars)
    return d


def _values(cls: str, cidrs: list[str]) -> str:
    return yaml.safe_dump({"gibson-workloads": {"setec": {"sandboxClasses": {
        "specOverrides": {cls: {"egressExemptCIDRs": cidrs}}}}}})


def selftest() -> int:
    tf = 'private_ip = "10.60.0.66"\n'
    good = _tree(_values("tool", ["10.60.0.66/32"]), tf)
    if findings(good):
        print(f"SELFTEST FAIL: the matching exemption must pass: {findings(good)}")
        return 1
    if findings(_tree("gibson-workloads: {}\n", None)):
        print("SELFTEST FAIL: an env with no exemption must pass")
        return 1
    cases = {
        "an address that is not the target": _tree(_values("tool", ["10.60.0.67/32"]), tf),
        "a prefix wider than /32": _tree(_values("tool", ["10.60.0.0/24"]), tf),
        "a second range beside the target": _tree(_values("tool", ["10.60.0.66/32", "10.0.0.0/8"]), tf),
        "an exemption on the agent class": _tree(_values("agent", ["10.60.0.66/32"]), tf),
        "an env with no target tfvars": _tree(_values("tool", ["10.60.0.66/32"]), None),
    }
    for what, root in cases.items():
        if not findings(root):
            print(f"SELFTEST FAIL: {what}: the guard gave no finding")
            return 1
    print(f"  ✓ selftest: {len(cases)} fixtures fail, the matching exemption passes")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    bad = findings(ROOT)
    if bad:
        print("a tool class egress exemption does not name the demo target (gibson#498):", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        return 1
    print("  ✓ target-egress-exemption: each exemption is the /32 of its demo target")
    return 0


if __name__ == "__main__":
    sys.exit(main())
