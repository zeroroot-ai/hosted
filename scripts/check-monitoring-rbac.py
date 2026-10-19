#!/usr/bin/env python3
"""Guard: the monitoring stack reads no Secret outside `monitoring` (hosted#505).

kube-prometheus-stack, as installed by hosted#423, gave three ServiceAccounts
in `monitoring` read access to every Secret of the cluster, the owner
credentials of charts ADR-0093 among them. Measured on the rebuilt staging on
2026-10-06 with `make owner-credential-readers-live` of charts. The fix is in
the values of each env and in gitops/monitoring-rbac/. This guard holds it.

WHAT IT CHECKS, for each gitops/envs/<env>/apps/monitoring.yaml
    1. global.rbac.create is false, so the chart writes no operator or
       Prometheus ClusterRole of its own.
    2. kube-state-metrics excludes the secrets collector, or names a
       collector list without it.
    3. Grafana binds an existing ClusterRole (rbac.useExistingClusterRole),
       is not namespaced, adds no ClusterRole rule, and each sidecar
       (dashboards, datasources, alerts, plugins, notifiers) watches
       ConfigMaps only.
    4. The operator watches named namespaces only, and its Prometheus,
       Alertmanager and ThanosRuler instances live in `monitoring` only.
    5. The Application loads gitops/monitoring-rbac as a source.
AND, for each manifest in gitops/monitoring-rbac/ and
gitops/envs/<env>/manifests/monitoring/
    6. No ClusterRole grants secrets, or a wildcard resource, in the core
       group.
    7. A Role outside `monitoring` that grants secrets names each Secret
       (resourceNames) and grants read verbs only. The API server applies
       resourceNames to list and watch too: such a request must select the
       named object (fieldSelector metadata.name).

Usage:
    scripts/check-monitoring-rbac.py             # the guard
    scripts/check-monitoring-rbac.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 a rule is broken · 2 the self-test is broken

The fixtures are in tests/guards/monitoring-rbac/.
"""

from __future__ import annotations

import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "guards" / "monitoring-rbac"
RBAC_DIR = "gitops/monitoring-rbac"
SIDECARS = ("dashboards", "datasources", "alerts", "plugins", "notifiers")
HOME_NS = "monitoring"


def dig(d: dict, *keys, default=None):
    for k in keys:
        if not isinstance(d, dict) or k not in d:
            return default
        d = d[k]
    return d


def check_app(path: pathlib.Path, name: str) -> list[str]:
    try:
        app = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as e:
        return [f"{name}: cannot read: {e}"]
    sources = dig(app, "spec", "sources", default=[]) or []
    chart = next((s for s in sources if s.get("chart") == "kube-prometheus-stack"), None)
    if chart is None:
        return [f"{name}: no kube-prometheus-stack source"]
    v = dig(chart, "helm", "valuesObject", default={}) or {}
    errs = []
    if dig(v, "global", "rbac", "create") is not False:
        errs.append(f"{name}: global.rbac.create is not false, so the chart writes an operator ClusterRole that reads every Secret")
    ksm = v.get("kube-state-metrics") or {}
    excluded = "secrets" in (ksm.get("collectorsExclude") or [])
    listed = ksm.get("collectors")
    if not excluded and (listed is None or "secrets" in listed):
        errs.append(f"{name}: kube-state-metrics runs the secrets collector, so it lists every Secret")
    g = v.get("grafana") or {}
    if not dig(g, "rbac", "useExistingClusterRole"):
        errs.append(f"{name}: grafana.rbac.useExistingClusterRole is not set, so the chart writes a ClusterRole on Secrets")
    if dig(g, "rbac", "namespaced") or dig(g, "rbac", "extraClusterRoleRules"):
        errs.append(f"{name}: grafana.rbac is namespaced or adds ClusterRole rules")
    for sc in SIDECARS:
        if dig(g, "sidecar", sc, "resource") != "configmap":
            errs.append(f"{name}: grafana.sidecar.{sc}.resource is not configmap, so the sidecar watches Secrets")
    op = v.get("prometheusOperator") or {}
    ns = op.get("namespaces") or {}
    if not ns.get("additional") and not ns.get("releaseNamespace"):
        errs.append(f"{name}: prometheusOperator.namespaces is empty, so the operator watches every namespace")
    for key in ("prometheusInstanceNamespaces", "alertmanagerInstanceNamespaces",
                "alertmanagerConfigNamespaces", "thanosRulerInstanceNamespaces"):
        if op.get(key) != [HOME_NS]:
            errs.append(f"{name}: prometheusOperator.{key} is not [{HOME_NS}]")
    if not any(s.get("path") == RBAC_DIR for s in sources):
        errs.append(f"{name}: the Application does not load {RBAC_DIR}")
    return errs


def secret_rules(doc: dict):
    for r in doc.get("rules") or []:
        groups = r.get("apiGroups") or []
        res = r.get("resources") or []
        if ("" in groups or "*" in groups) and ("secrets" in res or "*" in res):
            yield r


def check_manifest(path: pathlib.Path, name: str) -> list[str]:
    try:
        docs = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    except (OSError, yaml.YAMLError) as e:
        return [f"{name}: cannot read: {e}"]
    errs = []
    for d in docs:
        kind = d.get("kind")
        meta = d.get("metadata") or {}
        if kind == "ClusterRole":
            for _ in secret_rules(d):
                errs.append(f"{name}: ClusterRole {meta.get('name')} reads Secrets in every namespace")
        if kind == "Role" and meta.get("namespace") != HOME_NS:
            for r in secret_rules(d):
                if not r.get("resourceNames") or set(r.get("verbs") or []) - {"get", "list", "watch"}:
                    errs.append(f"{name}: Role {meta.get('namespace')}/{meta.get('name')} reaches Secrets it does not name, or does more than read them")
    return errs


def run(apps: list[tuple[pathlib.Path, str]], manifests: list[tuple[pathlib.Path, str]]) -> list[str]:
    errs = []
    for p, n in apps:
        errs += check_app(p, n)
    for p, n in manifests:
        errs += check_manifest(p, n)
    return errs


def selftest() -> int:
    good_app = (FIXTURES / "good" / "monitoring.yaml", "good/monitoring.yaml")
    good_rbac = (FIXTURES / "good" / "rbac.yaml", "good/rbac.yaml")
    cases = [("good", [good_app], [good_rbac], 0)]
    for bad in ("bad-rbac-create", "bad-ksm", "bad-grafana-sidecar", "bad-operator-namespaces", "bad-no-rbac-source"):
        cases.append((bad, [(FIXTURES / bad / "monitoring.yaml", f"{bad}/monitoring.yaml")], [good_rbac], 1))
    for bad in ("bad-clusterrole", "bad-role-unnamed"):
        cases.append((bad, [good_app], [(FIXTURES / bad / "rbac.yaml", f"{bad}/rbac.yaml")], 1))
    ok = True
    for label, apps, mans, want in cases:
        errs = run(apps, mans)
        if want == 0 and errs:
            print(f"SELFTEST FAIL: {label}: {errs}")
            ok = False
        if want and not errs:
            print(f"SELFTEST FAIL: {label}: the guard passed a broken fixture")
            ok = False
    if not ok:
        return 2
    print(f"✅ self-test: {len(cases) - 1} broken fixtures each fail; the good fixture passes")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    apps = sorted(ROOT.glob("gitops/envs/*/apps/monitoring.yaml"))
    if not apps:
        print("✗ no gitops/envs/*/apps/monitoring.yaml, so this guard checks nothing")
        return 1
    mans = sorted(ROOT.glob(f"{RBAC_DIR}/*.yaml")) + sorted(ROOT.glob("gitops/envs/*/manifests/monitoring/*.yaml"))
    if not any(str(p).startswith(str(ROOT / RBAC_DIR)) for p in mans):
        print(f"✗ {RBAC_DIR} holds no manifest")
        return 1
    rel = lambda p: str(p.relative_to(ROOT))  # noqa: E731
    errs = run([(p, rel(p)) for p in apps], [(p, rel(p)) for p in mans])
    if errs:
        for e in errs:
            print(f"✗ {e}")
        return 1
    print(f"✅ check-monitoring-rbac: {len(apps)} monitoring Application(s) and {len(mans)} manifest(s) read no Secret outside {HOME_NS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
