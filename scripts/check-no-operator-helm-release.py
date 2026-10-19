#!/usr/bin/env python3
"""Guard: stage 1 (Terraform) installs Argo CD, never the platform operators.

ADR-0083 and deploy#1728. The umbrella chart owns cert-manager,
external-secrets, external-dns and the CloudNativePG operator as subcharts,
so the same chart brings them up on kind, EKS and a customer cluster. Before
this, kind installed three of them from bootstrap/kind/gibson/operators.tf and EKS
installed three from bootstrap/eks/gibson/modules/bootstrap-addons, and the two lists
drifted (different versions, different namespaces, a `cnpg.enabled` seam in
the chart to pick which operator was real). A second copy of any of these in
Terraform is a parallel codepath (ADR-0027): two operators fight over one
CRD set, or one substrate silently runs a different version.

WHAT IT CHECKS
    Every `resource "helm_release"` block under bootstrap/, substrate/ and
    targets/ is parsed for its `chart = "..."` attribute. The last path segment of that
    value (so `oci://ghcr.io/external-secrets/charts/external-secrets` and
    `external-secrets` both count) must not be one of the four operator
    charts. Any hit fails the run and names the file and the resource.

Usage:
    scripts/check-no-operator-helm-release.py             # the guard
    scripts/check-no-operator-helm-release.py --selftest  # prove it can fail
Exit:
    0 clean · 1 an operator helm_release exists · 2 self-test broken

The failing fixture lives in tests/guards/operator-helm-release/bad/ and the
passing one in .../good/. --selftest runs the scanner over both: the bad
fixture must produce exactly one finding per operator chart, the good one
none. A guard whose fixture passes is a guard that cannot fail.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The Terraform roots of this repo. Before hosted#409 this named kind/, eks/
# and terraform/, three directories that the split of 2026-09-04 moved under
# bootstrap/. The scan read no file and reported a clean tree.
SCAN_DIRS = ("bootstrap", "substrate", "targets")
FIXTURES = ROOT / "tests" / "guards" / "operator-helm-release"

# The four operators the umbrella owns (helm/gibson/Chart.yaml).
OPERATOR_CHARTS = frozenset(
    {"external-secrets", "cert-manager", "cloudnative-pg", "external-dns"}
)

BLOCK_RE = re.compile(r'resource\s+"helm_release"\s+"([^"]+)"\s*\{')
CHART_RE = re.compile(r'^\s*chart\s*=\s*"([^"]+)"', re.M)

# Directory names never scanned under a root: provider/module build output and
# sibling checkouts. Matched on the path RELATIVE to the scanned root, so a
# checkout that itself lives under a .worktrees/ directory still scans.
SKIP_DIRS = frozenset({".terraform", ".worktrees"})


def helm_releases(path: pathlib.Path) -> list[tuple[str, str, str]]:
    """-> [(file, resource name, chart)] for every helm_release under path."""
    found: list[tuple[str, str, str]] = []
    if not path.is_dir():
        return found
    for tf in sorted(path.rglob("*.tf")):
        if SKIP_DIRS.intersection(tf.relative_to(path).parts):
            continue
        text = tf.read_text(encoding="utf-8", errors="replace")
        blocks = list(BLOCK_RE.finditer(text))
        for i, m in enumerate(blocks):
            end = blocks[i + 1].start() if i + 1 < len(blocks) else len(text)
            cm = CHART_RE.search(text, m.end(), end)
            if cm:
                found.append((str(tf), m.group(1), cm.group(1)))
    return found


def tf_file_count(roots: list[pathlib.Path]) -> int:
    """How many Terraform files the scan reads under the roots."""
    n = 0
    for root in roots:
        if not root.is_dir():
            continue
        for tf in root.rglob("*.tf"):
            if not SKIP_DIRS.intersection(tf.relative_to(root).parts):
                n += 1
    return n


def findings(roots: list[pathlib.Path]) -> list[str]:
    out: list[str] = []
    for root in roots:
        for tf, name, chart in helm_releases(root):
            short = chart.rstrip("/").split("/")[-1]
            if short in OPERATOR_CHARTS:
                try:
                    rel = pathlib.Path(tf).relative_to(ROOT)
                except ValueError:
                    rel = pathlib.Path(tf)
                out.append(f'{rel}: helm_release "{name}" installs {short}')
    return out


def selftest() -> int:
    bad = findings([FIXTURES / "bad"])
    good = findings([FIXTURES / "good"])
    failures: list[str] = []
    hit = {f.split(" installs ")[-1] for f in bad}
    if hit != set(OPERATOR_CHARTS):
        failures.append(
            f"bad fixture: expected one finding per operator chart {sorted(OPERATOR_CHARTS)}, "
            f"got {sorted(hit)}"
        )
    if good:
        failures.append(f"good fixture produced findings: {good}")
    if not (FIXTURES / "bad").is_dir() or not (FIXTURES / "good").is_dir():
        failures.append(f"fixtures missing under {FIXTURES.relative_to(ROOT)}")
    if failures:
        for f in failures:
            print(f"  ✗ {f}")
        print("❌ selftest failed: the guard cannot fail the way it claims")
        return 2
    print(f"✅ selftest passed: the bad fixture fails on {len(bad)} release(s), the good one on none")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    roots = [ROOT / d for d in SCAN_DIRS]
    missing = [d for d in SCAN_DIRS if not (ROOT / d).is_dir()]
    if missing:
        print(f"❌ the scan directories {missing} do not exist, so the guard would read nothing there")
        return 1
    read = tf_file_count(roots)
    releases = sum(len(helm_releases(r)) for r in roots)
    # A scan that reads no file, or finds no helm_release at all, did not look
    # at stage 1: Argo CD is a helm_release in bootstrap/modules/argocd.
    if read < 10 or releases < 1:
        print(f"❌ the scan read {read} Terraform files and found {releases} helm_release blocks. "
              "It did not look at stage 1")
        return 1
    hits = findings(roots)
    if hits:
        print("❌ Terraform declares a helm_release for an operator the umbrella owns (ADR-0083, deploy#1728):")
        for h in hits:
            print(f"   {h}")
        print()
        print("   cert-manager, external-secrets, external-dns and cloudnative-pg are subcharts of")
        print("   helm/gibson. Stage 1 installs Argo CD only. Delete the release; do not gate it.")
        return 1
    print(f"✅ no operator helm_release under {', '.join(SCAN_DIRS)}: "
          f"{read} Terraform files read, {releases} helm_release blocks checked")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
