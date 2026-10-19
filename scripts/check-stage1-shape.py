#!/usr/bin/env python3
"""check-stage1-shape.py — stage 1 stays thin (ADR-0083, deploy#1744).

ADR-0083 § "Where the cluster ends": bootstrap/eks/gibson provides the cluster and its
rows — storage, a LoadBalancer implementation, node autoscaling,
metrics-server, Argo CD — plus the VPC, the node
groups, the cluster OIDC provider and three controller IRSA roles. The AWS
control plane it used to carry (Aurora, Secrets Manager, the KMS keys, WAFv2,
GuardDuty, SES, ACM, the workload IRSA roles) was deleted, not gated off.
This guard keeps it deleted, in two directions:

  Denylist   no *.tf under bootstrap/eks/gibson declares a resource of a deleted
             class. Matched on the resource TYPE of every `resource` block,
             so a comment naming a type does not trip it, and a new resource
             of a banned class cannot hide behind a novel name.

  Ceiling    bootstrap/eks/gibson declares at most 50 resource blocks. The thin root
             declares 44; the ceiling leaves room for a row to grow, not for
             a control plane to move back in. Count keyed by content
             (`resource` blocks), never by line number.

Two modes, one rule set.

  Static (the merge gate, `make check-stage1-shape`): scan every *.tf under
  bootstrap/eks/gibson (provider caches excluded).

  Plan (`--plan plan.json`): the denylist over `terraform show -json` of the
  bootstrap/eks/gibson plan. This is what catches a banned class smuggled in by a
  registry module — e.g. the EKS module minting its own aws_kms_key when
  `create_kms_key` flips back on — which no static scan of our tree sees.

Usage: scripts/check-stage1-shape.py                   # static, exit 1 on a hit
       scripts/check-stage1-shape.py --plan plan.json  # exit 1 on a banned type
       scripts/check-stage1-shape.py --selftest        # prove every direction fails
Exit:  0 clean · 1 a rule is broken · 2 self-test broken or nothing scanned
"""
from __future__ import annotations

import json
import pathlib
import re
import shutil
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
STAGE1 = pathlib.Path("bootstrap/eks/gibson")
SKIP_DIRS = {".terraform", ".git", "__pycache__"}

# EVERY stage 1 root in this repo, each with its own ceiling and its own
# reach floor. A second root arrived with hosted#159 (staging on one EC2
# instance running k3s), and a root that is not listed here is a root no
# guard reads. `discover_stage1_roots` below fails when the tree holds one
# this list does not name, so the hole cannot open again quietly.
STAGE1_ROOTS: list[tuple[pathlib.Path, int, int]] = [
    (pathlib.Path("bootstrap/eks/gibson"), 50, 20),
    (pathlib.Path("bootstrap/ec2/gibson"), 40, 5),
]

# The thin root declares 44 resource blocks today. 50 leaves room for a row
# to grow; a control plane is dozens more and must arrive as a deliberate
# ceiling bump in the same PR that argues for it.
CEILING = 50

# One entry per deleted class (the issue's denylist, plus the sibling types
# each class arrives with — Aurora is aws_rds_* AND aws_db_*, ACM is
# certificate + validation, KMS is key + alias + grant + replicas).
DENY: list[tuple[str, re.Pattern[str]]] = [
    ("Aurora / RDS", re.compile(r"^aws_(rds|db)_")),
    ("Secrets Manager", re.compile(r"^aws_secretsmanager_")),
    ("KMS", re.compile(r"^aws_kms_(key|alias|grant|external_key|replica_key)")),
    ("WAFv2", re.compile(r"^aws_wafv2_")),
    ("GuardDuty", re.compile(r"^aws_guardduty_")),
    ("SES", re.compile(r"^aws_ses(v2)?_")),
    ("ACM", re.compile(r"^aws_acm_")),
    ("ElastiCache", re.compile(r"^aws_elasticache_")),
    ("EFS", re.compile(r"^aws_efs_")),
    ("S3 bucket", re.compile(r"^aws_s3_bucket$")),
]

RESOURCE_RE = re.compile(r'^\s*resource\s+"([a-z0-9_]+)"\s+"[^"]+"\s*{')
# The static scan must see the root and the modules, or it is scanning the
# wrong tree and must not report clean.
FLOOR_TF_FILES = 20


def deny_hit(rtype: str) -> str | None:
    for name, rx in DENY:
        if rx.search(rtype):
            return name
    return None


def files_under(base: pathlib.Path):
    for p in sorted(base.rglob("*.tf")):
        if p.is_file() and not (set(p.parts) & SKIP_DIRS):
            yield p


def discover_stage1_roots(root: pathlib.Path) -> list[pathlib.Path]:
    """Every directory under bootstrap/ that is a Terraform root with per-env
    var files. That shape is what makes a directory a stage 1 root, so it is
    what the guard looks for rather than a name."""
    found = []
    base = root / "bootstrap"
    if not base.is_dir():
        return found
    for backend in sorted(base.rglob("backend.tf")):
        if set(backend.parts) & SKIP_DIRS:
            continue
        d = backend.parent
        if (d / "envs").is_dir() and any((d / "envs").glob("*.tfvars")):
            found.append(d.relative_to(root))
    return found


def unlisted_roots(root: pathlib.Path) -> list[str]:
    listed = {d for d, _, _ in STAGE1_ROOTS}
    return [
        f"GUARD BROKEN: {d.as_posix()} is a stage 1 root that STAGE1_ROOTS does not name, so no guard reads it (ADR-0083)"
        for d in discover_stage1_roots(root)
        if d not in listed
    ]


def scan_one(root: pathlib.Path, stage1: pathlib.Path, ceiling: int, floor: int) -> list[str]:
    bad: list[str] = []
    count = 0
    seen = 0
    for p in files_under(root / stage1):
        seen += 1
        rel = p.relative_to(root).as_posix()
        for n, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            m = RESOURCE_RE.match(line)
            if not m:
                continue
            count += 1
            hit = deny_hit(m.group(1))
            if hit:
                bad.append(f"{rel}:{n}: {hit}: {line.strip()[:100]}")
    if seen < floor:
        bad.append(f"GUARD BROKEN: scanned only {seen} .tf files under {stage1.as_posix()} (floor {floor}) — the tree moved")
    if count > ceiling:
        bad.append(f"{stage1.as_posix()} declares {count} resource blocks — over the stage 1 ceiling of {ceiling} (ADR-0083)")
    return bad


def scan(root: pathlib.Path, ceiling: int = CEILING, floor: int = FLOOR_TF_FILES) -> list[str]:
    """The single-root scan the selftest drives against a fixture tree."""
    return scan_one(root, STAGE1, ceiling, floor)


def scan_all(root: pathlib.Path) -> list[str]:
    """Every listed root, plus the check that the list names them all."""
    bad = unlisted_roots(root)
    for stage1, ceiling, floor in STAGE1_ROOTS:
        if not (root / stage1).is_dir():
            bad.append(f"GUARD BROKEN: {stage1.as_posix()} is listed in STAGE1_ROOTS and does not exist")
            continue
        bad.extend(scan_one(root, stage1, ceiling, floor))
    return bad


def managed_types(plan: dict):
    for c in plan.get("resource_changes", []):
        if c.get("mode", "managed") != "managed":
            continue
        actions = set(c.get("change", {}).get("actions", []))
        if actions and actions != {"no-op"} and actions != {"delete"}:
            yield c.get("type", ""), c.get("address", "")


def plan_offenders(path: pathlib.Path) -> list[str]:
    if not path.is_file():
        return [f"GUARD BROKEN: {path} does not exist — the plan never ran"]
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return [f"GUARD BROKEN: {path} is not JSON ({exc})"]
    if "resource_changes" not in plan:
        return [f"GUARD BROKEN: {path} has no resource_changes key (format_version={plan.get('format_version', 'absent')})"]
    bad: list[str] = []
    for rtype, addr in managed_types(plan):
        hit = deny_hit(rtype)
        if hit:
            bad.append(f"{addr}: {hit}: the plan creates a {rtype}. That class left stage 1 (ADR-0083, deploy#1744).")
    return bad


# ---------------------------------------------------------------------------
# self-test: a clean copy of real stage 1 files passes; one injected resource
# per denylist class fails; a tree over the ceiling fails; the plan mode
# rejects each class and accepts the clean shape.
# ---------------------------------------------------------------------------

INJECT: list[tuple[str, str]] = [
    ("Aurora / RDS", 'resource "aws_rds_cluster" "x" {\n  cluster_identifier = "x"\n}\n'),
    ("Aurora / RDS", 'resource "aws_db_subnet_group" "x" {\n  subnet_ids = []\n}\n'),
    ("Secrets Manager", 'resource "aws_secretsmanager_secret" "x" {\n  name = "x"\n}\n'),
    ("KMS", 'resource "aws_kms_key" "x" {\n}\n'),
    ("WAFv2", 'resource "aws_wafv2_web_acl" "x" {\n  name = "x"\n}\n'),
    ("GuardDuty", 'resource "aws_guardduty_detector" "x" {\n}\n'),
    ("SES", 'resource "aws_ses_domain_identity" "x" {\n  domain = "x"\n}\n'),
    ("ACM", 'resource "aws_acm_certificate" "x" {\n  domain_name = "x"\n}\n'),
    ("ElastiCache", 'resource "aws_elasticache_cluster" "x" {\n  cluster_id = "x"\n}\n'),
    ("EFS", 'resource "aws_efs_file_system" "x" {\n}\n'),
    ("S3 bucket", 'resource "aws_s3_bucket" "x" {\n  bucket = "x"\n}\n'),
]

PLAN_CLEAN = {"format_version": "1.2", "resource_changes": [
    {"address": "module.network.aws_vpc.this", "mode": "managed", "type": "aws_vpc", "change": {"actions": ["create"]}},
    {"address": "data.aws_partition.current", "mode": "data", "type": "aws_partition", "change": {"actions": ["read"]}},
]}


def fixture_tree(tmp: pathlib.Path) -> None:
    """A small stage 1: the network module and the root files, verbatim."""
    for rel in ["modules/network", "main.tf", "karpenter.tf"]:
        src = ROOT / STAGE1 / rel
        dst = tmp / STAGE1 / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, dst, ignore=shutil.ignore_patterns(".terraform*"))
        else:
            shutil.copy(src, dst)


def selftest() -> int:
    def broken(msg: str) -> int:
        print(f"GUARD BROKEN: {msg}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as d:
        tmp = pathlib.Path(d)
        fixture_tree(tmp)
        bad = scan(tmp, floor=1)
        if bad:
            return broken(f"a clean copy of stage 1 was rejected: {bad}")
        if not scan(tmp, floor=999):
            return broken("a scan under the reach floor reported clean")
        target = tmp / STAGE1 / "injected.tf"
        for name, snippet in INJECT:
            target.write_text(snippet)
            bad = scan(tmp, floor=1)
            if not any(f": {name}:" in b for b in bad):
                return broken(f"an injected {name} resource was accepted (got {bad})")
        target.unlink()
        # A type named only in a comment must NOT trip the denylist.
        target.write_text('# history: the aws_kms_key and aws_rds_cluster left in deploy#1744\n')
        if scan(tmp, floor=1):
            return broken("a comment naming a banned type was rejected — the guard must key on resource blocks")
        # The ceiling.
        target.write_text("".join(f'resource "aws_sqs_queue" "q{i}" {{\n  name = "q{i}"\n}}\n' for i in range(CEILING + 1)))
        bad = scan(tmp, floor=1)
        if not any("over the stage 1 ceiling" in b for b in bad):
            return broken(f"a tree over the ceiling was accepted (got {bad})")
        target.unlink()
        # .terraform/ is provider cache, not our code.
        cache = tmp / STAGE1 / ".terraform/modules/x/main.tf"
        cache.parent.mkdir(parents=True)
        cache.write_text('resource "aws_kms_key" "hidden" {\n}\n')
        if scan(tmp, floor=1):
            return broken("a provider cache file was scanned")
        # A stage 1 root the list does not name must be REFUSED. This is the
        # failing fixture for the multi-root behaviour (hosted#159): the hole
        # it closes is a second root that silently gets no guard at all.
        new_root = tmp / "bootstrap/unlisted/gibson"
        (new_root / "envs").mkdir(parents=True)
        (new_root / "backend.tf").write_text('terraform {\n  backend "s3" {}\n}\n')
        (new_root / "envs/staging.tfvars").write_text('environment = "staging"\n')
        if not any("STAGE1_ROOTS does not name" in b for b in unlisted_roots(tmp)):
            return broken("a stage 1 root outside STAGE1_ROOTS was accepted")
        # A directory with a backend and NO per-env var files is not a stage 1
        # root, so it must not be demanded of the list.
        other = tmp / "bootstrap/terraform/eks"
        other.mkdir(parents=True)
        (other / "backend.tf").write_text('terraform {\n  backend "s3" {}\n}\n')
        found = [d.as_posix() for d in discover_stage1_roots(tmp)]
        if "bootstrap/terraform/eks" in found:
            return broken(f"a root with no envs/*.tfvars was treated as a stage 1 root ({found})")

        # plan mode
        f = tmp / "plan.json"
        f.write_text(json.dumps(PLAN_CLEAN))
        if plan_offenders(f):
            return broken(f"a clean plan was rejected: {plan_offenders(f)}")
        for name, rx in DENY:
            sample = {"Aurora / RDS": "aws_rds_cluster", "Secrets Manager": "aws_secretsmanager_secret",
                      "KMS": "aws_kms_key", "WAFv2": "aws_wafv2_web_acl", "GuardDuty": "aws_guardduty_detector",
                      "SES": "aws_ses_domain_identity", "ACM": "aws_acm_certificate",
                      "ElastiCache": "aws_elasticache_cluster", "EFS": "aws_efs_file_system",
                      "S3 bucket": "aws_s3_bucket"}[name]
            plan = {"format_version": "1.2", "resource_changes": [
                {"address": f"module.x.{sample}.this", "mode": "managed", "type": sample, "change": {"actions": ["create"]}}]}
            f.write_text(json.dumps(plan))
            bad = plan_offenders(f)
            if not any(f": {name}:" in b for b in bad):
                return broken(f"a plan creating a {sample} was accepted (got {bad})")
        # A data source of a banned type is a read, never a declaration.
        f.write_text(json.dumps({"format_version": "1.2", "resource_changes": [
            {"address": "data.aws_kms_key.x", "mode": "data", "type": "aws_kms_key", "change": {"actions": ["read"]}}]}))
        if plan_offenders(f):
            return broken("a plan that only READS a banned type was rejected")
        f.write_text(json.dumps({"format_version": "1.2"}))
        if not any("GUARD BROKEN" in b for b in plan_offenders(f)):
            return broken("a plan without resource_changes was accepted")
        if not any("GUARD BROKEN" in b for b in plan_offenders(tmp / "absent.json")):
            return broken("a missing plan file was accepted")
    print(f"✅ self-test: the clean stage 1 copy passes, {len(INJECT)} injected classes + the ceiling are rejected, "
          "a comment and a data source pass, the plan mode rejects every class")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) == 3 and argv[1] == "--plan":
        bad = plan_offenders(pathlib.Path(argv[2]))
        if bad:
            print("❌ the bootstrap/eks/gibson plan creates a resource of a deleted class (ADR-0083, deploy#1744):")
            for b in bad:
                print("   ", b)
            return 2 if all(b.startswith("GUARD BROKEN") for b in bad) else 1
        print(f"✅ {argv[2]}: no banned resource type in the plan")
        return 0
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    bad = scan_all(ROOT)
    if any(b.startswith("GUARD BROKEN") for b in bad):
        for b in bad:
            print(b, file=sys.stderr)
        return 2
    if bad:
        print(f"❌ {len(bad)} stage 1 shape violation(s) (ADR-0083, deploy#1744):")
        for b in bad:
            print("   ", b)
        return 1
    names = ", ".join(d.as_posix() for d, _, _ in STAGE1_ROOTS)
    print(f"✅ {names}: no banned resource class, each under its block ceiling")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
