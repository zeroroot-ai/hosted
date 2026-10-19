#!/usr/bin/env python3
"""The kind bringup names every address a pod reaches the kube-apiserver through.

`global.networkPolicy.apiServerCIDRs` ships EMPTY in the chart, and empty
renders NO egress rule. So an omission is not a weaker policy, it is a missing
one, and on a CNI that does not enforce NetworkPolicy it is invisible until the
first cluster that does. The estate has paid for that three times, each time as
OpenBao's Kubernetes-auth login answering a bare "permission denied":

  staging 2026-09-10   the VPC CIDR was allowed and the ClusterIP was not
  k3d     2026-09-14   zeroroot-ai/charts#80
  staging 2026-09-23   the CIDR was stale after ADR-0095

This EXERCISES the derivation rather than grepping for it: the block is lifted
out of scripts/recreate-kind.sh and run under a real bash with kubectl stubbed,
once per case. Then the Application heredoc it feeds is rendered and parsed as
YAML, because a parameter list with the wrong indent is a broken Application and
a check that only counted lines would not notice.

Run: python3 scripts/check-kind-apiserver-cidrs.py [--selftest]
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("check-kind-apiserver-cidrs: PyYAML is required (requirements-ci.txt)")

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "recreate-kind.sh"

DERIVATION_START = re.compile(r'^API_CIDRS=\(', re.M)
DERIVATION_END = re.compile(r'^log "apiserver reachable .*$', re.M)
APP_HEREDOC = re.compile(
    r'^log "stage 2: Application gibson".*?^kubectl apply -f - >/dev/null <<YAML\n(.*?)^YAML$',
    re.M | re.S,
)


def fail(msg: str) -> None:
    sys.exit(f"check-kind-apiserver-cidrs: {msg}")


def lift(text: str) -> str:
    """The derivation block, verbatim."""
    start = DERIVATION_START.search(text)
    if not start:
        fail(
            "scripts/recreate-kind.sh no longer derives API_CIDRS. The kind bringup would "
            "install with global.networkPolicy.apiServerCIDRs empty, which renders no egress "
            "rule to the kube-apiserver at all, and OpenBao's every Kubernetes-auth login "
            "answers a bare \"permission denied\" on any cluster that enforces NetworkPolicy."
        )
    end = DERIVATION_END.search(text, start.end())
    if not end:
        fail(
            "the API_CIDRS derivation in scripts/recreate-kind.sh does not end with the "
            "`log \"apiserver reachable ...\"` line this check anchors on. Either the block was "
            "rewritten or the log line was dropped; this check cannot lift it."
        )
    return text[start.start():end.end()]


def run_derivation(block: str, cluster_ip: str, endpoints: list[str]) -> tuple[int, str, str]:
    """Run the lifted block with kubectl stubbed. Returns (rc, api_cidr_params_yaml, stderr)."""
    # Real newlines, the way `kubectl -o jsonpath='...{"\n"}...'` emits them. A
    # bash single-quoted "\n" is a literal backslash-n, which the derivation would
    # happily carry into a CIDR — the first run of this check caught exactly that
    # in the harness, so the stub builds the stream with printf per line instead.
    eps = "".join(f"printf '%s\\n' {ip!r}\n  " for ip in endpoints) or "true"
    harness = f"""
set -u
K8S_SVC_IP={cluster_ip!r}
log() {{ printf '%s\\n' "$*" >&2; }}
die() {{ printf 'DIE: %s\\n' "$*" >&2; exit 9; }}
kubectl() {{
  # Only the endpoints read is reached here; the ClusterIP is already in hand.
  {eps}
}}
{block}
printf 'PARAMS<<<%s>>>' "$api_cidr_params_yaml"
"""
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as fh:
        fh.write(harness)
        path = fh.name
    proc = subprocess.run(["bash", path], capture_output=True, text=True)
    Path(path).unlink(missing_ok=True)
    m = re.search(r"PARAMS<<<(.*)>>>", proc.stdout, re.S)
    return proc.returncode, (m.group(1) if m else ""), proc.stderr


def render_application(text: str, params_yaml: str) -> dict:
    """The gibson Application heredoc, with this run's parameters, parsed as YAML."""
    m = APP_HEREDOC.search(text)
    if not m:
        fail(
            "the `stage 2: Application gibson` heredoc is not where this check expects it in "
            "scripts/recreate-kind.sh, so the parameter list it emits cannot be parsed."
        )
    body = m.group(1)
    if "${api_cidr_params_yaml}" not in body:
        fail(
            "the gibson Application does not interpolate ${api_cidr_params_yaml}. The CIDRs "
            "would be derived and then never passed to the chart, which is the same as not "
            "deriving them."
        )
    body = body.replace("${api_cidr_params_yaml}", params_yaml)
    # Another parameter fragment (a *_params_yaml variable holds whole list
    # items, for example the previous setec disk key) is empty here. Every
    # other expansion becomes a placeholder; only the parameter list is under
    # test.
    body = re.sub(r'\$\{[A-Za-z_][A-Za-z0-9_]*_params_yaml\}', "", body)
    body = re.sub(r'\$\{[A-Za-z_][A-Za-z0-9_]*\}', "x", body)
    body = re.sub(r'\$\{[^}]*\}', "x", body)
    try:
        return yaml.safe_load(body)
    except yaml.YAMLError as exc:
        fail(
            "the gibson Application does not parse as YAML once the parameter list is "
            f"substituted, so the bringup would apply nothing: {exc}"
        )
    raise AssertionError("unreachable")


def params_of(app: dict) -> dict[str, str]:
    try:
        raw = app["spec"]["source"]["helm"]["parameters"]
    except (KeyError, TypeError):
        fail("the rendered Application has no spec.source.helm.parameters")
    return {p["name"]: str(p["value"]) for p in raw}


def main() -> None:
    selftest = "--selftest" in sys.argv
    text = SCRIPT.read_text()
    block = lift(text)
    checks = 0

    # 1. The ordinary kind shape: one Service address, one control-plane endpoint.
    rc, params_yaml, err = run_derivation(block, "10.96.0.1", ["172.18.0.3"])
    if rc != 0:
        fail(f"the derivation refused a normal kind cluster (rc={rc}): {err.strip()}")
    app = render_application(text, params_yaml)
    got = params_of(app)
    want = {
        "global.networkPolicy.apiServerCIDRs[0]": "10.96.0.1/32",
        "global.networkPolicy.apiServerCIDRs[1]": "172.18.0.3/32",
    }
    for name, value in want.items():
        if got.get(name) != value:
            fail(
                f"the Application does not pass {name}={value}; it passes "
                f"{got.get(name)!r}. Both the Service address and the endpoint address must be "
                "named: kube-proxy rewrites the destination before a NetworkPolicy is "
                "evaluated, so one of the two is what the engine actually matches."
            )
    checks += 1

    # 2. A multi-endpoint control plane: every address, none dropped.
    rc, params_yaml, err = run_derivation(
        block, "172.20.0.1", ["10.60.1.7", "10.60.2.9", "10.60.3.4"]
    )
    if rc != 0:
        fail(f"the derivation refused a three-endpoint control plane (rc={rc}): {err.strip()}")
    got = params_of(render_application(text, params_yaml))
    indexed = {k: v for k, v in got.items() if k.startswith("global.networkPolicy.apiServerCIDRs")}
    if len(indexed) != 4:
        fail(
            f"a control plane with three endpoints produced {len(indexed)} CIDR parameter(s), "
            "not 4. An apiserver address the rule does not name is an apiserver OpenBao cannot "
            f"reach: {indexed}"
        )
    checks += 1

    # 3. Endpoints that did not answer must REFUSE, not render half a rule.
    rc, _, err = run_derivation(block, "10.96.0.1", [])
    if rc == 0:
        fail(
            "the derivation accepted a cluster whose kubernetes endpoints returned nothing. It "
            "would pass the Service address alone, and on an engine that matches the post-DNAT "
            "address that rule names nothing the apiserver answers from. It must refuse."
        )
    if "re-run" not in err.lower():
        fail(f"the refusal does not say what to do about it: {err.strip()!r}")
    checks += 1

    if selftest:
        # The check must fail when the parameters stop reaching the chart.
        broken = text.replace("${api_cidr_params_yaml}", "")
        try:
            render_application(broken, "\n        - name: x\n          value: \"y\"")
        except SystemExit as exc:
            if "never passed to the chart" not in str(exc):
                fail(f"selftest: wrong refusal for an unwired parameter list: {exc}")
        else:
            fail("selftest: an Application that drops the parameter list was accepted")
        # And when the derivation is gone entirely.
        try:
            lift(text.replace("API_CIDRS=(", "UNUSED_CIDRS=("))
        except SystemExit as exc:
            if "no longer derives API_CIDRS" not in str(exc):
                fail(f"selftest: wrong refusal for a missing derivation: {exc}")
        else:
            fail("selftest: a recreate-kind.sh with no derivation was accepted")
        print("check-kind-apiserver-cidrs: selftest OK — an unwired list and a missing "
              "derivation are both refused")

    if checks != 3:
        fail(f"ran {checks} of 3 cases")
    print(
        "check-kind-apiserver-cidrs: 3/3 — the kind bringup names both apiserver addresses, "
        "keeps every endpoint of a multi-address control plane, refuses a half-read, and the "
        "Application it writes still parses"
    )


if __name__ == "__main__":
    main()
