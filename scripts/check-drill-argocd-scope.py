#!/usr/bin/env python3
"""Guard: the drill Argo CD project permits what the staging project permits.

The drill proves a bringup of staging's platform (ADR-0095). Argo CD's
`default` project of each EC2 env is built from four lists of
bootstrap/ec2/gibson/envs/<env>.tfvars. If a list of drill misses an entry
of staging, the gibson app syncs on staging and fails on drill.

Measured 2026-10-12 (hosted#618): drill.tfvars had no setec namespace, API
group or cluster kind, and drill run 38195193902 stopped with
"namespace setec-system is not permitted in project 'default'".

WHAT IT CHECKS
    Each entry of these lists in staging.tfvars is also in drill.tfvars:
        argocd_extra_managed_api_groups
        argocd_extra_platform_namespaces
        argocd_extra_platform_source_repos
        argocd_extra_cluster_resources
    except the entries in STAGING_ONLY, which are the self-hosted runners
    (ARC). Those are named by content, never by line.

Usage:
    scripts/check-drill-argocd-scope.py             # the guard
    scripts/check-drill-argocd-scope.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 a rule is broken · 2 the self-test is broken or nothing was read

The fixtures are in tests/guards/drill-argocd-scope/<case>/{staging,drill}.tfvars.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "bootstrap" / "ec2" / "gibson" / "envs"
FIXTURES = ROOT / "tests" / "guards" / "drill-argocd-scope"

LISTS = (
    "argocd_extra_managed_api_groups",
    "argocd_extra_platform_namespaces",
    "argocd_extra_platform_source_repos",
    "argocd_extra_cluster_resources",
)

# The self-hosted runners run on staging only.
STAGING_ONLY = {
    "argocd_extra_managed_api_groups": {"actions.github.com"},
    "argocd_extra_platform_namespaces": {"arc-systems", "arc-runners"},
    "argocd_extra_platform_source_repos": {"ghcr.io/actions/actions-runner-controller-charts"},
    "argocd_extra_cluster_resources": set(),
}


def strip_comments(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def read_lists(path: pathlib.Path) -> dict[str, set[str]]:
    text = strip_comments(path.read_text(encoding="utf-8"))
    out: dict[str, set[str]] = {}
    for name in LISTS:
        m = re.search(r'^\s*' + name + r'\s*=\s*\[(.*?)^\s*\]', text, re.S | re.M)
        if not m:
            out[name] = set()
            continue
        body = m.group(1)
        if name == "argocd_extra_cluster_resources":
            out[name] = {f"{g}/{k}" for g, k in re.findall(
                r'group\s*=\s*"([^"]*)"\s*,\s*kind\s*=\s*"([^"]*)"', body)}
        else:
            out[name] = set(re.findall(r'"([^"]+)"', body))
    return out


def findings(staging: pathlib.Path, drill: pathlib.Path) -> list[str]:
    s, d = read_lists(staging), read_lists(drill)
    if not any(s.values()):
        return [f"{staging}: no Argo CD list was read, so the check did not look at anything"]
    out = []
    for name in LISTS:
        for entry in sorted(s[name] - STAGING_ONLY[name] - d[name]):
            out.append(f"{name}: staging has {entry!r} and drill does not. The gibson app of drill "
                       "fails its sync on a resource that staging syncs. Add it to drill.tfvars")
    return out


def selftest() -> int:
    cases = {"good": 0, "bad-no-setec-namespace": 1, "bad-no-setec-api-group": 1}
    for name, want in cases.items():
        d = FIXTURES / name
        if not (d / "staging.tfvars").is_file() or not (d / "drill.tfvars").is_file():
            print(f"check-drill-argocd-scope: selftest: the fixture {name} is missing", file=sys.stderr)
            return 2
        got = findings(d / "staging.tfvars", d / "drill.tfvars")
        if (len(got) > 0) != (want > 0):
            print(f"check-drill-argocd-scope: selftest: {name} gave {got}", file=sys.stderr)
            return 2
    print("✅ self-test: a drill with no setec namespace, and one with no setec API group, are each rejected")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    got = findings(ENVS / "staging.tfvars", ENVS / "drill.tfvars")
    if got:
        print("check-drill-argocd-scope: bootstrap/ec2/gibson/envs:", file=sys.stderr)
        for g in got:
            print(f"  {g}", file=sys.stderr)
        return 1
    print("✅ the drill Argo CD project permits each entry of staging, except the self-hosted runners")
    return 0


if __name__ == "__main__":
    sys.exit(main())
