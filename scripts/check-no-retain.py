#!/usr/bin/env python3
"""check-no-retain.py — stage 1 carries zero retain constructs (ADR-0083, deploy#1743).

Both teardown modes destroy stage 1 whole (CONTEXT.md "Wipe teardown",
"Preserve teardown"). Nothing in bootstrap/eks/gibson is carved out of the destroy, and
nothing is re-attached at the next apply. What must outlive a cluster lives in
stage 0 (substrate/gibson-bootstrap) or in the permanent apex workspace. The old
retain-and-reimport model that ADR-0083 rejected was deleted in deploy#1743.
This guard keeps it deleted.

Two modes, one rule set.

  Static (the merge gate, `make check-no-retain`): every file under bootstrap/eks/gibson
  is free of each construct below, and the Makefile and the workflows have no
  `eks-reset` target. Matched by content on every line, comments included,
  never by line number (CLAUDE.md § 8). A comment that names one of these is a
  comment that describes a path that no longer exists.

    prevent_destroy          a lifecycle guard that makes destroy abort
    state rm                 detaching a resource from state so destroy skips it
    teardown:keep            the tag allowlist the post-destroy verify subtracted
    eks-import-persistent    the script that re-attached survivors at apply
    EBS capture              .destroy-preserve.env / EBS_VOLUME_ID / "Recording
                             stateful EBS", the Neo4j volume-ID record
    eks-reset                the retain model in one line: "RDS/S3 data preserved"

  Plan (the exit test, `--plan plan.json`): `terraform show -json` of the
  bootstrap/eks/gibson plan declares no managed `aws_s3_bucket`. The durable bucket is
  stage 0's. A data source that reads a bucket is allowed.

The one prevent_destroy this repo keeps is on the apex zone in substrate/apex-zone,
outside this scan; scripts/check-apex-zone-ownership.py requires it.

The permanent root bootstrap/eks/public-site is read for ONE rule, the
teardown:keep tag (hosted#411). The root is permanent, so the other rules do
not apply to it: its state bucket keeps prevent_destroy on purpose. But no tag
exempts a resource from the post-destroy check (ADR-0070). That check exempts
the public site by service and by name. A tag there says that it does
something, and it does nothing.

Usage: scripts/check-no-retain.py                   # static, exit 1 on a hit
       scripts/check-no-retain.py --plan plan.json  # exit 1 on a bucket
       scripts/check-no-retain.py --selftest        # prove both modes can fail
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
# Every stage 1 root. A retain construct in a second root is the same defect
# as one in the first, so the scan reads them all (hosted#159). The list is
# kept beside the one in check-stage1-shape.py, which also refuses a root
# neither list names.
STAGE1_ROOTS = [pathlib.Path("bootstrap/eks/gibson"), pathlib.Path("bootstrap/ec2/gibson")]
# Permanent roots, read for the tag rule only (hosted#411).
TAG_ONLY_ROOTS = [pathlib.Path("bootstrap/eks/public-site")]
RESET_SCAN = [pathlib.Path("Makefile"), pathlib.Path(".github/workflows")]
SKIP_DIRS = {".terraform", ".git", "__pycache__"}
# The thin bootstrap/eks/gibson holds ~58 files (deploy#1744). A scan that sees fewer
# than this many is a scan of the wrong tree, and must not report clean.
FLOOR = 40

RULES: list[tuple[str, re.Pattern[str]]] = [
    ("prevent_destroy", re.compile(r"prevent_destroy")),
    ("state rm", re.compile(r"\bstate\s+rm\b")),
    ("teardown:keep", re.compile(r"teardown:keep")),
    ("eks-import-persistent", re.compile(r"eks-import-persistent")),
    ("EBS capture", re.compile(r"destroy-preserve\.env|EBS_VOLUME_ID|Recording stateful EBS")),
]
RESET_RULE: tuple[str, re.Pattern[str]] = ("eks-reset", re.compile(r"\beks-reset\b"))
TAG_RULE: tuple[str, re.Pattern[str]] = ("teardown:keep", re.compile(r"teardown:keep"))


def files_under(base: pathlib.Path):
    if base.is_file():
        yield base
        return
    if not base.is_dir():
        return
    for p in sorted(base.rglob("*")):
        if p.is_file() and not (set(p.parts) & SKIP_DIRS):
            yield p


def offenders_in_text(rel: str, text: str, rules: list[tuple[str, re.Pattern[str]]]) -> list[str]:
    bad: list[str] = []
    for n, line in enumerate(text.splitlines(), 1):
        for name, rx in rules:
            if rx.search(line):
                bad.append(f"{rel}:{n}: {name}: {line.strip()[:100]}")
    return bad


def scan(root: pathlib.Path, floor: int = FLOOR) -> tuple[list[str], int]:
    bad: list[str] = []
    seen = 0
    for stage1 in STAGE1_ROOTS:
        if not (root / stage1).is_dir():
            continue
        for p in files_under(root / stage1):
            seen += 1
            bad += offenders_in_text(p.relative_to(root).as_posix(), p.read_text(encoding="utf-8", errors="replace"), RULES)
    for tag_root in TAG_ONLY_ROOTS:
        for p in files_under(root / tag_root):
            seen += 1
            bad += offenders_in_text(p.relative_to(root).as_posix(), p.read_text(encoding="utf-8", errors="replace"), [TAG_RULE])
    for d in RESET_SCAN:
        for p in files_under(root / d):
            seen += 1
            bad += offenders_in_text(p.relative_to(root).as_posix(), p.read_text(encoding="utf-8", errors="replace"), [RESET_RULE])
    if seen < floor:
        bad.append(f"GUARD BROKEN: scanned only {seen} files (floor {floor}) — the tree moved")
    return bad, seen


def managed_resources(module: dict):
    for r in module.get("resources", []):
        yield r
    for child in module.get("child_modules", []):
        yield from managed_resources(child)


def plan_offenders(path: pathlib.Path) -> list[str]:
    """Managed aws_s3_bucket addresses the plan declares, or one GUARD BROKEN line."""
    if not path.is_file():
        return [f"GUARD BROKEN: {path} does not exist — the plan never ran"]
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return [f"GUARD BROKEN: {path} is not JSON ({exc})"]
    if "resource_changes" not in plan:
        return [f"GUARD BROKEN: {path} has no resource_changes key (format_version={plan.get('format_version', 'absent')})"]
    found: dict[str, None] = {}
    for c in plan["resource_changes"]:
        if c.get("mode", "managed") == "managed" and c.get("type") == "aws_s3_bucket":
            found[c["address"]] = None
    for r in managed_resources(plan.get("planned_values", {}).get("root_module", {})):
        if r.get("mode", "managed") == "managed" and r.get("type") == "aws_s3_bucket":
            found[r["address"]] = None
    return [f"{addr}: stage 1 declares an aws_s3_bucket. The durable bucket is stage 0's (ADR-0083)." for addr in found]


# ---------------------------------------------------------------------------
# self-test: a clean copy of real stage 1 files passes, one injected construct
# per rule fails, and the plan mode rejects a bucket.
# ---------------------------------------------------------------------------

INJECT: list[tuple[str, str]] = [
    ("prevent_destroy", '  lifecycle {\n    prevent_destroy = true\n  }\n'),
    ("state rm", 'terraform state rm "module.s3.aws_s3_bucket.this"\n'),
    ("teardown:keep", '--filters Name=tag-key,Values=teardown:keep\n'),
    ("eks-import-persistent", 'bash "$(dirname "$0")/eks-import-persistent.sh"\n'),
    ("EBS capture", 'PRESERVE_FILE=".destroy-preserve.env"\n'),
]

PLAN_BUCKET = {"format_version": "1.2", "resource_changes": [
    {"address": 'module.s3.aws_s3_bucket.this["audit"]', "mode": "managed", "type": "aws_s3_bucket", "change": {"actions": ["create"]}},
    {"address": "module.network.aws_vpc.this", "mode": "managed", "type": "aws_vpc", "change": {"actions": ["create"]}},
]}
PLAN_DATA_ONLY = {"format_version": "1.2", "resource_changes": [
    {"address": "data.aws_s3_bucket.durable", "mode": "data", "type": "aws_s3_bucket", "change": {"actions": ["read"]}},
    {"address": "module.network.aws_vpc.this", "mode": "managed", "type": "aws_vpc", "change": {"actions": ["create"]}},
]}
PLAN_NESTED = {"format_version": "1.2", "resource_changes": [], "planned_values": {"root_module": {"child_modules": [
    {"address": "module.s3", "resources": [{"address": 'module.s3.aws_s3_bucket.this["backups"]', "mode": "managed", "type": "aws_s3_bucket"}]}]}}}


def fixture_tree(tmp: pathlib.Path) -> None:
    """A small stage 1: the network module and the apply script, verbatim."""
    for rel in ["modules/network", "scripts/eks-pre-destroy.sh", "main.tf"]:
        src = ROOT / STAGE1 / rel
        dst = tmp / STAGE1 / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, dst, ignore=shutil.ignore_patterns(".terraform*"))
        else:
            shutil.copy(src, dst)
    (tmp / "Makefile").write_text("eks-up: eks-init\n\t@echo up\n")
    (tmp / ".github/workflows").mkdir(parents=True)
    (tmp / ".github/workflows/ci.yml").write_text("jobs:\n  guards:\n    steps: []\n")


def selftest() -> int:
    def broken(msg: str) -> int:
        print(f"GUARD BROKEN: {msg}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as d:
        tmp = pathlib.Path(d)
        fixture_tree(tmp)
        bad, seen = scan(tmp, floor=1)
        if bad:
            return broken(f"a clean copy of stage 1 was rejected: {bad}")
        bad, _ = scan(tmp, floor=seen + 1)
        if not bad:
            return broken("a scan under the reach floor reported clean")
        # A retain construct in the SECOND stage 1 root must be refused too.
        # This is the failing fixture for the multi-root scan (hosted#159).
        second = tmp / "bootstrap/ec2/gibson"
        second.mkdir(parents=True, exist_ok=True)
        (second / "injected.tf").write_text(
            'resource "aws_eip" "node" {\n  lifecycle {\n    prevent_destroy = true\n  }\n}\n'
        )
        bad, _ = scan(tmp, floor=1)
        if not any("bootstrap/ec2/gibson/injected.tf" in b for b in bad):
            return broken(f"a prevent_destroy in the second stage 1 root was accepted (got {bad})")
        (second / "injected.tf").unlink()
        # A teardown:keep tag in the permanent public-site root must be refused
        # (hosted#411), and a prevent_destroy there must pass: that root is
        # permanent, and its state bucket keeps the lifecycle guard on purpose.
        site = tmp / "bootstrap/eks/public-site"
        site.mkdir(parents=True, exist_ok=True)
        (site / "injected.tf").write_text(
            'resource "aws_s3_bucket" "this" {\n  tags = {\n    "teardown:keep" = "public web surface"\n  }\n}\n'
        )
        bad, _ = scan(tmp, floor=1)
        if not any("bootstrap/eks/public-site/injected.tf" in b and "teardown:keep" in b for b in bad):
            return broken(f"a teardown:keep tag in the public-site root was accepted (got {bad})")
        (site / "injected.tf").write_text(
            'resource "aws_s3_bucket" "state" {\n  lifecycle {\n    prevent_destroy = true\n  }\n}\n'
        )
        bad, _ = scan(tmp, floor=1)
        if bad:
            return broken(f"a prevent_destroy in the permanent public-site root was rejected: {bad}")
        (site / "injected.tf").unlink()
        bad, _ = scan(tmp, floor=1)
        if bad:
            return broken(f"the fixture tree was left dirty: {bad}")

        target = tmp / STAGE1 / "scripts/eks-pre-destroy.sh"
        clean = target.read_text()
        for name, snippet in INJECT:
            target.write_text(clean + snippet)
            bad, _ = scan(tmp, floor=1)
            if not any(f": {name}:" in b for b in bad):
                return broken(f"an injected {name} was accepted (got {bad})")
        target.write_text(clean)
        # A copy of a module with one prevent_destroy added fails, naming the file.
        module_copy = tmp / STAGE1 / "modules/network-copy"
        shutil.copytree(tmp / STAGE1 / "modules/network", module_copy)
        with (module_copy / "main.tf").open("a") as fh:
            fh.write('\nresource "aws_eip" "kept" {\n  lifecycle {\n    prevent_destroy = true\n  }\n}\n')
        bad, _ = scan(tmp, floor=1)
        if not any("modules/network-copy/main.tf" in b and "prevent_destroy" in b for b in bad):
            return broken(f"a module copy with prevent_destroy was accepted (got {bad})")
        shutil.rmtree(module_copy)
        # .terraform/ is provider cache, not our code.
        cache = tmp / STAGE1 / ".terraform/modules/x/main.tf"
        cache.parent.mkdir(parents=True)
        cache.write_text("lifecycle { prevent_destroy = true }\n")
        bad, _ = scan(tmp, floor=1)
        if bad:
            return broken(f"a provider cache file was scanned: {bad}")
        (tmp / "Makefile").write_text("eks-reset:\n\t@$(MAKE) eks-down\n")
        bad, _ = scan(tmp, floor=1)
        if not any("Makefile" in b and "eks-reset" in b for b in bad):
            return broken(f"a Makefile eks-reset target was accepted (got {bad})")
        (tmp / "Makefile").write_text("eks-up:\n\t@echo up\n")
        # plan mode
        for label, plan, want in [("a managed bucket", PLAN_BUCKET, 'module.s3.aws_s3_bucket.this["audit"]'),
                                  ("a nested planned bucket", PLAN_NESTED, 'module.s3.aws_s3_bucket.this["backups"]')]:
            f = tmp / "plan.json"
            f.write_text(json.dumps(plan))
            bad = plan_offenders(f)
            if not any(want in b for b in bad):
                return broken(f"a plan with {label} was accepted (got {bad})")
        f = tmp / "plan.json"
        f.write_text(json.dumps(PLAN_DATA_ONLY))
        if plan_offenders(f):
            return broken(f"a plan that only READS a bucket was rejected: {plan_offenders(f)}")
        f.write_text(json.dumps({"format_version": "1.2"}))
        if not any("GUARD BROKEN" in b for b in plan_offenders(f)):
            return broken("a plan without resource_changes was accepted")
        if not any("GUARD BROKEN" in b for b in plan_offenders(tmp / "absent.json")):
            return broken("a missing plan file was accepted")
    print(f"✅ self-test: the clean stage 1 copy passes, {len(INJECT)} injected constructs + a module copy with prevent_destroy + a teardown:keep tag in the public-site root + an eks-reset target are rejected, the plan mode rejects a bucket and accepts a data source")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) == 3 and argv[1] == "--plan":
        bad = plan_offenders(pathlib.Path(argv[2]))
        if bad:
            print("❌ the bootstrap/eks/gibson plan declares a bucket. Stage 1 owns no bucket (ADR-0083, deploy#1743):")
            for b in bad:
                print("   ", b)
            return 2 if all(b.startswith("GUARD BROKEN") for b in bad) else 1
        print(f"✅ {argv[2]}: no managed aws_s3_bucket in the plan")
        return 0
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    bad, seen = scan(ROOT)
    if any(b.startswith("GUARD BROKEN") for b in bad):
        for b in bad:
            print(b, file=sys.stderr)
        return 2
    if bad:
        print(f"❌ {len(bad)} retain construct(s) in stage 1. Both teardown modes destroy it whole (ADR-0083, deploy#1743):")
        for b in bad:
            print("   ", b)
        return 1
    names = ", ".join(d.as_posix() for d in STAGE1_ROOTS)
    tag_names = ", ".join(d.as_posix() for d in TAG_ONLY_ROOTS)
    print(f"✅ {seen} files scanned: {names} carry no prevent_destroy, state rm, teardown:keep, import script or EBS capture, {tag_names} carries no teardown:keep tag, and nothing defines eks-reset")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
