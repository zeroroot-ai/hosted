#!/usr/bin/env python3
"""Guard: one place pins the Cilium version (hosted#436, ADR-0083).

The pin is bootstrap/cilium/VERSION. Each substrate reads that file. A second
pin that differs makes two clusters run two versions of the network plugin,
and nothing shows it.

WHAT IT CHECKS
    Each tracked text file is read for a Cilium version in one of these forms:

    1. an image tag:       quay.io/cilium/cilium:v<version>, and the operator
                           and cilium-envoy images
    2. a chart version:    a line that names the cilium chart and `--version`
    3. a named variable:   cilium_version = "<version>", CILIUM_VERSION=<version>
    4. a helm_release:     a Terraform block whose chart is "cilium" and whose
                           version is a literal

    Each version found must equal the pin. A file that needs the version reads
    the pin file and holds no literal.

Usage:
    scripts/check-cilium-pin.py             # the guard
    scripts/check-cilium-pin.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 a second pin differs, or the pin file is not valid
    2 the self-test is broken

The failing fixtures are in tests/guards/cilium-pin/bad/, one file for each
form. The passing fixture is in tests/guards/cilium-pin/good/.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PIN_FILE = ROOT / "bootstrap" / "cilium" / "VERSION"
FIXTURES = ROOT / "tests" / "guards" / "cilium-pin"

SEMVER = r"v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)"
LINE_FORMS = [
    ("image tag", re.compile(r"quay\.io/cilium/(?:cilium|operator[a-z-]*|cilium-envoy):" + SEMVER)),
    ("chart version", re.compile(r"charts/cilium\b[^\n]*--version[ =]+[\"']?" + SEMVER)),
    ("chart version", re.compile(r"--version[ =]+[\"']?" + SEMVER + r"[\"']?[^\n]*charts/cilium\b")),
    ("named variable", re.compile(r"(?i)\bcilium[_-]?version\b\"?\s*(?::=|=|:)\s*[\"']?" + SEMVER)),
]
HELM_RELEASE = re.compile(r'resource\s+"helm_release"\s+"[^"]+"\s*\{')
TF_CHART = re.compile(r'^\s*chart\s*=\s*"([^"]+)"', re.M)
TF_VERSION = re.compile(r'^\s*version\s*=\s*"' + SEMVER + '"', re.M)

SKIP_PARTS = frozenset({".git", ".terraform", ".worktrees", "node_modules"})
TEXT_SUFFIXES = frozenset({
    ".tf", ".tfvars", ".tftpl", ".sh", ".bash", ".py", ".yaml", ".yml",
    ".json", ".md", ".bats", ".mk", ".toml", ".hcl", ".txt", "",
})


def read_pin(pin_file: pathlib.Path) -> str | None:
    if not pin_file.is_file():
        return None
    v = pin_file.read_text(encoding="utf-8").strip()
    return v if re.fullmatch(r"\d+\.\d+\.\d+", v) else None


def versions_in(text: str) -> list[tuple[str, int, str]]:
    """-> [(form, line number, version)] for each Cilium version literal."""
    found: list[tuple[str, int, str]] = []
    for n, line in enumerate(text.splitlines(), 1):
        for form, rx in LINE_FORMS:
            for m in rx.finditer(line):
                found.append((form, n, m.group(1)))
    blocks = list(HELM_RELEASE.finditer(text))
    for i, m in enumerate(blocks):
        end = blocks[i + 1].start() if i + 1 < len(blocks) else len(text)
        chart = TF_CHART.search(text, m.end(), end)
        if not chart or chart.group(1).rstrip("/").split("/")[-1] != "cilium":
            continue
        ver = TF_VERSION.search(text, m.end(), end)
        if ver:
            found.append(("helm_release", text.count("\n", 0, ver.start()) + 1, ver.group(1)))
    return found


def tracked_files(root: pathlib.Path) -> list[pathlib.Path]:
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=True, capture_output=True,
    ).stdout.decode("utf-8", errors="replace")
    return [root / p for p in out.split("\0") if p]


def scan(files: list[pathlib.Path], pin: str, base: pathlib.Path) -> tuple[list[str], int]:
    """-> (findings, number of files read)."""
    findings: list[str] = []
    read = 0
    for f in sorted(files):
        rel = f.relative_to(base)
        if SKIP_PARTS.intersection(rel.parts):
            continue
        if f.suffix not in TEXT_SUFFIXES or not f.is_file():
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        read += 1
        for form, line, version in versions_in(text):
            if version != pin:
                findings.append(
                    f"{rel}:{line}: {form} pins Cilium {version}, and the pin is {pin}"
                )
    return findings, read


def selftest() -> int:
    pin = "1.20.2"
    bad = sorted((FIXTURES / "bad").glob("*"))
    good = sorted((FIXTURES / "good").glob("*"))
    if len(bad) < 4 or not good:
        print("check-cilium-pin: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for f in bad:
        findings, _ = scan([f], pin, FIXTURES)
        if len(findings) != 1:
            print(f"check-cilium-pin: selftest: {f.name} gave {len(findings)} findings, not 1",
                  file=sys.stderr)
            return 2
    findings, read = scan(good, pin, FIXTURES)
    if findings or read != len(good):
        print(f"check-cilium-pin: selftest: the good fixtures gave {findings}", file=sys.stderr)
        return 2
    if read_pin(FIXTURES / "bad-pin" / "VERSION") is not None:
        print("check-cilium-pin: selftest: a pin file with no version was accepted", file=sys.stderr)
        return 2
    print(f"✅ self-test: {len(bad)} forms of a second pin are each rejected, "
          "the matching pins pass, a pin file with no version is rejected")
    return 0


def main() -> int:
    if "--selftest" in sys.argv[1:]:
        return selftest()
    pin = read_pin(PIN_FILE)
    if pin is None:
        print(f"check-cilium-pin: {PIN_FILE.relative_to(ROOT)} holds no version of the form 1.2.3",
              file=sys.stderr)
        return 1
    files = [f for f in tracked_files(ROOT)
             if FIXTURES not in f.parents and f != PIN_FILE]
    findings, read = scan(files, pin, ROOT)
    if read < 50:
        print(f"check-cilium-pin: only {read} files were read, so the scan did not look at the repo",
              file=sys.stderr)
        return 1
    if findings:
        print("check-cilium-pin: a second Cilium pin differs from bootstrap/cilium/VERSION:",
              file=sys.stderr)
        for f in findings:
            print(f"  {f}", file=sys.stderr)
        print("  Read the pin file in that place, or change the literal to the pin.", file=sys.stderr)
        return 1
    print(f"✅ Cilium has one pin, {pin}: {read} files read, no second pin differs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
