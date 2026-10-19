#!/usr/bin/env python3
"""Guard: this repo holds no chart source, except the two SaaS overlay charts.

ADR-0086: `hosted` is a customer of `charts`. It installs the published,
signed OCI chart at a pinned version. ADR-0074 permits two local charts, the
SaaS overlay charts. A third chart in this tree is chart source in the wrong
repo (hosted#415).

WHAT IT CHECKS
    Each tracked file is read by path, and a Helm template also by content:

    1. A `Chart.yaml` outside the allowed charts fails.
    2. A path that holds a `helm/` segment and a `templates/` segment fails.
    3. A file in a `templates/` directory that is a Helm template fails when
       it is outside the allowed charts. A Helm template is a .yaml, .yml,
       .tpl or .txt file that holds `{{` and one of `.Values`, `.Release`,
       `.Chart` or `include`. A Terraform template is not one, so
       `bootstrap/ec2/gibson/templates/` passes.

    The allowed list is keyed by path and holds exactly two charts.

Usage:
    scripts/check-no-chart-source.py             # the guard
    scripts/check-no-chart-source.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 chart source is in the tree · 2 the self-test is broken

The fixtures are in tests/guards/chart-source/.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "guards" / "chart-source"

# ADR-0074. Exactly these two. A third chart needs a decision, not an entry.
ALLOWED_CHARTS = (
    "gitops/saas-overlay/billing-webhook",
    "gitops/saas-overlay/entitlements-svc",
)

HELM_TEMPLATE_SUFFIXES = frozenset({".yaml", ".yml", ".tpl", ".txt"})
HELM_MARK = re.compile(r"\{\{-?[^}]*(\.Values|\.Release|\.Chart|\binclude\b)")


def allowed(rel: str) -> bool:
    return any(rel == c or rel.startswith(c + "/") for c in ALLOWED_CHARTS)


def findings(base: pathlib.Path, rels: list[str]) -> list[str]:
    out: list[str] = []
    for rel in sorted(rels):
        if allowed(rel):
            continue
        parts = rel.split("/")
        if parts[-1] == "Chart.yaml":
            out.append(f"{rel}: a chart outside the two SaaS overlay charts")
            continue
        if "templates" in parts[:-1]:
            if "helm" in parts[: parts.index("templates")]:
                out.append(f"{rel}: a template path under a helm directory")
                continue
            f = base / rel
            if f.suffix in HELM_TEMPLATE_SUFFIXES and f.is_file():
                try:
                    text = f.read_text(encoding="utf-8")
                except (UnicodeDecodeError, OSError):
                    continue
                if HELM_MARK.search(text):
                    out.append(f"{rel}: a Helm template outside the two SaaS overlay charts")
    return out


def tree(base: pathlib.Path) -> list[str]:
    return [str(p.relative_to(base)) for p in base.rglob("*") if p.is_file()]


def selftest() -> int:
    cases = {"bad-third-chart": 2, "bad-helm-templates": 1, "bad-loose-template": 1, "good": 0}
    for name, want in cases.items():
        d = FIXTURES / name
        if not d.is_dir():
            print(f"check-no-chart-source: selftest: the fixture {name} is missing", file=sys.stderr)
            return 2
        got = findings(d, tree(d))
        if len(got) != want:
            print(f"check-no-chart-source: selftest: {name} gave {got}, wanted {want} findings", file=sys.stderr)
            return 2
    if len(ALLOWED_CHARTS) != 2:
        print("check-no-chart-source: selftest: the allowed list must hold exactly two charts", file=sys.stderr)
        return 2
    print("✅ self-test: a third chart, a template under a helm directory and a loose Helm "
          "template are each rejected; the two overlay charts and a Terraform template pass")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], check=True,
                             capture_output=True).stdout.decode().split("\0")
    fixtures_rel = str(FIXTURES.relative_to(ROOT)) + "/"
    rels = [p for p in tracked if p and not p.startswith(fixtures_rel)]
    if len(rels) < 50:
        print(f"check-no-chart-source: only {len(rels)} tracked files, so the scan did not look at the repo",
              file=sys.stderr)
        return 1
    for c in ALLOWED_CHARTS:
        if f"{c}/Chart.yaml" not in rels:
            print(f"check-no-chart-source: the allowed chart {c} does not exist. Remove it from the list",
                  file=sys.stderr)
            return 1
    got = findings(ROOT, rels)
    if got:
        print("check-no-chart-source: chart source is in this repo (ADR-0086):", file=sys.stderr)
        for g in got:
            print(f"  {g}", file=sys.stderr)
        print("  Chart source lives in zeroroot-ai/charts. This repo installs the published chart.",
              file=sys.stderr)
        return 1
    print(f"✅ no chart source outside the two SaaS overlay charts: {len(rels)} tracked files read")
    return 0


if __name__ == "__main__":
    sys.exit(main())
