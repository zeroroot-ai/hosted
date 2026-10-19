#!/usr/bin/env python3
"""check-secret-plane-alerts.py: each env that runs the monitoring stack
alerts on an ExternalSecret that is not Ready (hosted#174).

WHY THIS GUARD EXISTS
---------------------
On 2026-09-22 every ExternalSecret in gibson could not reach its provider for
hours, and the only signal was one Argo Application that read Degraded. The
pods ran on Secrets written earlier. The fix is an alert that reaches the
mailbox. This guard keeps it in place: an env that loses the rule, or stops
the scrape that feeds it, fails here and not on the next outage.

WHAT IT MEASURES
----------------
For each env with gitops/envs/<env>/apps/monitoring.yaml:
  1. manifests/monitoring/ holds a PrometheusRule with the alert
     ExternalSecretNotReady on externalsecret_status_condition, and the
     alert ExternalSecretMetricsAbsent, so a missing scrape is not silence.
  2. values.yaml sets external-secrets.serviceMonitor.enabled: true.

Usage: scripts/check-secret-plane-alerts.py            # the guard
       scripts/check-secret-plane-alerts.py --selftest # prove it can fail
Exit:  0 each env alerts · 1 an env does not · 2 could not run
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts/testdata/secret-plane-alerts"
METRIC = "externalsecret_status_condition"


def alerts_in(directory: Path) -> dict[str, str]:
    """Return {alert name: expr} for each PrometheusRule under directory."""
    found: dict[str, str] = {}
    for path in sorted(directory.glob("*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if not isinstance(doc, dict) or doc.get("kind") != "PrometheusRule":
                continue
            for group in (doc.get("spec") or {}).get("groups") or []:
                for rule in group.get("rules") or []:
                    if "alert" in rule:
                        found[rule["alert"]] = str(rule.get("expr", ""))
    return found


def audit(root: Path) -> list[str]:
    """Report one line per env that does not alert on the secret plane."""
    failures: list[str] = []
    envs = sorted(p.parent.parent for p in (root / "gitops/envs").glob("*/apps/monitoring.yaml"))
    if not envs:
        return [f"{root}: no env runs the monitoring stack, so nothing was checked"]
    for env in envs:
        name = env.name
        alerts = alerts_in(env / "manifests/monitoring")
        expr = alerts.get("ExternalSecretNotReady", "")
        if METRIC not in expr or 'status="False"' not in expr:
            failures.append(f"{name}: no ExternalSecretNotReady alert on {METRIC} Ready=False")
        if METRIC not in alerts.get("ExternalSecretMetricsAbsent", ""):
            failures.append(f"{name}: no ExternalSecretMetricsAbsent alert, so a lost scrape is silence")
        values = yaml.safe_load((env / "values.yaml").read_text()) or {}
        monitor = ((values.get("external-secrets") or {}).get("serviceMonitor") or {})
        if monitor.get("enabled") is not True:
            failures.append(f"{name}: values.yaml does not set external-secrets.serviceMonitor.enabled: true")
    return failures


def selftest() -> int:
    """good passes. Each bad fixture fails with its own reason."""
    cases = {"good": None, "no-rule": "ExternalSecretNotReady", "no-servicemonitor": "serviceMonitor"}
    for case, want in cases.items():
        got = audit(FIXTURES / case)
        if want is None and got:
            print(f"selftest FAIL: {case} should pass, got {got}")
            return 1
        if want is not None and not any(want in line for line in got):
            print(f"selftest FAIL: {case} should fail on {want}, got {got}")
            return 1
    print(f"selftest ok: {len(cases)} fixtures")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(__doc__)
        return 2
    failures = audit(ROOT)
    if failures:
        print("An env does not alert on a stale secret plane (hosted#174):")
        for line in failures:
            print(f"  {line}")
        return 1
    print("check-secret-plane-alerts: each monitoring env alerts on an ExternalSecret that is not Ready")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
