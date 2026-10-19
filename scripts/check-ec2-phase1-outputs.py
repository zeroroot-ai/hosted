#!/usr/bin/env python3
"""Guard: each output that the EC2 recreate reads after phase 1 is written by phase 1.

scripts/recreate-ec2.sh applies phase 1 with -target on every aws_ resource of
bootstrap/ec2/gibson, then reads outputs with `terraform output -raw <name>`
before phase 2. A targeted apply writes no output that depends on no targeted
resource. Such an output reads "not found", and the recreate stops.

Measured twice: on 2026-10-06 `nested_virtualization` (hosted#498), and on
2026-10-12 `node_count`, which was `var.node_count` (hosted#609).

WHAT IT CHECKS
    Each name in a `terraform ... output -raw <name>` call of
    scripts/recreate-ec2.sh above the phase 2 apply is an output of the root,
    and its value names an aws_ resource of the root (aws_<type>.<name>).
    The check reads both files, so a new read is covered with no change here.

Usage:
    scripts/check-ec2-phase1-outputs.py             # the guard
    scripts/check-ec2-phase1-outputs.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 a rule is broken · 2 the self-test is broken or nothing was read

The fixtures are in tests/guards/ec2-phase1-outputs/<case>/{recreate.sh,outputs.tf}.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EC2_DIR = ROOT / "bootstrap" / "ec2" / "gibson"
RECREATE = ROOT / "scripts" / "recreate-ec2.sh"
FIXTURES = ROOT / "tests" / "guards" / "ec2-phase1-outputs"

READ = re.compile(r'terraform\s+-chdir="\$EC2_DIR"\s+output\s+-raw\s+([a-z0-9_]+)')
PHASE2 = re.compile(r'phase 2')
OUTPUT = re.compile(r'^output\s+"([a-z0-9_]+)"\s*\{(.*?)^\}', re.S | re.M)
VALUE = re.compile(r'^\s*value\s*=\s*(.*)$', re.M)
RESOURCE = re.compile(r'^resource\s+"(aws_[a-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"', re.M)


def strip_comments(text: str) -> str:
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def phase1_reads(script: str) -> list[str]:
    reads = []
    for line in script.splitlines():
        code = line.split("#", 1)[0]
        if PHASE2.search(line) and "log " in line:
            break
        reads += READ.findall(code)
    return reads


def findings(script_path: pathlib.Path, tf_dir: pathlib.Path) -> list[str]:
    reads = phase1_reads(script_path.read_text(encoding="utf-8"))
    if not reads:
        return [f"{script_path}: no `output -raw` read before phase 2 was found, so the check did not look at anything"]
    outputs: dict[str, str] = {}
    resources: set[str] = set()
    for tf in sorted(tf_dir.glob("*.tf")):
        text = strip_comments(tf.read_text(encoding="utf-8"))
        for name, body in OUTPUT.findall(text):
            m = VALUE.search(body)
            outputs[name] = m.group(1) if m else ""
        resources |= {f"{k}.{n}" for k, n in RESOURCE.findall(text)}
    out = []
    for name in reads:
        if name not in outputs:
            out.append(f"the recreate reads the output {name}, and {tf_dir} declares no such output")
            continue
        named = set(re.findall(r'\b(aws_[a-z0-9_]+\.[A-Za-z0-9_-]+)', outputs[name])) & resources
        if not named:
            out.append(
                f"the output {name} is `{outputs[name].strip()}`, which names no aws_ resource of the root. "
                "Phase 1 applies with -target and does not write it, so the read after phase 1 fails. "
                "Derive the value from a resource")
    return out


def selftest() -> int:
    cases = {"good": 0, "bad-variable-only": 1, "bad-missing-output": 1}
    for name, want in cases.items():
        d = FIXTURES / name
        if not (d / "recreate.sh").is_file():
            print(f"check-ec2-phase1-outputs: selftest: the fixture {name} is missing", file=sys.stderr)
            return 2
        got = findings(d / "recreate.sh", d)
        if (len(got) > 0) != (want > 0):
            print(f"check-ec2-phase1-outputs: selftest: {name} gave {got}", file=sys.stderr)
            return 2
    print("✅ self-test: an output that names only a variable, and a read of no output, are each rejected")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    got = findings(RECREATE, EC2_DIR)
    if got:
        print("check-ec2-phase1-outputs: scripts/recreate-ec2.sh and bootstrap/ec2/gibson:", file=sys.stderr)
        for g in got:
            print(f"  {g}", file=sys.stderr)
        return 1
    print("✅ each output the EC2 recreate reads after phase 1 names an aws_ resource that phase 1 applies")
    return 0


if __name__ == "__main__":
    sys.exit(main())
