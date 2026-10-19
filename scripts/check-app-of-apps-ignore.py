#!/usr/bin/env python3
"""check-app-of-apps-ignore.py — the app-of-apps ignores one path of one
Application, and nothing else (D91).

The app-of-apps (bootstrap/modules/argocd/main.tf, kubectl_manifest
app_of_apps) runs selfHeal. Each path it ignores is a path that Git no longer
controls on a live Application. D91 opens exactly one such path: the Helm
parameters of the gibson chart source, where a restore puts the three
Postgres recovery values that it derives from the named backup. This guard
keeps it to that one path:

  1. The app_of_apps resource has exactly one ignoreDifferences entry:
     group argoproj.io, kind Application, name gibson, jsonPointers
     ["/spec/sources/0/helm/parameters"], and no other key. Its syncOptions
     hold RespectIgnoreDifferences=true, or a sync would still revert it.
  2. No other ignoreDifferences is in bootstrap/modules/argocd, and no root
     Application of gitops/envs/<env>/root.yaml has one.
  3. The restore sets exactly the three parameter names of D91
     (RECOVERY_PARAMETERS in scripts/lib/restore-recovery.sh).
  4. No env overlay gibson.yaml sets helm.parameters on that source. Git
     values there would be ignored after the first apply, and that is a seam
     nobody reviews.

The fixtures run first, on every invocation. A guard that cannot fail is
worse than no guard.

Run:  scripts/check-app-of-apps-ignore.py
"""
from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE = ROOT / "bootstrap" / "modules" / "argocd"
ENVS = ROOT / "gitops" / "envs"
RECOVERY_LIB = ROOT / "scripts" / "lib" / "restore-recovery.sh"

WANT_ENTRY = {
    "group": "argoproj.io",
    "kind": "Application",
    "name": "gibson",
    "jsonPointers": ["/spec/sources/0/helm/parameters"],
}
WANT_PARAMETERS = [
    "platformPostgres.recovery.backupID",
    "platformPostgres.recovery.serverName",
    "platformPostgres.backup.serverName",
]


def strip_comments(hcl: str) -> str:
    """HCL with each # and // comment removed, strings kept."""
    out = []
    for line in hcl.splitlines():
        res, in_str, i = [], False, 0
        while i < len(line):
            c = line[i]
            if c == '"' and (i == 0 or line[i - 1] != "\\"):
                in_str = not in_str
            if not in_str and (c == "#" or line.startswith("//", i)):
                break
            res.append(c)
            i += 1
        out.append("".join(res))
    return "\n".join(out)


def resource_block(hcl: str, rtype: str, rname: str) -> str | None:
    m = re.search(r'^resource\s+"%s"\s+"%s"\s*\{' % (re.escape(rtype), re.escape(rname)), hcl, re.M)
    if not m:
        return None
    nxt = re.search(r'^(resource|data|module|locals|variable|output)\b', hcl[m.end():], re.M)
    return hcl[m.start(): m.end() + (nxt.start() if nxt else len(hcl))]


def bracket_body(text: str, start: int) -> str:
    """The text inside the [ ... ] that opens at text[start]."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "[":
            depth += 1
        elif text[i] == "]":
            depth -= 1
            if depth == 0:
                return text[start + 1: i]
    raise ValueError("unbalanced [ at %d" % start)


def parse_entries(body: str) -> list[dict]:
    """Each { key = value } object of an HCL list of objects."""
    entries = []
    for obj in re.findall(r"\{([^{}]*)\}", body):
        e: dict = {}
        for k, v in re.findall(r'(\w+)\s*=\s*(\[[^\]]*\]|"[^"]*"|\S+)', obj):
            v = v.strip()
            if v.startswith("["):
                e[k] = re.findall(r'"([^"]*)"', v)
            else:
                e[k] = v.strip('"')
        entries.append(e)
    return entries


def module_failures(files: dict[str, str]) -> list[str]:
    out = []
    main = files.get("main.tf")
    if main is None:
        return ["bootstrap/modules/argocd/main.tf is missing"]
    clean = {n: strip_comments(t) for n, t in files.items()}
    block = resource_block(clean["main.tf"], "kubectl_manifest", "app_of_apps")
    if block is None:
        return ["main.tf has no resource kubectl_manifest app_of_apps, so step 1 checked nothing"]
    hits = [m.start() for m in re.finditer(r"\bignoreDifferences\s*=\s*\[", block)]
    if len(hits) != 1:
        out.append("the app_of_apps resource has %d ignoreDifferences lists, not 1" % len(hits))
    else:
        start = block.index("[", hits[0])
        entries = parse_entries(bracket_body(block, start))
        if entries != [WANT_ENTRY]:
            out.append("the app-of-apps ignores %r. D91 permits exactly one entry: %r" % (entries, WANT_ENTRY))
    if not re.search(r'"RespectIgnoreDifferences=true"', block):
        out.append("the app_of_apps syncOptions have no RespectIgnoreDifferences=true, so a sync reverts the "
                   "restore parameters that the diff ignores")
    total = sum(len(re.findall(r"\bignoreDifferences\b", t)) for t in clean.values())
    if total != len(hits):
        out.append("bootstrap/modules/argocd has %d ignoreDifferences outside app_of_apps. D91 permits none"
                   % (total - len(hits)))
    return out


def root_failures(roots: dict[str, str]) -> list[str]:
    out = []
    for name, text in roots.items():
        for doc in yaml.safe_load_all(text):
            if doc and (doc.get("spec") or {}).get("ignoreDifferences"):
                out.append("%s: the root Application ignores differences. Only the app-of-apps may, on one path (D91)"
                           % name)
    return out


def parameter_failures(lib_text: str) -> list[str]:
    m = re.search(r'^RECOVERY_PARAMETERS="([^"]*)"', lib_text, re.M)
    if not m:
        return ["scripts/lib/restore-recovery.sh has no RECOVERY_PARAMETERS line, so step 3 checked nothing"]
    got = m.group(1).split()
    if got != WANT_PARAMETERS:
        return ["the restore sets the parameters %r. D91 permits exactly %r" % (got, WANT_PARAMETERS)]
    return []


def overlay_failures(apps: dict[str, str]) -> list[str]:
    out = []
    for name, text in apps.items():
        doc = yaml.safe_load(text) or {}
        src = ((doc.get("spec") or {}).get("sources") or [None])[0] or {}
        if (src.get("helm") or {}).get("parameters"):
            out.append("%s sets helm.parameters on the gibson chart source. That path is the restore seam that the "
                       "app-of-apps ignores, so Git values there are not reviewed after the first apply (D91)" % name)
    return out


GOOD_MAIN = '''
resource "kubectl_manifest" "app_of_apps" {
  yaml_body = yamlencode({
    spec = {
      # a comment with ignoreDifferences in it does not count
      ignoreDifferences = [
        {
          group        = "argoproj.io"
          kind         = "Application"
          name         = "gibson"
          jsonPointers = ["/spec/sources/0/helm/parameters"]
        },
      ]
      syncPolicy = {
        syncOptions = [
          "RespectIgnoreDifferences=true",
        ]
      }
    }
  })
}
'''


def self_test() -> list[str]:
    out = []
    if module_failures({"main.tf": GOOD_MAIN}):
        out.append("self-test: the one permitted entry failed: %r" % module_failures({"main.tf": GOOD_MAIN}))
    wide = GOOD_MAIN.replace('"/spec/sources/0/helm/parameters"', '"/spec/sources/0/helm"')
    if not module_failures({"main.tf": wide}):
        out.append("self-test: a wider ignored path passed")
    other = GOOD_MAIN.replace('name         = "gibson"', 'name         = "gibson-velero"')
    if not module_failures({"main.tf": other}):
        out.append("self-test: the same path on another Application passed")
    two = GOOD_MAIN.replace("        },\n      ]", "        },\n        {\n          kind = \"Application\"\n"
                            "          jqPathExpressions = [\".spec\"]\n        },\n      ]")
    if not module_failures({"main.tf": two}):
        out.append("self-test: a second ignored entry passed")
    jq = GOOD_MAIN.replace('jsonPointers = ["/spec/sources/0/helm/parameters"]',
                           'jsonPointers = ["/spec/sources/0/helm/parameters"]\n          jqPathExpressions = [".x"]')
    if not module_failures({"main.tf": jq}):
        out.append("self-test: an extra key on the one entry passed")
    if not module_failures({"main.tf": GOOD_MAIN.replace('"RespectIgnoreDifferences=true",', "")}):
        out.append("self-test: an app-of-apps without RespectIgnoreDifferences passed")
    if not module_failures({"main.tf": GOOD_MAIN, "appprojects.tf": 'x = { ignoreDifferences = [] }'}):
        out.append("self-test: an ignoreDifferences elsewhere in the module passed")
    if not root_failures({"root.yaml": "spec:\n  ignoreDifferences:\n    - kind: Application\n"}):
        out.append("self-test: a root Application that ignores differences passed")
    if parameter_failures('RECOVERY_PARAMETERS="%s"\n' % " ".join(WANT_PARAMETERS)):
        out.append("self-test: the three D91 parameters failed")
    if not parameter_failures('RECOVERY_PARAMETERS="%s global.domain"\n' % " ".join(WANT_PARAMETERS)):
        out.append("self-test: a fourth restore parameter passed")
    if not overlay_failures({"gibson.yaml": "spec:\n  sources:\n    - chart: gibson\n      helm:\n"
                                            "        parameters:\n          - name: a\n            value: b\n"}):
        out.append("self-test: an overlay with helm.parameters on the gibson source passed")
    return out


def main() -> int:
    failures = self_test()
    files = {p.name: p.read_text(encoding="utf-8") for p in sorted(MODULE.glob("*.tf"))}
    failures += module_failures(files)
    roots = {str(p.relative_to(ROOT)): p.read_text(encoding="utf-8") for p in sorted(ENVS.glob("*/root.yaml"))}
    failures += root_failures(roots)
    failures += parameter_failures(RECOVERY_LIB.read_text(encoding="utf-8"))
    apps = {str(p.relative_to(ROOT)): p.read_text(encoding="utf-8") for p in sorted(ENVS.glob("*/gibson.yaml"))}
    if not apps:
        failures.append("no gitops/envs/<env>/gibson.yaml, so step 4 checked nothing")
    failures += overlay_failures(apps)
    if failures:
        for f in failures:
            print("::error::" + f)
        return 1
    print("ok: the app-of-apps ignores only /spec/sources/0/helm/parameters of Application gibson, the restore "
          "sets only the three D91 parameters, and no overlay sets that path (%d envs)" % len(apps))
    return 0


if __name__ == "__main__":
    sys.exit(main())
