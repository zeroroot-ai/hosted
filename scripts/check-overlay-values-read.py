#!/usr/bin/env python3
"""check-overlay-values-read.py — each env overlay sets only values its pinned chart reads.

Helm ignores a value that no template reads. So an overlay key that the
chart deleted, renamed or never had renders cleanly and does nothing. Two
failures came from that (hosted#537):

  * hosted#526 moved the billing values while the pins stayed on charts
    0.136.8, which read none of them. The next bring-up from main would
    have installed billing in neither the old shape nor the new one.
  * The setec runtime agent and installer keys stayed in the overlays after
    setec#198 deleted both. Each reader of the overlay saw a knob that
    does nothing.

For every env whose `RECREATE_UP_<env>` in the Makefile runs recreate-aws.sh
or recreate-ec2.sh, the guard reads the umbrella chart version the env pins
(the OCI source of gitops/envs/<env>/gibson.yaml), gets that published chart,
and walks gitops/envs/<env>/values.yaml against it. A key is read when one
of these holds, in the chart (or subchart) the key belongs to:

  1. the default values.yaml of the chart declares it,
  2. a template of the chart names the key,
  3. an ancestor key is passed whole to a template through toYaml, tpl or
     range, so the chart takes any key under it (for example
     zitadel.configmapConfig).

`global` is shared by every chart and is not checked. A key under a default
that is an empty map, null, a list or a scalar is not checked either: the
chart takes a free shape there.

Everything else fails, with the key path. Delete the key, or move the pin to
the chart that reads it.

The chart comes from oci://ghcr.io/zeroroot-ai/charts/gibson with `helm pull`,
which needs no login. CHART_TGZ_DIR names a directory that already holds
gibson-<version>.tgz, for a run with no network.

Run:  scripts/check-overlay-values-read.py
"""

from __future__ import annotations

import io
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "gitops" / "envs"
MAKEFILE = ROOT / "Makefile"
OCI_REPO = "ghcr.io/zeroroot-ai/charts"
CHART = "gibson"
PASS_WHOLE = re.compile(r"\b(toYaml|tpl|range)\b")


def overlay_envs(makefile_text: str) -> list[str]:
    envs = re.findall(
        r"^RECREATE_UP_(\w+)\s*:=\s*scripts/recreate-(?:aws|ec2)\.sh", makefile_text, re.M)
    return sorted(set(envs))


def pinned_version(app_text: str) -> str | None:
    """The targetRevision of the umbrella source of a platform Application."""
    doc = yaml.safe_load(app_text) or {}
    for src in ((doc.get("spec") or {}).get("sources") or []):
        if src.get("repoURL") == OCI_REPO and src.get("chart") == CHART:
            return str(src.get("targetRevision") or "") or None
    return None


class Chart:
    """One chart of a packaged umbrella: its defaults, its template text and
    its subcharts by values key."""

    def __init__(self, files: dict[str, str], prefix: str):
        self.defaults = yaml.safe_load(files.get(prefix + "values.yaml", "") or "") or {}
        own = [n for n in files
               if n.startswith(prefix + "templates/") and "/charts/" not in n[len(prefix):]]
        self.templates = "\n".join(files[n] for n in sorted(own))
        self.subcharts: dict[str, Chart] = {}
        meta = yaml.safe_load(files.get(prefix + "Chart.yaml", "") or "") or {}
        for dep in meta.get("dependencies") or []:
            name = dep.get("name") or ""
            key = dep.get("alias") or name
            for d in (name, key):
                sub = "%scharts/%s/" % (prefix, d)
                if sub + "Chart.yaml" in files:
                    self.subcharts[key] = Chart(files, sub)
                    break

    def names(self, key: str) -> bool:
        return re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(key), self.templates) is not None

    def passes_whole(self, key: str) -> bool:
        pat = re.compile(r"(?<![\w-])%s(?![\w-])" % re.escape(key))
        return any(PASS_WHOLE.search(line) and pat.search(line)
                   for line in self.templates.splitlines())


def load_chart(tgz_bytes: bytes) -> Chart:
    files: dict[str, str] = {}
    with tarfile.open(fileobj=io.BytesIO(tgz_bytes), mode="r:gz") as tf:
        for m in tf.getmembers():
            if m.isfile() and (m.name.endswith((".yaml", ".yml", ".tpl", ".txt", ".json"))):
                f = tf.extractfile(m)
                if f is not None:
                    files[m.name] = f.read().decode("utf-8", "replace")
    return Chart(files, CHART + "/")


def unread(chart: Chart, overlay: dict) -> list[str]:
    out: list[str] = []

    def walk(c: Chart, defaults, node: dict, path: list[str], ancestors: list[str]) -> None:
        for key, value in node.items():
            key = str(key)
            here = path + [key]
            if not ancestors and key == "global":
                continue
            if not ancestors and key in c.subcharts:
                if isinstance(value, dict):
                    sub = c.subcharts[key]
                    walk(sub, sub.defaults, value, here, [])
                continue
            if isinstance(defaults, dict) and key in defaults:
                d = defaults[key]
                if isinstance(value, dict) and isinstance(d, dict) and d:
                    walk(c, d, value, here, ancestors + [key])
                continue
            if c.names(key) or any(c.passes_whole(a) for a in ancestors):
                continue
            out.append(".".join(here))

    walk(chart, chart.defaults, overlay, [], [])
    return out


def fetch(version: str, cache: dict[str, bytes]) -> bytes:
    if version in cache:
        return cache[version]
    local = os.environ.get("CHART_TGZ_DIR")
    if local:
        p = pathlib.Path(local) / ("%s-%s.tgz" % (CHART, version))
        cache[version] = p.read_bytes()
        return cache[version]
    with tempfile.TemporaryDirectory() as tmp:
        res = subprocess.run(
            ["helm", "pull", "oci://%s/%s" % (OCI_REPO, CHART), "--version", version,
             "--destination", tmp], capture_output=True, text=True, check=False)
        if res.returncode != 0:
            raise RuntimeError("helm pull %s %s failed: %s" % (CHART, version, res.stderr.strip()[-400:]))
        cache[version] = (pathlib.Path(tmp) / ("%s-%s.tgz" % (CHART, version))).read_bytes()
    return cache[version]


# ---------------------------------------------------------------------------
# The failing fixtures, run on every invocation. A guard that cannot fail is
# worse than no guard.
# ---------------------------------------------------------------------------
def fixture_tgz() -> bytes:
    files = {
        "gibson/Chart.yaml": "name: gibson\ndependencies:\n  - name: gibson-workloads\n"
                             "  - name: zitadel-chart\n    alias: zitadel\n",
        "gibson/values.yaml": "platformPostgres:\n  instances: 3\n",
        "gibson/templates/pg.yaml": "{{ .Values.platformPostgres.instances }}\n",
        "gibson/charts/gibson-workloads/Chart.yaml": "name: gibson-workloads\n",
        "gibson/charts/gibson-workloads/values.yaml":
            "gibson:\n  replicas: 1\n  auditExport:\n    bucket: \"\"\n"
            "  podAnnotations: {}\ndashboard:\n  billing:\n    enabled: false\n",
        "gibson/charts/gibson-workloads/templates/d.yaml":
            "{{ .Values.gibson.replicas }} {{ .Values.gibson.auditExport.bucket }}\n"
            "{{ with .Values.gibson }}{{ .entitlementsEndpoint }}{{ end }}\n",
        "gibson/charts/zitadel-chart/Chart.yaml": "name: zitadel-chart\n",
        "gibson/charts/zitadel-chart/values.yaml": "zitadel:\n  configmapConfig:\n    Log: {}\n",
        "gibson/charts/zitadel-chart/templates/cm.yaml":
            "{{ .Values.zitadel.configmapConfig | toYaml }}\n",
    }
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
    return buf.getvalue()


SELF_TEST = [
    # (name, overlay, expected unread paths)
    ("a key the defaults declare", {"gibson-workloads": {"gibson": {"replicas": 2}}}, []),
    ("a key only a template names", {"gibson-workloads": {"gibson": {"entitlementsEndpoint": "x"}}}, []),
    ("a key under a free map", {"gibson-workloads": {"gibson": {"podAnnotations": {"a": "b"}}}}, []),
    ("a key under a map passed whole through toYaml",
     {"zitadel": {"zitadel": {"configmapConfig": {"ExternalPort": 443}}}}, []),
    ("global is shared and not checked", {"global": {"anything": 1}}, []),
    ("the hosted#537 defect: a value the pinned chart does not read",
     {"gibson-workloads": {"dashboard": {"billing": {"accountLink": "x"}}}},
     ["gibson-workloads.dashboard.billing.accountLink"]),
    ("a key that setec#198 deleted",
     {"gibson-workloads": {"setec": {"installer": {"enabled": False}}}},
     ["gibson-workloads.setec"]),
    ("an umbrella key that no chart reads", {"platformPostgres": {"recovery": {"x": 1}}},
     ["platformPostgres.recovery"]),
    ("a subchart reached by its alias, with an unread key",
     {"zitadel": {"replicaCount": 2}}, ["zitadel.replicaCount"]),
]


def self_test() -> list[str]:
    out = []
    chart = load_chart(fixture_tgz())
    for name, overlay, want in SELF_TEST:
        got = unread(chart, overlay)
        if got != want:
            out.append("self-test %r: expected %s, got %s" % (name, want or "no finding", got or "no finding"))
    app = ("spec:\n  sources:\n    - repoURL: %s\n      chart: gibson\n      targetRevision: \"0.1.0\"\n"
           "    - repoURL: https://github.com/zeroroot-ai/hosted\n      targetRevision: main\n" % OCI_REPO)
    if pinned_version(app) != "0.1.0":
        out.append("self-test: pinned_version no longer reads the umbrella pin")
    if overlay_envs("RECREATE_UP_kind := scripts/recreate-kind.sh x\n"
                    "RECREATE_UP_staging := scripts/recreate-ec2.sh x staging\n") != ["staging"]:
        out.append("self-test: overlay_envs no longer reads the recreate rows")
    return out


def main() -> int:
    failures = self_test()
    envs = overlay_envs(MAKEFILE.read_text(encoding="utf-8"))
    if not envs:
        failures.append("the Makefile names no env whose stage 2 is the git overlay; "
                        "this guard would check nothing")
    cache: dict[str, bytes] = {}
    checked = []
    for env in envs:
        app = ENVS / env / "gibson.yaml"
        version = pinned_version(app.read_text(encoding="utf-8")) if app.is_file() else None
        if not version:
            failures.append("gitops/envs/%s/gibson.yaml pins no %s/%s version" % (env, OCI_REPO, CHART))
            continue
        try:
            chart = load_chart(fetch(version, cache))
        except (RuntimeError, OSError) as err:
            failures.append("could not get chart %s %s for %s: %s" % (CHART, version, env, err))
            continue
        overlay = yaml.safe_load((ENVS / env / "values.yaml").read_text(encoding="utf-8")) or {}
        for path in unread(chart, overlay):
            failures.append("gitops/envs/%s/values.yaml sets %s, which charts %s does not read. "
                            "Delete it, or move the pin to the chart that reads it (hosted#537)."
                            % (env, path, version))
        checked.append("%s@%s" % (env, version))
    if failures:
        for f in failures:
            print("::error::" + f)
        return 1
    print("ok: every overlay key is read by its pinned chart (%s)" % ", ".join(checked))
    return 0


if __name__ == "__main__":
    sys.exit(main())
