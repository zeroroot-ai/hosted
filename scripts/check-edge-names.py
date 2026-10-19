#!/usr/bin/env python3
"""check-edge-names.py: each EC2 and EKS overlay lists the names of its edge
certificate, and they are the hosts the edge serves (row 9 of the drill path
audit).

The bringup restores the kept edge certificate only when it knows the names
the Certificate asks for (scripts/lib/edge-cert.sh). An overlay that leaves
`gibson-workloads.certManager.envoyEdge.dnsNames` empty uses the chart
default, which the bringup cannot read, so every recreate asks Let's Encrypt
for a new certificate. The default also adds www, which the edge does not
serve (ADR-0077).

What fails, for each env of gitops/envs/{staging,prod,drill}/values.yaml:

  1. the list is empty or missing;
  2. the list is not exactly app, api, docs and the apex of `global.domain`.

Usage:  scripts/check-edge-names.py [--selftest]
Exit:   0 clean, 1 a rule is broken, 2 the self-test is broken or a file is missing
"""
from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ("staging", "prod", "drill")


def findings(values: dict, env: str) -> list[str]:
    domain = ((values.get("global") or {}).get("domain") or "").strip()
    if not domain:
        return [f"{env}: the overlay sets no global.domain"]
    edge = (((values.get("gibson-workloads") or {}).get("certManager") or {}).get("envoyEdge") or {})
    names = edge.get("dnsNames") or []
    if not names:
        return [f"{env}: gibson-workloads.certManager.envoyEdge.dnsNames is empty, so the bringup cannot restore the kept edge certificate"]
    want = sorted([f"app.{domain}", f"api.{domain}", f"docs.{domain}", domain])
    if sorted(names) != want:
        return [f"{env}: the edge names are {sorted(names)}, and the hosts the edge serves are {want}"]
    return []


def selftest() -> int:
    good = {"global": {"domain": "x.example.test"},
            "gibson-workloads": {"certManager": {"envoyEdge": {"dnsNames": [
                "app.x.example.test", "api.x.example.test", "docs.x.example.test", "x.example.test"]}}}}
    cases = {
        "empty": ({**good, "gibson-workloads": {"certManager": {"envoyEdge": {"dnsNames": []}}}}, "is empty"),
        "www": ({**good, "gibson-workloads": {"certManager": {"envoyEdge": {"dnsNames": [
            "app.x.example.test", "api.x.example.test", "docs.x.example.test", "x.example.test", "www.x.example.test"]}}}},
            "hosts the edge serves"),
        "other domain": ({**good, "global": {"domain": "y.example.test"}}, "hosts the edge serves"),
        "no domain": ({**good, "global": {}}, "no global.domain"),
    }
    if findings(good, "good"):
        print(f"check-edge-names: selftest: the good overlay failed: {findings(good, 'good')}", file=sys.stderr)
        return 2
    for name, (values, want) in cases.items():
        got = findings(values, name)
        if not any(want in g for g in got):
            print(f"check-edge-names: selftest: {name} did not raise {want!r}: {got}", file=sys.stderr)
            return 2
    print(f"✅ self-test: {len(cases)} bad overlays each raise their rule; the good overlay passes")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    got = []
    for env in ENVS:
        p = ROOT / "gitops" / "envs" / env / "values.yaml"
        if not p.is_file():
            print(f"check-edge-names: {p} is missing", file=sys.stderr)
            return 2
        got += findings(yaml.safe_load(p.read_text(encoding="utf-8")) or {}, env)
    if got:
        print("check-edge-names:", *got, sep="\n  ", file=sys.stderr)
        return 1
    print("✅ staging, prod and drill list the names of their edge certificate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
