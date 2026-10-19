#!/usr/bin/env python3
"""check-helm-paths-rooted.py — a path into a helm tree is rooted at CHARTS_ROOT.

This repository holds no chart source (ADR-0086): all of it moved to
zeroroot-ai/charts on 2026-09-04. scripts/check-no-chart-source.py fails the
build on a `Chart.yaml` or a Helm template outside the two SaaS overlay
charts (hosted#415). This guard is the other half: a SCRIPT that reaches into
`helm/` relative to itself.

Two did, and both were dead on arrival (hosted#363):

    test/preflight/kind-preflight.sh:15
      CHART_DIR="$(cd "$(dirname "$0")/../../helm/gibson" && pwd)"
      -> cd: test/preflight/../../helm/gibson: No such file or directory

    scripts/stripe-webhook-preflight.sh:45
      PLANS_FILE="${PLANS_FILE:-${SCRIPT_DIR}/../helm/gibson-workloads/files/plans.yaml}"
      -> the documented invocation read a path that cannot exist, so the
         lookupKey check had nothing to compare against

The first failed loudly on line 15 under `set -euo pipefail`, which is the
better of the two outcomes. The second had a working override, so it only broke
for anyone who followed the usage in its own header.

THE RULE

A `/helm/` — a helm segment with a path separator in front of it — must have
`CHARTS_ROOT` on the same line. That is the whole rule, and it draws the line
where the language does:

    "${SCRIPT_DIR}/../helm/gibson-workloads/files/plans.yaml"   a path   -> must be rooted
    "$CHARTS_ROOT/helm/gibson"                                  a path   -> rooted, fine
    "no chart golden renders at {charts_root}/helm/testdata"    a path   -> rooted, fine
    "enabled by default per helm/gibson-workloads/values.yaml"  a name   -> prose, untouched

A JSON pointer is not a path either. `/spec/sources/0/helm/parameters`
addresses a field of an Argo Application (D91), and its `helm` follows an
array index. A directory of this repo is never named by a number, so a
`/helm/` right after a numeric segment is a pointer, and it passes.

Prose that names a chart file is useful and stays. A leading separator is what
turns a name into something a shell or an open() will try to resolve, and
nothing in this repo can resolve it without CHARTS_ROOT.

  check-helm-paths-rooted.py             exit 1 on an unrooted path
  check-helm-paths-rooted.py --selftest  prove the fixtures fail and the tree is clean
"""
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TREES = ("scripts", "test", "bootstrap", "gitops")
SUFFIXES = (".sh", ".py", ".bats")

# A helm segment with a separator in front of it. The separator may be the
# literal "/" of a relative path or the "/" that follows a variable expansion.
# Not when the segment before it is a number: that is the array index of a
# JSON pointer (/spec/sources/0/helm/parameters), not a directory.
PATH_INTO_HELM = re.compile(r'(?<!/[0-9])(?<!/[0-9][0-9])/helm/')
ROOTED = re.compile(r'charts_root', re.I)


def offenders(text: str, label: str) -> list[str]:
    out = []
    for n, line in enumerate(text.split("\n"), 1):
        # A comment resolves nothing. `scripts/recreate-aws.sh` writes "the
        # kubernetes/helm/kubectl providers", which is a list of Terraform
        # provider names and not a directory, and that is the whole reason this
        # judges code lines only.
        if line.lstrip().startswith("#"):
            continue
        if not PATH_INTO_HELM.search(line):
            continue
        if ROOTED.search(line):
            continue
        out.append(f"{label}:{n}: {line.strip()[:120]}")
    return out


def files() -> list[pathlib.Path]:
    out = []
    for tree in TREES:
        for p in sorted((ROOT / tree).rglob("*")):
            if p.is_file() and p.suffix in SUFFIXES and p.name != os.path.basename(__file__):
                out.append(p)
    return out


def check() -> list[str]:
    bad = []
    for p in files():
        bad += offenders(p.read_text(errors="replace"), str(p.relative_to(ROOT)))
    return bad


BAD_RELATIVE = '''CHART_DIR="$(cd "$(dirname "$0")/../../helm/gibson" && pwd)"'''
BAD_EXPANDED = '''readonly PLANS_FILE="${PLANS_FILE:-${SCRIPT_DIR}/../helm/gibson-workloads/files/plans.yaml}"'''
GOOD = '\n'.join([
    'CHARTS_ROOT="${CHARTS_ROOT:-$(pwd)/../charts}"',
    'CHART="$CHARTS_ROOT/helm/gibson"',
    '# the chart source has no helm/gibson-velero/values-kind.yaml',
    'fail "enabled by default per helm/gibson-workloads/values.yaml"',
    'print(f"no chart golden renders at {charts_root}/helm/testdata/golden")',
    '#            the kubernetes/helm/kubectl providers read module.cluster',
    '# CHART_DIR="$(dirname "$0")/../../helm/gibson"   <- a commented-out path',
    """-p '[{"op":"remove","path":"/spec/sources/0/helm/parameters"}]'""",
])
# A pointer on the line does not excuse a real path beside it.
BAD_AFTER_POINTER = '''patch -p "/spec/sources/0/helm/x"; cat "$HERE/../helm/gibson/values.yaml"'''
BAD_DIGIT_DIR = '''cat "${SCRIPT_DIR}/v2/../helm/gibson/values.yaml"'''


def selftest() -> int:
    for name, src, want in (
        ("a relative path into helm/", BAD_RELATIVE, 1),
        ("an expanded path into helm/", BAD_EXPANDED, 1),
        ("a real path on the same line as a JSON pointer", BAD_AFTER_POINTER, 1),
        ("a path whose helm/ follows a directory v2/..", BAD_DIGIT_DIR, 1),
        ("rooted paths, prose and a JSON pointer", GOOD, 0),
    ):
        got = offenders(src, "fixture")
        if len(got) != want:
            print(f"SELFTEST FAIL: {name} must yield {want} offender(s), got {len(got)}: {got}")
            return 1
    live = check()
    if live:
        print("SELFTEST FAIL: the tree is not clean:\n  " + "\n  ".join(live))
        return 1
    print(f"OK: a relative and an expanded path into helm/ both fail; a CHARTS_ROOT path, "
          f"prose, a provider list, a commented-out path and a JSON pointer all pass; {len(files())} script(s) clean")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    bad = check()
    if bad:
        print("❌ paths into a helm tree that CHARTS_ROOT does not root:\n  " + "\n  ".join(bad))
        print("  this repo holds no chart source (ADR-0086). Resolve it through "
              "$CHARTS_ROOT, the way test/edge/harness.sh does.")
        return 1
    print(f"✓ helm-paths-rooted: every path into a helm tree in {len(files())} script(s) is rooted at CHARTS_ROOT")
    return 0


if __name__ == "__main__":
    sys.exit(main())
