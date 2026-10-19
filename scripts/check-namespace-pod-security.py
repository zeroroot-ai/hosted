#!/usr/bin/env python3
"""Guard: the gibson namespace enforces the restricted Pod Security level,
and one place per env sets it (D8, ADR-0165, hosted#438).

WHAT IT CHECKS
    1. The one place of each env sets the labels enforce, audit and warn to
       restricted. The places are the managedNamespaceMetadata of the gibson
       Argo Application:
         - gitops/envs/<env>/gibson.yaml, for each env directory
         - the gibson Application of scripts/recreate-kind.sh, for kind
       A missing label, a weaker level (baseline, privileged) or a missing
       env file fails.
    2. No other file sets a Pod Security label on the gibson namespace:
         - a Terraform kubernetes_namespace(_v1) resource named gibson
         - a YAML Namespace named gibson
         - a `kubectl label` line that names the gibson namespace
       A lifecycle ignore_changes entry is not a label and passes.

Usage:
    scripts/check-namespace-pod-security.py             # the guard
    scripts/check-namespace-pod-security.py --selftest  # prove that it can fail
Exit:
    0 clean · 1 a finding · 2 the self-test is broken

The failing fixtures are in tests/guards/namespace-pod-security/bad-*/, one
directory for each way to fail. The passing fixture is good/.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tests" / "guards" / "namespace-pod-security"
NAMESPACE = "gibson"
PSS = "pod-security.kubernetes.io/"
WANT = {f"{PSS}enforce": "restricted", f"{PSS}audit": "restricted", f"{PSS}warn": "restricted"}

TF_NS = re.compile(r'resource\s+"kubernetes_namespace(?:_v1)?"\s+"[^"]+"\s*\{')
TF_NAME = re.compile(r'^\s*name\s*=\s*"([^"]+)"', re.M)
KUBECTL_LABEL = re.compile(r"kubectl\s+label\s+(?:ns|namespace|namespaces)\b[^\n]*" + re.escape(PSS))


def tf_block(text: str, start: int) -> str:
    """The text of the block that opens at start, up to its closing brace."""
    depth = 0
    for i in range(text.index("{", start), len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return text[start:]


def strip_ignore_changes(block: str) -> str:
    """Drop lifecycle ignore_changes lists: they name labels, they set none."""
    out = block
    while True:
        m = re.search(r"ignore_changes\s*=\s*\[", out)
        if not m:
            return out
        depth, i = 0, m.end() - 1
        for i in range(m.end() - 1, len(out)):
            if out[i] == "[":
                depth += 1
            elif out[i] == "]":
                depth -= 1
                if depth == 0:
                    break
        out = out[:m.start()] + out[i + 1:]


def application_labels(doc: dict) -> dict | None:
    """The managedNamespaceMetadata labels of a gibson Application, or None."""
    if not isinstance(doc, dict) or doc.get("kind") != "Application":
        return None
    spec = doc.get("spec") or {}
    if (spec.get("destination") or {}).get("namespace") not in (NAMESPACE, "${NS}"):
        return None
    meta = (spec.get("syncPolicy") or {}).get("managedNamespaceMetadata") or {}
    return meta.get("labels") or {}


def check_place(name: str, labels: dict | None) -> list[str]:
    if labels is None:
        return [f"{name}: no gibson Application with managedNamespaceMetadata"]
    bad = []
    for key, want in WANT.items():
        got = labels.get(key)
        if got != want:
            bad.append(f"{name}: {key} is {got!r}, want {want!r}")
    return bad


def kind_labels(text: str) -> dict | None:
    """The managedNamespaceMetadata labels of the gibson Application of the
    kind recreate script. The heredoc holds shell expansions, so it is not
    YAML as a whole: only the managedNamespaceMetadata block is read."""
    anchor = text.find('log "stage 2: Application gibson"')
    if anchor < 0:
        return None
    m = re.search(r"<<YAML\n(.*?)\nYAML\n", text[anchor:], re.S)
    if not m:
        return None
    lines = m.group(1).split("\n")
    for i, line in enumerate(lines):
        if line.strip() == "managedNamespaceMetadata:":
            indent = len(line) - len(line.lstrip())
            block = [line[indent:]]
            for nxt in lines[i + 1:]:
                if nxt.strip() and len(nxt) - len(nxt.lstrip()) <= indent:
                    break
                block.append(nxt[indent:])
            meta = yaml.safe_load("\n".join(block)) or {}
            return (meta.get("managedNamespaceMetadata") or {}).get("labels") or {}
    return None


def places(root: pathlib.Path) -> list[str]:
    bad = []
    envs = sorted(p for p in (root / "gitops" / "envs").glob("*") if p.is_dir())
    if not envs:
        bad.append("gitops/envs: no env directory, so the guard looked at nothing")
    for env in envs:
        path = env / "gibson.yaml"
        rel = path.relative_to(root)
        if not path.exists():
            bad.append(f"{rel}: missing")
            continue
        labels = None
        for doc in yaml.safe_load_all(path.read_text()):
            got = application_labels(doc)
            if got is not None:
                labels = got
        bad += check_place(str(rel), labels)
    script = root / "scripts" / "recreate-kind.sh"
    if not script.exists():
        bad.append("scripts/recreate-kind.sh: missing")
    else:
        bad += check_place("scripts/recreate-kind.sh", kind_labels(script.read_text()))
    return bad


def tracked(root: pathlib.Path) -> list[pathlib.Path]:
    try:
        out = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True, check=True).stdout
        return [root / line for line in out.splitlines() if line]
    except (subprocess.CalledProcessError, FileNotFoundError):
        return [p for p in root.rglob("*") if p.is_file()]


def second_places(root: pathlib.Path, files: list[pathlib.Path]) -> list[str]:
    bad = []
    for path in files:
        rel = path.relative_to(root)
        if rel.parts and rel.parts[0] == "tests":
            continue
        if path.suffix not in (".tf", ".yaml", ".yml", ".sh", ".bash", ".tftpl"):
            continue
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        if PSS not in text:
            continue
        if path.suffix in (".tf", ".tftpl"):
            for m in TF_NS.finditer(text):
                block = tf_block(text, m.start())
                name = TF_NAME.search(block)
                if name and name.group(1) == NAMESPACE and PSS in strip_ignore_changes(block):
                    bad.append(f"{rel}: a Terraform namespace resource sets a Pod Security label on {NAMESPACE}")
        elif path.suffix in (".yaml", ".yml"):
            try:
                docs = list(yaml.safe_load_all(text))
            except yaml.YAMLError:
                docs = []
            for doc in docs:
                if isinstance(doc, dict) and doc.get("kind") == "Namespace" and \
                        (doc.get("metadata") or {}).get("name") == NAMESPACE and \
                        any(k.startswith(PSS) for k in ((doc.get("metadata") or {}).get("labels") or {})):
                    bad.append(f"{rel}: a Namespace manifest sets a Pod Security label on {NAMESPACE}")
        if path.suffix in (".sh", ".bash", ".tftpl"):
            for m in KUBECTL_LABEL.finditer(text):
                line = m.group(0)
                if re.search(r"\b" + NAMESPACE + r"\b|\$\{?NS\}?", line):
                    bad.append(f"{rel}: `kubectl label` sets a Pod Security label on {NAMESPACE}")
    return bad


def audit(root: pathlib.Path, files: list[pathlib.Path] | None = None) -> list[str]:
    return places(root) + second_places(root, files if files is not None else tracked(root))


def selftest() -> int:
    good = FIXTURES / "good"
    got = audit(good, [p for p in good.rglob("*") if p.is_file()])
    if got:
        print("SELFTEST FAIL: the good fixture must pass:\n  " + "\n  ".join(got))
        return 2
    bads = sorted(p for p in FIXTURES.glob("bad-*") if p.is_dir())
    if not bads:
        print("SELFTEST FAIL: no bad fixture")
        return 2
    for bad in bads:
        if not audit(bad, [p for p in bad.rglob("*") if p.is_file()]):
            print(f"SELFTEST FAIL: the fixture {bad.name} passed, want a finding")
            return 2
    print(f"  ✓ selftest: the good fixture passes, {len(bads)} bad fixtures fail")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    bad = audit(ROOT)
    if bad:
        print("❌ the gibson namespace must enforce restricted, set in one place per env (hosted#438):")
        print("  " + "\n  ".join(bad))
        return 1
    print("✓ namespace-pod-security: each env enforces restricted on gibson, from one place")
    return 0


if __name__ == "__main__":
    sys.exit(main())
