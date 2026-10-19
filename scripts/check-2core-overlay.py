#!/usr/bin/env python3
"""check-2core-overlay.py — every rung of the ladder keeps the platform
schedulable on a 2-vCPU GitHub-hosted runner.

WHY THIS GUARD EXISTS
---------------------
The first guard of this name was deleted with the deploy repo in the
2026-09-04 split and nothing measured the budget afterwards. On 2026-09-07
hosted run 34124471104 held 1715m of requests on a ~2000m node with the
umbrella overlay applied, and the umbrella's neo4j (a chart-enforced 500m)
sat Pending "Insufficient cpu" for an hour. The first guard counted only the
umbrella. The node also carries kube-system, the Velero release, the
metrics-server add-on, the ToolHive operator and, once the seeded tenant
provisions, its data plane. This guard counts all of them.

WHAT IT MEASURES
----------------
  1. helm template of the umbrella: values-baseline.yaml + the CI overlay,
     platformPostgres.instances=1 as the recreate verb sets it. Deployments,
     StatefulSets and DaemonSets times replicas, plus the CNPG Cluster CR
     times instances.
  2. helm template of gibson-velero + its CI overlay, the same way.
  3. The metrics-server CI overlay's requests (the add-on is not a chart in
     this repo; the verb installs it with -f this file).
  4. The kube-system baseline of a kind v1.33 node, measured 2026-09-07:
     kube-apiserver 250m, kube-controller-manager 200m, etcd 100m/100Mi,
     kube-scheduler 100m, coredns 2 x 100m/70Mi. Cilium is the network
     plugin: the agent 90m/128Mi and the operator 10m/64Mi
     (bootstrap/cilium/values.yaml).
  5. The ToolHive operator the verb installs: 10m/64Mi (upstream default).
  6. TWO tenant data planes, each a neo4j at the tenant-operator's small
     tier (100m / 1Gi, its tierDefaults; the chart's tenantNeo4j.tiers.*
     values are discarded by the operator): the bringup's own tenant
     (tenant-primary, created by the first-admin Job) and the tenant the
     exit test seeds. Postgres and Redis for a tenant live in the platform's
     shared stores and add no pod. The first guard counted one tenant at a
     value the operator never reads, and hosted run 34233760977 (2026-09-08)
     held 1915m against the 1765m it modelled.
  7. The restore helper. backup-verify restores a pod that carries an
     fs-backup volume, and Velero gives that pod an init container asking
     for 100m / 128Mi unless the fs-restore-action-config ConfigMap the
     Velero overlay ships says otherwise. On that same run the restored pod
     sat Pending "Insufficient cpu" for 900 s. The row reads the overlay's
     ConfigMap and falls back to Velero's defaults when it is absent, and
     the self-test proves that the total counts that default.

The budget is the runner's allocatable minus headroom: 2000m CPU and
~7990Mi memory were measured on ubuntu-latest (2 vCPU / 7 GB) on the same
run. CPU_BUDGET_M leaves 100m for burst scheduling of hook Jobs;
MEM_BUDGET_MI leaves ~1 GB.

Usage: scripts/check-2core-overlay.py            # the guard
       scripts/check-2core-overlay.py --selftest # prove it can fail
Env:   CHARTS_ROOT  a checkout of zeroroot-ai/charts (default ../charts)
Exit:  0 within budget · 1 over budget · 2 could not run / self-test broken
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CHARTS_ROOT = Path(os.environ.get("CHARTS_ROOT") or (ROOT.parent / "charts")).resolve()
# The rungs live in the CHART now (zeroroot-ai/charts#93), not here. They are
# what `make recreate ENV=kind RUNG=<rung>` installs, so measuring anything
# else would measure a file nothing uses.
#
# metrics-server is the exception and stays here: it is not a chart in
# zeroroot-ai/charts, this repo's verb installs it directly, so it has no rung
# to name.
RUNGS = ("developer", "ci")
METRICS_OVERLAY = ROOT / "test/baseline/ci-2core-metrics-server.values.yaml"
# The signup exit test (hosted#122) installs the CI rung plus this overlay,
# which enables the Mailpit sink. Its requests count against the same node.
SIGNUP_OVERLAY = ROOT / "test/signup/values.yaml"


def umbrella_rung(rung: str) -> Path:
    return CHARTS_ROOT / f"helm/gibson/values-{rung}.yaml"


# What an installer supplies and no rung holds: the archive bucket and the
# sandbox disk inputs of setec (ADR-0166). The chart has no default for them,
# on purpose, and its own offline guards render with this fixture. The kind
# verb takes the same inputs from stage 0. Requests do not depend on them.
def render_inputs() -> Path:
    return CHARTS_ROOT / "helm/testdata/render-inputs/gibson.yaml"


def velero_rung(rung: str) -> Path:
    # Velero installs as its own release, so an umbrella rung never reaches it.
    return CHARTS_ROOT / f"helm/gibson-velero/values-{rung}.yaml"
OVERAGE_FIXTURE = ROOT / "scripts/testdata/2core-overlay/overage.values.yaml"

CPU_BUDGET_M = 1900
MEM_BUDGET_MI = 7000

# Measured on kind v1.33.1 (node image kindest/node), 2026-09-07, on the
# workstation and on run 34124471104. kube-proxy and local-path-provisioner
# request nothing.
KUBE_SYSTEM_BASELINE = [
    ("kube-system/kube-apiserver", 250, 0),
    ("kube-system/kube-controller-manager", 200, 0),
    ("kube-system/etcd", 100, 100),
    ("kube-system/kube-scheduler", 100, 0),
    ("kube-system/coredns x2", 200, 140),
    # Cilium replaced kindnet (hosted#436). The numbers are the requests in
    # bootstrap/cilium/values.yaml.
    ("kube-system/cilium", 90, 128),
    ("kube-system/cilium-operator", 10, 64),
    ("toolhive-system/toolhive-operator", 10, 64),
]


def cpu_m(v) -> int:
    s = str(v)
    if s.endswith("m"):
        return int(s[:-1])
    return int(round(float(s) * 1000))


def mem_mi(v) -> float:
    s = str(v)
    units = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1024 * 1024, "K": 0.001, "M": 0.954, "G": 954}
    for unit, factor in units.items():
        if s.endswith(unit):
            return float(s[: -len(unit)]) * factor
    return float(s) / (1024 * 1024)


def die(msg: str, code: int = 2) -> None:
    print(f"check-2core-overlay: {msg}", file=sys.stderr)
    sys.exit(code)


def helm_template(chart: Path, values: list[Path], extra_args: list[str]) -> list[dict]:
    if not (chart / "Chart.yaml").is_file():
        die(f"no chart at {chart}. Set CHARTS_ROOT to a checkout of zeroroot-ai/charts")
    cmd = ["helm", "template", "budget", str(chart)]
    for v in values:
        cmd += ["-f", str(v)]
    cmd += extra_args
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        die(f"helm template {chart.name} failed:\n{out.stderr.strip()[-2000:]}")
    return [d for d in yaml.safe_load_all(out.stdout) if d]


def ensure_deps(chart: Path) -> None:
    """The umbrella vendors its sub-charts as tarballs. Repack the first-party ones.

    The first version built the tarballs only when none existed. A checkout
    that already held them rendered STALE first-party sub-charts: on
    2026-09-07 charts main gained a gibson.toolImage helper in gibson-common,
    the packaged gibson-common-*.tgz on the workstation predated it, and
    this guard died in `helm template` with "no template gibson.toolImage"
    while the chart itself was fine. charts' own golden.sh repacks the
    first-party tarballs before every render for the same reason
    (.charts.stamp tracks dependency SOURCES, not those charts' templates).
    Do the same: remove the first-party tarballs and the stamps, then build.
    Third-party tarballs stay, so no network round trip when they are
    present.
    """
    if chart.name != "gibson":
        return
    for tgz in (chart / "charts").glob("gibson-*.tgz"):
        tgz.unlink()
    for stamp in (CHARTS_ROOT / "helm").glob("*/.charts.stamp"):
        stamp.unlink()
    out = subprocess.run(["make", "-C", str(CHARTS_ROOT), "chart-deps"], capture_output=True, text=True)
    if out.returncode != 0:
        die(f"make chart-deps in {CHARTS_ROOT} failed:\n{out.stderr.strip()[-1500:]}")


def workload_rows(docs: list[dict], prefix: str) -> list[tuple[str, int, float]]:
    rows = []
    for d in docs:
        kind = d.get("kind")
        name = d.get("metadata", {}).get("name", "?")
        if kind in ("Deployment", "StatefulSet", "DaemonSet"):
            spec = d.get("spec", {})
            replicas = 1 if kind == "DaemonSet" else int(spec.get("replicas", 1) or 1)
            containers = spec.get("template", {}).get("spec", {}).get("containers", [])
            c = sum(cpu_m(x.get("resources", {}).get("requests", {}).get("cpu", 0)) for x in containers)
            m = sum(mem_mi(x.get("resources", {}).get("requests", {}).get("memory", 0)) for x in containers)
            rows.append((f"{prefix}{kind}/{name} x{replicas}", c * replicas, m * replicas))
        elif kind == "Cluster" and str(d.get("apiVersion", "")).split("/", 1)[0] == "postgresql.cnpg.io":
            spec = d.get("spec", {})
            inst = int(spec.get("instances", 1) or 1)
            req = spec.get("resources", {}).get("requests", {})
            rows.append((f"{prefix}CNPG/{name} x{inst}", cpu_m(req.get("cpu", 0)) * inst, mem_mi(req.get("memory", 0)) * inst))
    return rows


def deep_merge(a: dict, b: dict) -> dict:
    out = dict(a)
    for k, v in (b or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


# The tenant-operator sizes every per-tenant neo4j from its own tierDefaults
# (gibson operators/tenant/internal/dataplane/neo4j.go: small = 10Gi, 100m,
# 1Gi) and discards the chart's tenantNeo4j.tiers.* values, so those values
# are not the truth and this guard does not read them. Measured on hosted run
# 34233760977: tenant-primary and tenant-restoreloop each held 100m / 1Gi
# with the overlay claiming 50m. Change these two numbers only when the
# operator's tierDefaults change.
TENANT_NEO4J_SMALL_CPU_M = 100
TENANT_NEO4J_SMALL_MEM_MI = 1024


def tenant_data_planes() -> list[tuple[str, int, float]]:
    """The two per-tenant neo4j pods the loop stands up, at the operator's small tier.

    The bringup's first-admin Job creates tenant-primary, and the exit test
    seeds a second tenant. The operator creates both StatefulSets after the
    install, so no manifest carries them.
    """
    return [
        ("tenant-primary/neo4j (operator small tier)", TENANT_NEO4J_SMALL_CPU_M, float(TENANT_NEO4J_SMALL_MEM_MI)),
        ("tenant-<seeded>/neo4j (operator small tier)", TENANT_NEO4J_SMALL_CPU_M, float(TENANT_NEO4J_SMALL_MEM_MI)),
    ]


# Velero's own defaults for the fs-backup restore helper init container
# (pkg/restore/actions/pod_volume_restore_action.go). They apply to every
# restored pod that carries an fs-backup volume unless a ConfigMap labelled
# velero.io/plugin-config + velero.io/pod-volume-restore=RestoreItemAction
# says otherwise.
RESTORE_HELPER_DEFAULT_CPU_M = 100
RESTORE_HELPER_DEFAULT_MEM_MI = 128


def restore_helper(velero_values: list[Path]) -> tuple[str, int, float]:
    """The request of the restore helper init container Velero adds to a restored pod.

    backup-verify (scripts/backup-verify.sh) restores the canary pod into a
    scratch namespace on every preserve teardown. That pod requests nothing
    itself, and still needs this much free on the node, or it never
    schedules and check 2 times out.
    """
    merged: dict = {}
    for f in velero_values:
        merged = deep_merge(merged, yaml.safe_load(f.read_text()) or {})
    cms = merged.get("velero", {}).get("configMaps", {}) or {}
    for name, cm in cms.items():
        labels = (cm or {}).get("labels", {}) or {}
        if "velero.io/plugin-config" in labels and labels.get("velero.io/pod-volume-restore") == "RestoreItemAction":
            data = (cm or {}).get("data", {}) or {}
            return (
                f"restored canary/restore-helper init ({name})",
                cpu_m(data.get("cpuRequest", f"{RESTORE_HELPER_DEFAULT_CPU_M}m")),
                mem_mi(data.get("memRequest", f"{RESTORE_HELPER_DEFAULT_MEM_MI}Mi")),
            )
    return ("restored canary/restore-helper init (Velero default, no ConfigMap)", RESTORE_HELPER_DEFAULT_CPU_M, float(RESTORE_HELPER_DEFAULT_MEM_MI))


def measure(umbrella_values: list[Path], velero_values: list[Path], metrics_values: Path) -> tuple[list[tuple[str, int, float]], int, float]:
    umbrella = CHARTS_ROOT / "helm/gibson"
    velero = CHARTS_ROOT / "helm/gibson-velero"
    ensure_deps(umbrella)
    rows: list[tuple[str, int, float]] = []
    inputs = render_inputs()
    if not inputs.is_file():
        die(f"missing {inputs}: the chart's render inputs. Is CHARTS_ROOT={CHARTS_ROOT} a charts checkout?")
    rows += workload_rows(helm_template(umbrella, [inputs, *umbrella_values], ["--namespace", "gibson", "--set", "platformPostgres.instances=1"]), "")
    rows += workload_rows(helm_template(velero, velero_values, []), "velero: ")
    ms = yaml.safe_load(metrics_values.read_text()) or {}
    req = ms.get("resources", {}).get("requests", {})
    rows.append(("kube-system/metrics-server", cpu_m(req.get("cpu", 0)), mem_mi(req.get("memory", 0))))
    rows += [(n, c, float(m)) for n, c, m in KUBE_SYSTEM_BASELINE]
    rows += tenant_data_planes()
    rows.append(restore_helper(velero_values))
    cpu = sum(r[1] for r in rows)
    mem = sum(r[2] for r in rows)
    return rows, cpu, mem


def report(rows, cpu, mem) -> bool:
    for name, c, m in sorted(rows, key=lambda r: -r[1]):
        if c or m:
            print(f"  {c:5d}m {m:7.0f}Mi  {name}")
    ok = cpu <= CPU_BUDGET_M and mem <= MEM_BUDGET_MI
    verdict = "within" if ok else "OVER"
    print(f"  total {cpu}m of {CPU_BUDGET_M}m CPU, {mem:.0f}Mi of {MEM_BUDGET_MI}Mi memory: {verdict} the 2-vCPU runner budget")
    return ok


def guard() -> int:
    """Every rung fits the node, measured one rung at a time.

    developer and CI ship identical content today. They are measured
    SEPARATELY and not compared, because ADR-0090 keeps them as two files so
    either may change later without a rename. A guard that required them equal
    would defeat that. Their totals are printed, so a divergence is visible on
    the run that introduces it.
    """
    if not METRICS_OVERLAY.is_file():
        die(f"missing overlay {METRICS_OVERLAY}")
    baseline = CHARTS_ROOT / "helm/gibson/values-baseline.yaml"
    if not baseline.is_file():
        die(f"missing {baseline} — is CHARTS_ROOT={CHARTS_ROOT} a charts checkout?")

    failed = []
    totals = {}
    for rung in RUNGS:
        u, v = umbrella_rung(rung), velero_rung(rung)
        for f in (u, v):
            if not f.is_file():
                die(f"the ladder names a '{rung}' rung and {f} is missing "
                    f"(zeroroot-ai/charts#93). CHARTS_ROOT={CHARTS_ROOT}")
        print(f"— rung: {rung}")
        rows, cpu, mem = measure([baseline, u], [v], METRICS_OVERLAY)
        totals[rung] = (cpu, mem)
        if not report(rows, cpu, mem):
            failed.append(rung)

    # The signup exit test's node: the CI rung plus its Mailpit overlay.
    if not SIGNUP_OVERLAY.is_file():
        die(f"missing overlay {SIGNUP_OVERLAY}")
    print("— rung: ci + test/signup/values.yaml (exit-test-signup)")
    rows, cpu, mem = measure([baseline, umbrella_rung("ci"), SIGNUP_OVERLAY], [velero_rung("ci")], METRICS_OVERLAY)
    if not report(rows, cpu, mem):
        failed.append("ci + signup overlay")

    if failed:
        print(f"::error::the 2-vCPU runner budget is exceeded by rung(s): {', '.join(failed)} "
              f"— shrink a request in that rung (zeroroot-ai/charts helm/gibson/values-<rung>.yaml), "
              f"never the baseline profile an operator installs", file=sys.stderr)
        return 1

    shape = " and ".join(f"{r} {totals[r][0]}m/{totals[r][1]:.0f}Mi" for r in RUNGS)
    if len({totals[r] for r in RUNGS}) == 1:
        print(f"✅ every rung ({shape}) keeps the platform, Velero, metrics-server, "
              f"kube-system and the seeded tenant under the 2-vCPU runner budget, "
              f"and the rungs still agree")
    else:
        print(f"✅ every rung ({shape}) is under the 2-vCPU runner budget.")
        print("   NOTE: the rungs no longer measure the same. That is allowed "
              "(ADR-0090 keeps them separate so either may change); say why in "
              "the rung that changed.")
    return 0


def selftest() -> int:
    if not OVERAGE_FIXTURE.is_file():
        die(f"self-test fixture missing: {OVERAGE_FIXTURE}")
    baseline = CHARTS_ROOT / "helm/gibson/values-baseline.yaml"
    # The planted overage: the clean overlays plus one request raised past
    # the whole budget. The guard must fail on it.
    u, v = umbrella_rung("ci"), velero_rung("ci")
    rows, cpu, mem = measure([baseline, u, OVERAGE_FIXTURE], [v], METRICS_OVERLAY)
    if cpu <= CPU_BUDGET_M:
        die(f"self-test: the planted overage ({cpu}m) did not exceed the budget — the guard cannot fail")
    # The restore helper: the Velero overlay without its fs-restore-action-config
    # ConfigMap puts Velero's 100m default on the node, and that must not fit.
    # This is the shape of run 34233760977, planted.
    velero_doc = yaml.safe_load(v.read_text()) or {}
    if not (velero_doc.get("velero", {}).get("configMaps") or {}):
        die("self-test: the Velero rung carries no configMaps, so the restore helper runs at Velero's default request")
    velero_doc["velero"].pop("configMaps")
    with tempfile.NamedTemporaryFile("w", suffix=".values.yaml", delete=False) as tf:
        yaml.safe_dump(velero_doc, tf)
        no_cm = Path(tf.name)
    try:
        rows2, cpu2, mem2 = measure([baseline, u], [no_cm], METRICS_OVERLAY)
    finally:
        no_cm.unlink()
    helper = [r for r in rows2 if r[0].startswith("restored canary/restore-helper")]
    if not helper or helper[0][1] != RESTORE_HELPER_DEFAULT_CPU_M:
        die("self-test: without the ConfigMap the restore helper row must read Velero's 100m default")
    # The guard counts that default in the total. The self-test proves the
    # count, not that the total is over the budget: whether it fits depends
    # on what the chart runs today (charts#563 freed the 700m of the platform
    # Neo4j), and a self-test keyed to that would need a re-pin after each
    # chart change.
    rows_c, cpu_c, mem_c = measure([baseline, u], [v], METRICS_OVERLAY)
    helper_c = [r for r in rows_c if r[0].startswith("restored canary/restore-helper")]
    if not helper_c:
        die("self-test: the clean Velero rung has no restore helper row")
    if cpu2 - cpu_c != RESTORE_HELPER_DEFAULT_CPU_M - helper_c[0][1]:
        die(f"self-test: without fs-restore-action-config the total moves by {cpu2 - cpu_c}m, "
            f"not by the {RESTORE_HELPER_DEFAULT_CPU_M - helper_c[0][1]}m of the helper default — "
            "the guard would not have caught run 34233760977")
    # Unit paths: the parsers must read the shapes the chart emits.
    assert cpu_m("250m") == 250 and cpu_m("1") == 1000 and cpu_m(0.5) == 500
    assert mem_mi("1Gi") == 1024 and mem_mi("512Mi") == 512 and round(mem_mi("1024Ki")) == 1
    print(f"✅ self-test: the planted overage measures {cpu}m > {CPU_BUDGET_M}m and is rejected; without fs-restore-action-config the total counts the helper default ({cpu2}m, not {cpu_c}m); unit parsers agree")
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv[1:] else guard())
