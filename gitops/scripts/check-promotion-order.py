#!/usr/bin/env python3
"""Prod must never run a chart version staging has not run first.

The first half of launch blocker 5's exit test (deploy#1194): *prod runs the
chart digest staging tested*.

`check-prod-promotion.sh` already enforces this on a PR that BUMPS prod — it
diffs the change set and requires the new prod version to be one staging is
already pinned to. That is a gate on a transition. It says nothing about the
state the repo is in right now, so a prod pin edited outside a bump-shaped
diff, a bad revert, or a merge that reordered two promotions leaves no trace
it can see.

This is the standing check on the state itself, and it is what the launch
scorecard reads:

  1. every env under envs/ pins a chartVersion that chart-digests.yaml
     records — an unrecorded version is one nothing verified the digest of,
     which is the gap gitops#388 exists to close;
  2. prod's version is not AHEAD of staging's. Equal is the settled state
     after a promotion; behind is the window between staging taking a new
     version and prod following. Ahead means prod is running something
     staging never tested, which is the blocker in one sentence;
  3. drill pins exactly the staging version. Drill is the throwaway copy of
     staging (ADR-0095), and its values.yaml follows the staging values.yaml.
     A drill pin that stays behind renders an old chart against new values.
     Drill run 37460863468 failed that way: drill pinned 0.135.0 while its
     values followed staging to 0.136.8, and the 0.135.0 tenant-operator
     template refused the values (tenantOperator.billing.stripeExpectedMode
     is REQUIRED). bump-chart-version.sh moves drill with each staging bump.

It deliberately does NOT hit the network. `verify-chart-signature.sh` owns the
"does this version still resolve to the recorded digest" question, and it
already has a selftest that proves it rejects a moved tag. Splitting them keeps
the offline assertion runnable with no registry and no credentials.

Usage:
  scripts/check-promotion-order.py            # check this repo
  scripts/check-promotion-order.py --selftest # prove it still rejects
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
LEDGER = REPO / "chart-digests.yaml"
ENVS = REPO / "envs"

# The OCI umbrella chart's targetRevision is the single promotion marker
# (gitops#448). Match it under the ghcr.io/zeroroot-ai/charts source only, so a
# targetRevision belonging to the $values source can never be read by mistake.
# Each gap between the three keys is a run of whole lines, each blank or a
# comment. A line is "[ \t]*" then an optional comment then "\n", so a
# character can belong to one part of the pattern only (no ReDoS).
_GAP = r"(?:[ \t]*(?:#[^\n]*)?\n)*"
CHART_SOURCE = re.compile(
    r"repoURL:[ \t]*ghcr\.io/zeroroot-ai/charts[ \t]*\n"
    + _GAP
    + r"[ \t]*chart:[ \t]*gibson[ \t]*\n"
    + _GAP
    + r'[ \t]*targetRevision:[ \t]*"?([0-9]+\.[0-9]+\.[0-9]+)"?',
)


class Failure(Exception):
    pass


def semver(v: str) -> tuple[int, int, int]:
    major, minor, patch = v.split(".")
    return int(major), int(minor), int(patch)


def pinned_version(env_dir: pathlib.Path) -> str | None:
    """The umbrella chartVersion an env pins, or None if the env pins none."""
    for name in ("gibson.yaml", "apps/gibson.yaml"):
        path = env_dir / name
        if not path.is_file():
            continue
        match = CHART_SOURCE.search(path.read_text())
        if match:
            return match.group(1)
    return None


def recorded_versions(ledger: pathlib.Path) -> set[str]:
    if not ledger.is_file():
        raise Failure(f"{ledger.name} does not exist — nothing records what a tag may mean")
    # Deliberately not yaml.safe_load: this file is also read by a bash script
    # with the same shape assumption, and a parser mismatch between the two is
    # exactly the kind of drift that makes one of them silently pass.
    found = set(re.findall(r'^\s{2}"([0-9]+\.[0-9]+\.[0-9]+)":\s*$', ledger.read_text(), re.M))
    if not found:
        # A reach floor: an empty parse must fail, never silently pass.
        raise Failure(f"parsed zero versions out of {ledger.name} — the file shape changed")
    return found


def check(repo: pathlib.Path, ledger: pathlib.Path, envs: pathlib.Path) -> list[str]:
    pins: dict[str, str] = {}
    for env_dir in sorted(p for p in envs.iterdir() if p.is_dir()):
        version = pinned_version(env_dir)
        if version:
            pins[env_dir.name] = version

    if not pins:
        raise Failure("no env pins an umbrella chartVersion — the check would pass vacuously")

    recorded = recorded_versions(ledger)
    lines = []

    for env, version in pins.items():
        if version not in recorded:
            raise Failure(
                f"{env} pins {version}, which {ledger.name} does not record. "
                f"Nothing has verified what that tag resolves to, so nothing "
                f"stops the tag from moving under it."
            )
        lines.append(f"  {env:<8} {version}  (recorded)")

    if "prod" in pins and "staging" in pins:
        prod, staging = pins["prod"], pins["staging"]
        if semver(prod) > semver(staging):
            raise Failure(
                f"prod pins {prod} but staging pins {staging} — prod is AHEAD. "
                f"Prod is running a chart version staging never tested."
            )
        relation = "equal to" if prod == staging else "behind"
        lines.append(f"  prod is {relation} staging — prod runs a version staging tested first")

    if "drill" in pins:
        if "staging" not in pins:
            raise Failure("drill pins a chart version but staging pins none — drill follows staging (ADR-0095)")
        drill, staging = pins["drill"], pins["staging"]
        if drill != staging:
            raise Failure(
                f"drill pins {drill} but staging pins {staging} — DRILL DIFFERS. "
                f"Drill renders the staging values, so it must pin the staging "
                f"version. Run gitops/scripts/bump-chart-version.sh staging {staging}."
            )
        lines.append("  drill is equal to staging — drill runs the version and values staging runs")

    return lines


def selftest() -> int:
    """Every branch, against scratch files. No repo state, no network."""
    cases = [
        (
            "prod ahead of staging is rejected",
            {"staging": "0.113.0", "prod": "0.115.0"},
            ["0.113.0", "0.115.0"],
            "AHEAD",
        ),
        (
            "a pin the ledger does not record is rejected",
            {"staging": "0.115.0", "prod": "0.113.0"},
            ["0.115.0"],
            "does not record",
        ),
        ("prod behind staging is accepted", {"staging": "0.115.0", "prod": "0.113.0"}, ["0.113.0", "0.115.0"], None),
        ("prod equal to staging is accepted", {"staging": "0.115.0", "prod": "0.115.0"}, ["0.115.0"], None),
        (
            "drill behind staging is rejected",
            {"staging": "0.136.8", "drill": "0.135.0", "prod": "0.128.0"},
            ["0.128.0", "0.135.0", "0.136.8"],
            "DRILL DIFFERS",
        ),
        (
            "drill ahead of staging is rejected",
            {"staging": "0.135.0", "drill": "0.136.8"},
            ["0.135.0", "0.136.8"],
            "DRILL DIFFERS",
        ),
        (
            "drill with no staging pin is rejected",
            {"drill": "0.136.8"},
            ["0.136.8"],
            "staging pins none",
        ),
        (
            "drill equal to staging is accepted",
            {"staging": "0.136.8", "drill": "0.136.8", "prod": "0.128.0"},
            ["0.128.0", "0.136.8"],
            None,
        ),
    ]

    failures = 0
    for title, pins, ledger_versions, expect in cases:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            envs = root / "envs"
            for env, version in pins.items():
                (envs / env).mkdir(parents=True)
                (envs / env / "gibson.yaml").write_text(
                    "spec:\n  sources:\n"
                    "    - repoURL: ghcr.io/zeroroot-ai/charts\n"
                    "      chart: gibson\n"
                    f'      targetRevision: "{version}"\n'
                )
            ledger = root / "chart-digests.yaml"
            ledger.write_text(
                "charts:\n"
                + "".join(
                    f'  "{v}":\n    digest: "sha256:{"0" * 64}"\n    signed: true\n'
                    for v in ledger_versions
                )
            )
            try:
                check(root, ledger, envs)
                got = None
            except Failure as exc:
                got = str(exc)

            if expect is None:
                ok = got is None
            else:
                ok = got is not None and expect in got
            print(f"  [{'PASS' if ok else 'FAIL'}] selftest: {title}")
            if not ok:
                print(f"         expected {expect!r}, got {got!r}")
                failures += 1

    return 1 if failures else 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true", help="prove the check still rejects")
    args = parser.parse_args()

    if args.selftest:
        sys.exit(selftest())

    try:
        lines = check(REPO, LEDGER, ENVS)
    except Failure as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
    print("\n".join(lines))
    print("OK — no env runs a chart version staging has not run first, and drill runs the staging version.")


if __name__ == "__main__":
    main()
