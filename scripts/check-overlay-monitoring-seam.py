#!/usr/bin/env python3
"""check-overlay-monitoring-seam.py — the monitoring stack of an env can sync.

The staging rebuild of 2026-10-06 found two faults in the monitoring Application
(hosted#423). Neither shows in a render. Both stop the sync on a live cluster.

1. The store. The chart's ClusterSecretStore `gibson-secrets` serves only the
   release namespace `gibson` (spec.conditions). An ExternalSecret in any other
   namespace that names it fails with "is not allowed from namespace".

2. The CRDs. An env that installs kube-prometheus-stack owns the full
   prometheus-operator CRD set. If its gibson-crds Application still ships
   ServiceMonitor and PrometheusRule (the chart default), two Applications own
   the same CRDs and the monitoring sync never completes. The chart's seam is
   `prometheus-operator-crds.enabled: false`.

WHAT IT CHECKS, for each gitops/envs/<env>/:
    a. No ExternalSecret outside `gibson` names the ClusterSecretStore
       `gibson-secrets`.
    b. If an Application of the env installs the chart kube-prometheus-stack,
       the gibson-crds Application sets prometheus-operator-crds.enabled to
       false.

Usage:
    scripts/check-overlay-monitoring-seam.py             # the guard
    scripts/check-overlay-monitoring-seam.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 a rule is broken · 2 the self-test is broken or nothing was read

The fixtures are in tests/guards/monitoring-seam/.
"""

from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "gitops" / "envs"
FIXTURES = ROOT / "tests" / "guards" / "monitoring-seam"
RELEASE_NS = "gibson"
CLUSTER_STORE = "gibson-secrets"


def docs(env_dir: pathlib.Path):
    for f in sorted(env_dir.rglob("*.yaml")):
        try:
            for d in yaml.safe_load_all(f.read_text(encoding="utf-8")):
                if isinstance(d, dict):
                    yield f, d
        except yaml.YAMLError:
            continue


def sources(app: dict) -> list[dict]:
    spec = app.get("spec") or {}
    out = list(spec.get("sources") or [])
    if spec.get("source"):
        out.append(spec["source"])
    return [s for s in out if isinstance(s, dict)]


def findings(env_dir: pathlib.Path) -> tuple[list[str], int]:
    out: list[str] = []
    seen = 0
    installs_stack = False
    crds_seam_off = None  # None: no gibson-crds Application found
    for f, d in docs(env_dir):
        kind = d.get("kind")
        meta = d.get("metadata") or {}
        if kind == "ExternalSecret":
            seen += 1
            ref = (d.get("spec") or {}).get("secretStoreRef") or {}
            ns = meta.get("namespace", "")
            if ref.get("kind") == "ClusterSecretStore" and ref.get("name") == CLUSTER_STORE and ns != RELEASE_NS:
                out.append(f"{f.relative_to(env_dir)}: ExternalSecret {meta.get('name')} in namespace "
                           f"{ns or '<none>'} names the ClusterSecretStore {CLUSTER_STORE}, which serves "
                           f"only {RELEASE_NS}")
        if kind == "Application":
            seen += 1
            for s in sources(d):
                if s.get("chart") == "kube-prometheus-stack":
                    installs_stack = True
                if s.get("chart") == "gibson-crds":
                    vals = ((s.get("helm") or {}).get("valuesObject") or {}).get("prometheus-operator-crds") or {}
                    crds_seam_off = vals.get("enabled") is False
    if installs_stack and crds_seam_off is not True:
        out.append("the env installs kube-prometheus-stack, and its gibson-crds Application does not set "
                   "prometheus-operator-crds.enabled: false, so two Applications own the same CRDs")
    return out, seen


def selftest() -> int:
    cases = {"good": 0, "bad-cluster-store-in-monitoring": 1, "bad-crds-twice": 1}
    for name, want in cases.items():
        d = FIXTURES / name
        if not d.is_dir():
            print(f"check-overlay-monitoring-seam: selftest: the fixture {name} is missing", file=sys.stderr)
            return 2
        got, seen = findings(d)
        if seen == 0 or (len(got) > 0) != (want > 0):
            print(f"check-overlay-monitoring-seam: selftest: {name} gave {got} ({seen} read)", file=sys.stderr)
            return 2
    print("✅ self-test: the cluster store in monitoring, and the CRDs owned twice, are each rejected")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    total = 0
    bad: list[str] = []
    for env_dir in sorted(p for p in ENVS.iterdir() if p.is_dir()):
        got, seen = findings(env_dir)
        total += seen
        bad += [f"{env_dir.name}: {g}" for g in got]
    if total == 0:
        print("check-overlay-monitoring-seam: no Application or ExternalSecret was read", file=sys.stderr)
        return 2
    if bad:
        print("check-overlay-monitoring-seam:", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        return 1
    print(f"✅ {total} Applications and ExternalSecrets read: no foreign namespace uses {CLUSTER_STORE}, "
          "and no env owns the prometheus-operator CRDs twice")
    return 0


if __name__ == "__main__":
    sys.exit(main())
