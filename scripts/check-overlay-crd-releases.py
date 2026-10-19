#!/usr/bin/env python3
"""check-overlay-crd-releases.py — an env that pins a split chart installs both halves.

charts#82 split the operator CustomResourceDefinitions out of `gibson-crds`
into their own published release, `gibson-operator-crds`, from 0.127.2. The
reason was a hard limit: a Helm release record is one Secret, the apiserver
caps a Secret at 1 MiB, and together they were 1131 KB. Apart they are 136 KB
and 699 KB.

Argo never hit that limit, because Argo renders and applies server-side and
writes no release record. So Argo will happily install a `gibson-crds` at
0.127.2 or later and say nothing about the cert-manager, External Secrets and
CloudNativePG CRDs that are no longer in it. The platform then renders custom
resources of kinds the apiserver does not know, and the failure names the CR,
never the missing release.

The overlays are hand-written, so the omission is one forgotten file away. This
is the gate: an environment that pins a version carrying the split must declare
the operator CRDs release too, at the same version, ahead of the chart that
needs it.

It checks TWO kinds of declaration, and the second was the hole this guard
already fell through once. The Argo overlays pin a published version, so a
version comparison tells you whether the split applies. scripts/recreate-kind.sh
packages the charts itself and pins `0.0.0-recreate.<stamp>`, which is below
every real version, so the first check skipped it entirely and the kind exit
test went red for three runs with

    error: the server doesn't have a resource type "externalsecrets"
    error: the server doesn't have a resource type "certificates"

A script that installs from the chart SOURCE always has the split, because the
source is where the split lives. So for those the rule is simpler and stricter:
install one CRD release and you must install the other.

Run:  scripts/check-overlay-crd-releases.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "gitops" / "envs"

# The first published version in which gibson-crds no longer carries the
# operator CRDs. Below this, one release is correct and two would be wrong.
SPLIT_AT = (0, 127, 2)

CRDS_CHART = "gibson-crds"
OPERATOR_CHART = "gibson-operator-crds"


def version_tuple(text: str):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", text.strip().strip('"'))
    return tuple(int(x) for x in m.groups()) if m else None


def applications(env_dir: pathlib.Path):
    """Every Application in one env, as (chart, version, wave, path).

    Read with regular expressions rather than a YAML parser on purpose: these
    files are Argo manifests with comments that carry the reasoning, and this
    check has to run wherever `make check` runs, with no third-party import.
    """
    out = []
    for path in sorted(env_dir.glob("*.yaml")):
        text = path.read_text(encoding="utf-8")
        # Executable lines only: a comment naming a chart must never satisfy
        # this check.
        body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
        chart = re.search(r"^\s*chart:\s*(\S+)", body, re.M)
        rev = re.search(r'^\s*targetRevision:\s*"?([^"\s]+)"?', body, re.M)
        wave = re.search(r'sync-wave:\s*"(-?\d+)"', body)
        if chart and rev:
            out.append((chart.group(1), rev.group(1),
                        int(wave.group(1)) if wave else 0, path))
    return out


def script_failures(items):
    """Failures for installers that build from the chart source.

    `items` is (name, text) pairs rather than paths, so the self-test below can
    hand this the same code a real script goes through.
    """
    out = []
    scanned = 0
    for name, text in items:
        # Executable lines only. This file's own prose names both charts.
        body = "\n".join(l for l in text.splitlines()
                          if not l.lstrip().startswith("#"))
        if CRDS_CHART not in body:
            continue
        scanned += 1
        if OPERATOR_CHART not in body:
            out.append(
                "%s installs %s and never %s. Both live in the chart source, "
                "so a path that installs one must install the other."
                % (name, CRDS_CHART, OPERATOR_CHART))
            continue
        # Order matters here too: the CRDs must be established before anything
        # renders a custom resource of them.
        if body.index(OPERATOR_CHART) > body.index(CRDS_CHART):
            out.append(
                "%s installs %s before %s. The operator CRDs must be "
                "established first." % (name, CRDS_CHART, OPERATOR_CHART))
    return out, scanned


# The failing fixtures, run on every invocation. A guard that cannot fail is
# worse than no guard, and this branch shipped broken once already.
SELF_TEST = [
    ("omits-the-operator-crds.sh",
     'helm upgrade --install gibson-crds "$CHART_DIR/gibson-crds"\n'),
    ("wrong-order.sh",
     'apply_overlay_app gibson-crds\napply_overlay_app gibson-operator-crds\n'),
    # A comment naming only gibson-crds is prose, not an install.
    ("comment-only.sh", '# we used to install gibson-crds here\necho hi\n'),
]


def self_test() -> str | None:
    bad, _ = script_failures(SELF_TEST[:1])
    if len(bad) != 1:
        return "a script installing only %s must fail" % CRDS_CHART
    bad, _ = script_failures(SELF_TEST[1:2])
    if len(bad) != 1 or "before" not in bad[0]:
        return "a script installing the two CRD releases in the wrong order must fail"
    bad, scanned = script_failures(SELF_TEST[2:3])
    if bad or scanned:
        return "a comment naming %s must not count as an install" % CRDS_CHART
    return None


def main() -> int:
    broken = self_test()
    if broken:
        print("✗ check-overlay-crd-releases self-test: %s" % broken, file=sys.stderr)
        return 2

    if not ENVS.is_dir():
        print("✗ no gitops/envs directory", file=sys.stderr)
        return 2

    failures = []
    checked = 0
    for env_dir in sorted(p for p in ENVS.iterdir() if p.is_dir()):
        apps = applications(env_dir)
        crds = [a for a in apps if a[0] == CRDS_CHART]
        if not crds:
            continue
        checked += 1
        _, crds_ver, crds_wave, crds_path = crds[0]
        ver = version_tuple(crds_ver)
        if ver is None or ver < SPLIT_AT:
            continue  # below the split, one release is the whole set

        ops = [a for a in apps if a[0] == OPERATOR_CHART]
        if not ops:
            failures.append(
                "%s pins %s %s, which no longer carries the cert-manager, "
                "External Secrets and CloudNativePG CRDs, and declares no %s "
                "Application. Those CRDs would simply be absent."
                % (env_dir.name, CRDS_CHART, crds_ver, OPERATOR_CHART))
            continue

        _, ops_ver, ops_wave, _ = ops[0]
        if ops_ver != crds_ver:
            failures.append(
                "%s pins %s at %s and %s at %s. They are published together "
                "and must move together."
                % (env_dir.name, CRDS_CHART, crds_ver, OPERATOR_CHART, ops_ver))
        if ops_wave >= crds_wave:
            failures.append(
                "%s syncs %s at wave %d and %s at wave %d. The operator CRDs "
                "must be established first, so their wave must be lower."
                % (env_dir.name, OPERATOR_CHART, ops_wave, CRDS_CHART, crds_wave))

    # Every installer in scripts/, whether it packages the source or applies an
    # Application. No version to compare: the source always carries the split,
    # so naming one release and not the other is always wrong.
    script_bad, script_count = script_failures(
        (p.name, p.read_text(encoding="utf-8", errors="replace"))
        for p in sorted((ROOT / "scripts").glob("*.sh"))
        if p.name != pathlib.Path(__file__).name)
    failures.extend(script_bad)
    checked += script_count

    if failures:
        print("✗ check-overlay-crd-releases:", file=sys.stderr)
        for f in failures:
            print("    %s" % f, file=sys.stderr)
        print("  charts#82 split the release; an overlay that pins the split "
              "must install both halves.", file=sys.stderr)
        return 1

    print("✅ self-test: a missing half, a wrong order and a comment are all "
          "judged correctly")
    print("✅ check-overlay-crd-releases: %d place(s) install the CRDs — every "
          "one declares both releases, operator CRDs first" % checked)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
