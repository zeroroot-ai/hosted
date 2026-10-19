#!/usr/bin/env python3
"""check-kind-terraform-no-seed.py — the kind Terraform is not a seed producer
(ADR-0083, deploy#1732).

The openbao-auto-init sidecar is the ONE seed path: it writes every key the
chart's ExternalSecrets read into the platform's OpenBao and revokes the
initial root token. Before deploy#1732, bootstrap/kind/gibson/credentials.tf generated
~26 credentials with random_password and wrote one Kubernetes Secret per
credential. That producer is deleted. This guard keeps it deleted.

What fails, keyed by content (never by line number, CLAUDE.md § 8):

  1. kind/**.tf declares a credential generator: random_password, random_id,
     random_bytes, random_string, random_uuid or tls_private_key.
  2. kind/**.tf declares a kubernetes_secret_v1 (or kubernetes_secret) whose
     resource address is not on the allowlist below.
  3. An allowlisted address no longer exists. A stale allowlist entry is a
     defect in the guard, so the guard fails on it instead of rotting.

The allowlist is EMPTY since deploy#1737: `make recreate ENV=kind` writes the
bringup keyring and Velero's two credentials through
scripts/keyring-to-cluster.sh, and the ArgoCD repository Secrets left with
kind-up (stage 2 on kind syncs from the durable bucket's charts/ prefix with
an anonymous GET, so Argo holds no credential). Terraform writes no Secret at
all. The set stays here so a future producer must argue its case in review.

Usage: scripts/check-kind-terraform-no-seed.py            # the guard
       scripts/check-kind-terraform-no-seed.py --selftest # prove it can fail
Exit:  0 clean · 1 a rule is broken · 2 self-test broken or nothing scanned
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
KIND = ROOT / "bootstrap" / "kind"

GENERATOR_TYPES = (
    "random_password",
    "random_id",
    "random_bytes",
    "random_string",
    "random_uuid",
    "tls_private_key",
)

SECRET_TYPES = ("kubernetes_secret_v1", "kubernetes_secret")

ALLOWED_SECRET_ADDRESSES: set[str] = set()

BLOCK_RE = re.compile(r'^resource\s+"(?P<type>[a-z0-9_]+)"\s+"(?P<name>[^"]+)"\s*\{', re.M)


def scan(files: list[tuple[str, str]]) -> tuple[list[str], set[str]]:
    """Return (offences, secret addresses seen) over (relpath, hcl) pairs."""
    bad: list[str] = []
    seen: set[str] = set()
    for rel, hcl in files:
        for m in BLOCK_RE.finditer(hcl):
            rtype, rname = m.group("type"), m.group("name")
            addr = f"{rtype}.{rname}"
            if rtype in GENERATOR_TYPES:
                bad.append(
                    f"{rel}: {addr} generates a credential. The openbao-auto-init "
                    f"sidecar is the one seed path (deploy#1732); nothing in kind/ "
                    f"generates secret material."
                )
            if rtype in SECRET_TYPES:
                seen.add(addr)
                if addr not in ALLOWED_SECRET_ADDRESSES:
                    bad.append(
                        f"{rel}: {addr} writes a Kubernetes Secret. Nothing in kind/ "
                        f"may (deploy#1737): the bringup keyring reaches the cluster "
                        f"through scripts/keyring-to-cluster.sh, run by make recreate."
                    )
    return bad, seen


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        fixture = [(
            "bootstrap/kind/gibson/fixture.tf",
            'resource "random_password" "gibson_master_key" {\n  length = 32\n}\n'
            'resource "kubernetes_secret_v1" "gibson_master_key" {\n  metadata {}\n}\n',
        )]
        bad, _ = scan(fixture)
        wants = ["random_password.gibson_master_key", "kubernetes_secret_v1.gibson_master_key"]
        if len(bad) != 2 or not all(any(w in b for b in bad) for w in wants):
            print(f"GUARD BROKEN: expected the generator and the Secret to be named, got {bad}", file=sys.stderr)
            return 2
        print("✅ self-test: the guard fails on a credential generator and on an unlisted Secret")
        return 0

    files = [
        (str(p.relative_to(ROOT)), p.read_text())
        for p in sorted(KIND.rglob("*.tf"))
    ]
    if not files:
        print("nothing scanned: no .tf files under kind/ — an empty scan would pass vacuously", file=sys.stderr)
        return 2
    bad, seen = scan(files)
    for missing in sorted(ALLOWED_SECRET_ADDRESSES - seen):
        bad.append(
            f"allowlist entry {missing} matches no resource in kind/. "
            f"Remove the entry: a stale allowlist is a defect in the guard."
        )
    if bad:
        print("❌ the kind Terraform is not a seed producer (ADR-0083, deploy#1732):")
        for b in bad:
            print(f"    {b}")
        return 1
    print(f"✅ kind/: no credential generator and no Kubernetes Secret renders (deploy#1737)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
