#!/usr/bin/env python3
"""check-apex-zone-ownership.py — the apex zone and its mail records belong to
substrate/apex-zone and to no environment (ADR-0083, CONTEXT.md "Apex zone").

On 2026-09-01 the company's mail DNS turned out to be created by the prod
estate and held alive only by prevent_destroy. substrate/apex-zone now owns the
zeroroot.ai hosted zone, the Google Workspace MX / SPF / DKIM records and the
SES domain identities with their DKIM CNAMEs. This guard keeps them there.

What fails, keyed by content (never by line number, CLAUDE.md § 8):

  1. bootstrap/eks/gibson declares an aws_route53_record that is a mail record: type MX,
     or a name under _domainkey or _dmarc.
  2. bootstrap/eks/gibson declares an SES identity resource (aws_ses_domain_identity,
     aws_ses_domain_dkim, aws_ses_domain_mail_from, aws_sesv2_email_identity,
     aws_ses_email_identity). The identity is company property.
  3. bootstrap/eks/gibson declares any aws_route53_zone. Since deploy#1742 an
     environment creates no zone at all: the apex belongs to substrate/apex-zone
     and a sub-zone belongs to stage 0 (substrate/gibson-bootstrap), which
     delegates it from the apex. bootstrap/eks/gibson reads its zone by name.
  4. Anything in the Makefile, a workflow, or a bringup script that runs
     terraform destroy against substrate/apex-zone or substrate/gibson-bootstrap. Both
     workspaces are permanent: no teardown mode reaches them.
  5. substrate/apex-zone stops declaring the zone with prevent_destroy. That is the
     one place in this repo where the guard and the intent agree.

Usage: scripts/check-apex-zone-ownership.py            # the guard
       scripts/check-apex-zone-ownership.py --selftest # prove it can fail
Exit:  0 clean · 1 a rule is broken · 2 self-test broken or nothing scanned
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GIBSON = ROOT / "eks" / "gibson"
APEX = ROOT / "substrate" / "apex-zone"

# Files that may name the workspace next to "destroy" only in prose. A destroy
# INVOCATION is `terraform ... destroy` or `make ... destroy`-shaped text.
DESTROY_SCAN = ["Makefile", ".github/workflows", "bootstrap/eks/gibson/scripts", "scripts"]
DESTROY_EXT = {".yml", ".yaml", ".sh", ".py", ""}

SES_IDENTITY_TYPES = (
    "aws_ses_domain_identity",
    "aws_ses_domain_dkim",
    "aws_ses_domain_mail_from",
    "aws_sesv2_email_identity",
    "aws_ses_email_identity",
)

BLOCK_RE = re.compile(r'^resource\s+"(?P<type>[a-z0-9_]+)"\s+"(?P<name>[^"]+)"\s*\{', re.M)


def resource_blocks(tf: str):
    """Yield (type, name, body) for every top-level resource block.

    Body is the text up to the matching close brace, found by brace depth.
    HCL strings never contain an unbalanced brace in these files.
    """
    for m in BLOCK_RE.finditer(tf):
        depth, i = 1, m.end()
        while depth and i < len(tf):
            c = tf[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            i += 1
        yield m.group("type"), m.group("name"), tf[m.end():i - 1]


def offenders_in_tf(rel: str, tf: str) -> list[str]:
    bad: list[str] = []
    for rtype, rname, body in resource_blocks(tf):
        addr = f"{rel}: {rtype}.{rname}"
        if rtype == "aws_route53_record":
            if re.search(r'^\s*type\s*=\s*"MX"', body, re.M):
                bad.append(f"{addr} is an MX record. Mail records live in substrate/apex-zone.")
            if re.search(r"_domainkey|_dmarc", body):
                bad.append(f"{addr} is a DKIM or DMARC record. Mail records live in substrate/apex-zone.")
        elif rtype in SES_IDENTITY_TYPES:
            bad.append(f"{addr} declares an SES identity. The identity lives in substrate/apex-zone.")
        elif rtype == "aws_route53_zone":
            bad.append(f"{addr} declares a hosted zone. An environment creates no zone: the apex is substrate/apex-zone's, a sub-zone is stage 0's (substrate/gibson-bootstrap).")
    return bad


PERMANENT_WORKSPACES = ("apex-zone", "gibson-bootstrap")


def destroyed_permanent_workspace(line: str) -> str | None:
    """The permanent workspace a terraform destroy on this line names, in any argument order."""
    if re.search(r"\bterraform\b", line) is None or re.search(r"\bdestroy\b", line) is None:
        return None
    for ws in PERMANENT_WORKSPACES:
        if ws in line:
            return ws
    return None


def offenders_in_text(rel: str, text: str) -> list[str]:
    bad: list[str] = []
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        ws = destroyed_permanent_workspace(line)
        if ws:
            bad.append(f"{rel}:{n} runs terraform destroy against eks/{ws}. The workspace is permanent.")
    return bad


def apex_workspace_offenders(files: dict[str, str]) -> list[str]:
    """files: relative path -> content of every .tf in substrate/apex-zone."""
    if not files:
        return ["substrate/apex-zone has no .tf files. The apex zone has no owner."]
    zones = [(rel, body) for rel, tf in files.items() for t, _, body in resource_blocks(tf) if t == "aws_route53_zone"]
    if len(zones) != 1:
        return [f"substrate/apex-zone must declare exactly one aws_route53_zone, found {len(zones)}."]
    rel, body = zones[0]
    if not re.search(r"^\s*prevent_destroy\s*=\s*true", body, re.M):
        return [f"{rel}: the apex zone must carry prevent_destroy = true. This is the one permanent workspace."]
    return []


def scan() -> tuple[list[str], int]:
    bad: list[str] = []
    seen = 0
    for p in sorted(GIBSON.rglob("*.tf")):
        if "/tests/" in p.as_posix() or "/.terraform/" in p.as_posix():
            continue
        seen += 1
        bad += offenders_in_tf(p.relative_to(ROOT).as_posix(), p.read_text(encoding="utf-8"))
    for d in DESTROY_SCAN:
        base = ROOT / d
        paths = [base] if base.is_file() else sorted(base.rglob("*")) if base.is_dir() else []
        for p in paths:
            if p.is_file() and p.suffix in DESTROY_EXT and p.name != pathlib.Path(__file__).name:
                seen += 1
                bad += offenders_in_text(p.relative_to(ROOT).as_posix(), p.read_text(encoding="utf-8", errors="replace"))
    apex_files = {p.relative_to(ROOT).as_posix(): p.read_text(encoding="utf-8") for p in sorted(APEX.glob("*.tf"))}
    bad += apex_workspace_offenders(apex_files)
    return bad, seen


FIXTURES: list[tuple[str, str, str]] = [
    # (what it is, snippet, the substring the guard must name)
    ("an apex MX record",
     'resource "aws_route53_record" "mx" {\n  zone_id = "Z1"\n  name    = "zeroroot.ai"\n  type    = "MX"\n  ttl     = 3600\n  records = ["1 smtp.google.com."]\n}\n',
     "is an MX record"),
    ("a DKIM record",
     'resource "aws_route53_record" "dkim" {\n  zone_id = "Z1"\n  name    = "google._domainkey.zeroroot.ai"\n  type    = "TXT"\n  ttl     = 3600\n  records = ["v=DKIM1"]\n}\n',
     "is a DKIM or DMARC record"),
    ("a DMARC record",
     'resource "aws_route53_record" "dmarc" {\n  zone_id = "Z1"\n  name    = "_dmarc.zeroroot.ai"\n  type    = "TXT"\n  ttl     = 600\n  records = ["v=DMARC1; p=quarantine"]\n}\n',
     "is a DKIM or DMARC record"),
    ("an SES domain identity",
     'resource "aws_ses_domain_identity" "this" {\n  domain = var.domain\n}\n',
     "declares an SES identity"),
    ("an SESv2 email identity",
     'resource "aws_sesv2_email_identity" "this" {\n  email_identity = var.domain\n}\n',
     "declares an SES identity"),
    ("an unconditional hosted zone",
     'resource "aws_route53_zone" "this" {\n  name = var.domain\n  lifecycle {\n    prevent_destroy = true\n  }\n}\n',
     "declares a hosted zone"),
    ("a conditional hosted zone (the pre-#1742 sub-zone shape)",
     'resource "aws_route53_zone" "this" {\n  count = local.is_subzone ? 1 : 0\n  name  = var.domain\n}\n',
     "declares a hosted zone"),
]

# The shape bootstrap/eks/gibson has since deploy#1742: records into a zone it was
# given, never a zone.
CLEAN = (
    'resource "aws_route53_record" "validation" {\n  for_each = toset([var.domain])\n  zone_id  = var.zone.zone_id\n'
    '  name     = "_acme.${each.value}"\n  type     = "CNAME"\n  ttl      = 60\n  records  = ["x"]\n}\n'
)


def selftest() -> int:
    for what, snippet, expect in FIXTURES:
        bad = offenders_in_tf("fixture.tf", snippet)
        if not any(expect in b for b in bad):
            print(f"GUARD BROKEN: {what} was accepted (wanted '{expect}', got {bad})", file=sys.stderr)
            return 2
    if offenders_in_tf("clean.tf", CLEAN):
        print(f"GUARD BROKEN: a clean route53 module was rejected: {offenders_in_tf('clean.tf', CLEAN)}", file=sys.stderr)
        return 2
    for ws in PERMANENT_WORKSPACES:
        destroy_line = f"\t@terraform -chdir=eks/{ws} destroy -auto-approve\n"
        if not offenders_in_text("Makefile", destroy_line):
            print(f"GUARD BROKEN: a Makefile destroy of eks/{ws} was accepted", file=sys.stderr)
            return 2
    if offenders_in_text("Makefile", "# never add a destroy target for substrate/apex-zone\n\t@terraform -chdir=substrate/apex-zone plan\n"):
        print("GUARD BROKEN: a comment and a plan were flagged as a destroy", file=sys.stderr)
        return 2
    if not apex_workspace_offenders({}):
        print("GUARD BROKEN: an empty substrate/apex-zone was accepted", file=sys.stderr)
        return 2
    if not apex_workspace_offenders({"main.tf": 'resource "aws_route53_zone" "apex" {\n  name = "zeroroot.ai"\n}\n'}):
        print("GUARD BROKEN: an apex zone without prevent_destroy was accepted", file=sys.stderr)
        return 2
    if apex_workspace_offenders({"main.tf": 'resource "aws_route53_zone" "apex" {\n  name = "zeroroot.ai"\n  lifecycle {\n    prevent_destroy = true\n  }\n}\n'}):
        print("GUARD BROKEN: the correct apex workspace shape was rejected", file=sys.stderr)
        return 2
    print(f"✅ self-test: {len(FIXTURES)} mail/zone fixtures rejected, the clean module accepted, the destroy rule fires for {', '.join(PERMANENT_WORKSPACES)}, the prevent_destroy rule fires")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    bad, seen = scan()
    if seen < 10:
        print(f"GUARD BROKEN: scanned only {seen} files under bootstrap/eks/gibson and the destroy surfaces — the tree moved", file=sys.stderr)
        return 2
    if bad:
        print("❌ the apex zone and its mail records belong to substrate/apex-zone (ADR-0083):")
        for b in bad:
            print("   ", b)
        return 1
    print(f"✅ {seen} files scanned: bootstrap/eks/gibson declares no hosted zone and no mail record, substrate/apex-zone owns the apex, nothing destroys a permanent workspace")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
