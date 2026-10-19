#!/usr/bin/env python3
"""check-marketing-host.py — every marketing origin in the Argo tree is the
ONE off-cluster marketing site.

WHY THIS GUARD EXISTS
---------------------
On 2026-09-14 a signup on staging that reached the plan-selection step
redirected to `https://www.staging.zeroroot.ai/pricing?missing_plan=true`
and died there. No such host exists. The staging zone holds api, app and
docs and nothing else, because ADR-0077 moved the marketing site to S3 +
CloudFront in a singleton Terraform root with no Environment: there is one
marketing site, it is production-only, and no chart deploys it in any
environment.

The values never followed. `dashboard.wwwUrl` still carried its pre-0077
value in three places, and the comments around them still described a `www`
Envoy vhost backed by the `www-svc` SaaS overlay that ADR-0077 deleted:

  envs/staging             https://www.staging.zeroroot.ai  does not resolve
  envs/dev (deleted in hosted#406)
                           https://www.zeroroot.ai:30443    the kind NodePort,
                                                            on a distribution
                                                            that answers on 443

Nothing measured the key, so a dead marketing origin reached a live
environment and stayed there. The dashboard cannot catch this itself: it
fail-closes on wwwUrl being EMPTY (gitops/scripts/check-profile-coherence.sh
proves that), which is why a stale non-empty value looked healthy.

WHAT IT MEASURES
----------------
Every `wwwUrl` key in every YAML document under gitops/, at any depth,
carries MARKETING_ORIGIN or is empty. One literal comparison rejects both
failure shapes: a per-environment `www.<env>.` host, and a port suffix on a
distribution that has none. The key is found by name rather than by a fixed
path, because the overlays nest it under `gibson-workloads.dashboard` and
the profile values files put it under a top-level `dashboard`.

Helm template directories are skipped: they hold Go templates, not YAML, so
a parser reads them as garbage. Anywhere else a file that will not parse is
a failure, not a file to step over.

Usage: scripts/check-marketing-host.py            # the guard
       scripts/check-marketing-host.py --selftest # prove it can fail
Exit:  0 every origin agrees · 1 one drifted · 2 could not run
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterator

import yaml

ROOT = Path(__file__).resolve().parent.parent
GITOPS = ROOT / "gitops"
FIXTURE = ROOT / "scripts/testdata/marketing-host/per-env-www.values.yaml"

# ADR-0077: one site, production-only, off-cluster. There is no second one
# to point at, so this is a literal and not a pattern.
MARKETING_ORIGIN = "https://www.zeroroot.ai"


def find_www_urls(node: object, path: str = "") -> Iterator[tuple[str, object]]:
    """Yield (yaml path, value) for every wwwUrl key at any depth."""
    if isinstance(node, dict):
        for key, value in node.items():
            here = f"{path}.{key}" if path else str(key)
            if key == "wwwUrl":
                yield here, value
            else:
                yield from find_www_urls(value, here)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from find_www_urls(value, f"{path}[{index}]")


def audit(files: list[Path]) -> list[str]:
    """Report one line per marketing origin that is not the one site."""
    failures: list[str] = []
    for values in files:
        try:
            docs = list(yaml.safe_load_all(values.read_text()))
        except yaml.YAMLError as err:
            failures.append(f"{values.relative_to(ROOT)}: unreadable YAML: {err}")
            continue
        for doc in docs:
            for where, url in find_www_urls(doc):
                # Self-hosted leaves it unset on purpose; billing is off there.
                if url in (None, ""):
                    continue
                if url != MARKETING_ORIGIN:
                    failures.append(
                        f"{values.relative_to(ROOT)}: {where}={url!r}, expected "
                        f"{MARKETING_ORIGIN!r} (ADR-0077: one off-cluster site)"
                    )
    return failures


def selftest() -> int:
    """Prove the guard fails on the exact value that reached staging."""
    if not FIXTURE.is_file():
        print(f"SELFTEST BROKEN: missing fixture {FIXTURE}", file=sys.stderr)
        return 2
    if not audit([FIXTURE]):
        print("SELFTEST BROKEN: a per-env www host was accepted", file=sys.stderr)
        return 2
    print("OK: check-marketing-host self-test: a per-env www host is rejected")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(f"usage: {argv[0]} [--selftest]", file=sys.stderr)
        return 2
    if not GITOPS.is_dir():
        print(f"could not run: no {GITOPS}", file=sys.stderr)
        return 2
    files = sorted(
        p
        for p in GITOPS.rglob("*.yaml")
        if p.is_file() and "templates" not in p.relative_to(GITOPS).parts
    )
    if not files:
        print(f"could not run: no YAML under {GITOPS}", file=sys.stderr)
        return 2
    failures = audit(files)
    for line in failures:
        print(f"FAIL: {line}", file=sys.stderr)
    if failures:
        return 1
    print(f"OK: every marketing origin under gitops/ is {MARKETING_ORIGIN}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
