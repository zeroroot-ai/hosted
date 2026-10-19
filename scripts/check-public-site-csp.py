#!/usr/bin/env python3
"""check-public-site-csp.py: the docs edge sets a Content-Security-Policy
(docs-site advisory GHSA-6hc8-9whc-fxfw).

WHY THIS GUARD EXISTS
---------------------
The docs distributions used the AWS managed SecurityHeadersPolicy, which sets
no Content-Security-Policy. The container of the docs set none either. The
static-site module now builds its own response headers policy, and the CSP
comes from one local in bootstrap/eks/public-site/main.tf. A CSP that is
empty, or that allows framing or plugins, is the gap this guard keeps closed.

WHAT IT MEASURES
----------------
In bootstrap/eks/public-site/main.tf:
  1. local.docs_content_security_policy is set, and it holds
     default-src 'self', object-src 'none' and frame-ancestors 'none'.
  2. module "docs" and module "docs_staging" pass it as
     content_security_policy.
In the module: the distribution uses the module's own response headers policy,
not the managed one.

Usage: scripts/check-public-site-csp.py            # the guard
       scripts/check-public-site-csp.py --selftest # prove it can fail
Exit:  0 the docs edge sets the CSP · 1 it does not · 2 could not run
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = "bootstrap/eks/public-site"
FIXTURES = ROOT / "scripts/testdata/public-site-csp"
MANAGED_POLICY = "67f7725c-6f97-4210-82d7-5512b31e9d03"
REQUIRED = ("default-src 'self'", "object-src 'none'", "frame-ancestors 'none'")


def module_block(text: str, name: str) -> str:
    """Return the body of module "<name>", or an empty string."""
    m = re.search(r'module\s+"%s"\s*\{(.*?)\n\}' % re.escape(name), text, re.S)
    return m.group(1) if m else ""


def audit(root: Path) -> list[str]:
    failures: list[str] = []
    main = (root / SITE / "main.tf").read_text()
    module = (root / SITE / "modules/static-site/main.tf").read_text()
    m = re.search(r'docs_content_security_policy\s*=\s*"([^"]*)"', main)
    csp = m.group(1) if m else ""
    if not csp:
        failures.append("local.docs_content_security_policy is missing or empty")
    for part in REQUIRED:
        if csp and part not in csp:
            failures.append(f"the docs CSP lacks {part}")
    for name in ("docs", "docs_staging"):
        body = module_block(main, name)
        if not re.search(r"content_security_policy\s*=\s*local\.docs_content_security_policy", body):
            failures.append(f'module "{name}" does not pass the docs CSP')
    if MANAGED_POLICY in module:
        failures.append("the module still uses the managed SecurityHeadersPolicy, which sets no CSP")
    return failures


def selftest() -> int:
    cases = {"good": None, "no-csp": "missing or empty", "frames": "frame-ancestors 'none'"}
    for case, want in cases.items():
        got = audit(FIXTURES / case)
        if want is None and got:
            print(f"selftest FAIL: {case} should pass, got {got}")
            return 1
        if want is not None and not any(want in line for line in got):
            print(f"selftest FAIL: {case} should fail on {want}, got {got}")
            return 1
    print(f"selftest ok: {len(cases)} fixtures")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(__doc__)
        return 2
    failures = audit(ROOT)
    if failures:
        print("The docs edge does not set the required CSP (GHSA-6hc8-9whc-fxfw):")
        for line in failures:
            print(f"  {line}")
        return 1
    print("check-public-site-csp: the docs and docs-staging edges set the CSP")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
