#!/usr/bin/env python3
"""Every cluster overlay names the addresses a pod reaches the kube-apiserver through.

`global.networkPolicy.apiServerCIDRs` ships EMPTY in the chart, and the helper
`gibson.netpolEgressAPIServer` renders NOTHING when it is empty. An omission is
therefore not a weaker policy, it is a missing one — and on a CNI that does not
enforce NetworkPolicy it is invisible until the first cluster that does.

WHAT IT HAS COST, three times, every time as OpenBao's Kubernetes-auth login
answering a bare "permission denied", then the secret store InvalidProviderConfig,
then every ExternalSecret in SecretSyncedError, and the platform never finishing:

    staging 2026-09-10   the VPC CIDR was allowed and the ClusterIP was not
    k3d     2026-09-14   zeroroot-ai/charts#80
    staging 2026-09-23   the CIDR was stale after the ADR-0095 move to 10.60.0.0/16

Note the third one. A committed CIDR is a fact that can ROT, and that is the class
this gate closes: the value is DERIVED from the substrate that defines it and the
overlay must agree, so moving a VPC range fails here instead of in a bringup.

WHY NOT DERIVE IT AT BRINGUP

On AWS the verb cannot. Terraform creates an app-of-apps that reads
`gitops/envs/<env>/` from git at `targetRevision: main` with `selfHeal: true`, so a
parameter injected into a child Application is reverted on the next reconcile.
Every AWS bringup value is a reviewed commit; there is no script-time seam, and
adding one is an ApplicationSet or a terraform-owned Application — a design call.
ENV=kind is the exception and needs no entry here: `scripts/recreate-kind.sh`
builds its Applications inline and derives the pair from the live cluster
(check-kind-apiserver-cidrs.py).

THE DERIVATION, from committed facts only

  node range       `vpc_cidr` in the env's bootstrap workspace — the env's own
                   tfvars when it overrides, else the variable's default.
  apiserver address the first address of the Service range, `service_cidr` in
                   the same workspace. The EC2 workspace passes it to k3s as
                   --service-cidr, and the EKS workspace sets it on the cluster
                   as service_ipv4_cidr, so it is the range the cluster uses.
                   It is required: a missing value fails, never a guess.

The overlay pins no Envoy ClusterIP any more. charts#163 deleted
envoy.service.clusterIP (ADR-0092: a client dials the Envoy Service by name), and
this check used to read the Service range from that pin. It now reads the range
from the stage 1 Terraform, the reviewed commit that defines it, and it fails an
overlay that still pins a clusterIP, because the chart refuses that value.

BOTH NAMES, because they are the same apiserver and a policy engine may judge
either: kube-proxy rewrites the destination before a NetworkPolicy is evaluated,
so a packet to the Service leaves as the endpoint address, while an engine that
evaluates the pre-DNAT address sees the ClusterIP. Measured on staging 2026-09-10:
with only the VPC CIDR allowed, the ENIs answered and the ClusterIP timed out.

  check-apiserver-cidrs.py             exit 1 when an overlay is empty or disagrees
  check-apiserver-cidrs.py --selftest  prove each assertion fails on a fixture
"""
from __future__ import annotations

import ipaddress
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("check-apiserver-cidrs: PyYAML is required (requirements-ci.txt)")

ROOT = Path(__file__).resolve().parent.parent

# env -> the bootstrap workspace that defines its network.
#
# One deliberate absence, so it does not read as an oversight:
#   kind  `make recreate ENV=kind` builds its Argo Applications inline and derives
#         the pair from the live cluster at bringup, which is the better source
#         where it is available (check-kind-apiserver-cidrs.py).
SUBSTRATE = {
    "staging": "bootstrap/ec2/gibson",
    "drill": "bootstrap/ec2/gibson",
    "prod": "bootstrap/eks/gibson",
}

KEY_PATH = ("global", "networkPolicy", "apiServerCIDRs")


class Problem(Exception):
    pass


def tfvar(workspace: Path, env: str, name: str, *, required: bool) -> str | None:
    """A terraform scalar: the env's tfvars when it overrides, else the default.

    Never returns a value it did not actually read. A missing required variable
    raises rather than falling back, because a derivation that quietly invents an
    input is how a wrong CIDR gets committed — which is the same failure as an
    absent one (staging 2026-09-23).
    """
    envfile = workspace / "envs" / f"{env}.tfvars"
    if envfile.is_file():
        m = re.search(rf'^\s*{re.escape(name)}\s*=\s*"([^"]+)"', envfile.read_text(), re.M)
        if m:
            return m.group(1)
    varsfile = workspace / "variables.tf"
    if varsfile.is_file():
        text = varsfile.read_text()
        m = re.search(rf'variable\s+"{re.escape(name)}"\s*\{{(.*?)^\}}', text, re.M | re.S)
        if m:
            d = re.search(r'^\s*default\s*=\s*"([^"]+)"', m.group(1), re.M)
            if d:
                return d.group(1)
    if required:
        raise Problem(
            f"{workspace}/variables.tf declares no default for `{name}` and "
            f"{workspace}/envs/{env}.tfvars does not set it, so this check cannot derive "
            f"the expected apiServerCIDRs for {env}. Set it in the tfvars, or give the "
            f"variable a default — do not guess the range."
        )
    return None


def pinned_cluster_ips(values: dict) -> dict[str, str]:
    """Every clusterIP the overlay still sets, by dotted path."""
    found: dict[str, str] = {}

    def walk(node, path: tuple[str, ...]) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "clusterIP" and isinstance(v, str) and v:
                    found[".".join(path + (k,))] = v
                walk(v, path + (k,))
        elif isinstance(node, list):
            for item in node:
                walk(item, path)

    walk(values, ())
    return found


def expected_for(env: str, workspace_rel: str, root: Path) -> tuple[list[str], str]:
    workspace = root / workspace_rel
    values_path = root / "gitops" / "envs" / env / "values.yaml"
    if not values_path.is_file():
        raise Problem(f"{values_path} does not exist, but {env} is listed as a cloud env")
    values = yaml.safe_load(values_path.read_text()) or {}

    node_range = tfvar(workspace, env, "vpc_cidr", required=True)
    ipaddress.IPv4Network(node_range)  # refuses a malformed value loudly

    pinned = pinned_cluster_ips(values)
    if pinned:
        raise Problem(
            f"gitops/envs/{env}/values.yaml still pins a clusterIP ({pinned}). charts#163 "
            f"deleted envoy.service.clusterIP, so the chart refuses the value: a client "
            f"dials the Envoy Service by name (ADR-0092). Delete it."
        )

    declared = tfvar(workspace, env, "service_cidr", required=True)
    svc_range = ipaddress.IPv4Network(declared)  # refuses a malformed value loudly
    apiserver = ipaddress.IPv4Address(int(svc_range.network_address) + 1)
    note = f"service range {declared} declared by {workspace_rel}"

    return [node_range, f"{apiserver}/32"], note


def overlay_cidrs(root: Path, env: str) -> list[str] | None:
    values = yaml.safe_load((root / "gitops" / "envs" / env / "values.yaml").read_text()) or {}
    node = values
    for part in KEY_PATH:
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node if isinstance(node, list) else None


def violations(root: Path, substrate: dict[str, str]) -> list[str]:
    out: list[str] = []
    for env, workspace_rel in sorted(substrate.items()):
        try:
            want, note = expected_for(env, workspace_rel, root)
        except Problem as exc:
            out.append(str(exc))
            continue
        got = overlay_cidrs(root, env)
        if not got:
            out.append(
                f"{env}: global.networkPolicy.apiServerCIDRs is empty or absent, so the chart "
                f"renders NO egress rule to the kube-apiserver at all and OpenBao's every "
                f"Kubernetes-auth login answers a bare \"permission denied\". Set it to "
                f"{want} ({note})."
            )
            continue
        if sorted(got) != sorted(want):
            out.append(
                f"{env}: apiServerCIDRs is {got}, derived expects {want} ({note}). A range "
                f"that no longer matches its substrate fails exactly like an absent one — "
                f"that is what bit staging on 2026-09-23 after the ADR-0095 move."
            )
    return out


def _fixture(tmp: Path, *, vpc: str | None, svc_declared: str | None,
             overlay_cidrs_value, cluster_ip: str | None = None) -> Path:
    root = tmp
    ws = root / "bootstrap" / "fake"
    (ws / "envs").mkdir(parents=True)
    body = 'variable "cluster_name" {\n  type = string\n}\n'
    if vpc:
        body += f'variable "vpc_cidr" {{\n  type = string\n  default = "{vpc}"\n}}\n'
    if svc_declared:
        body += f'variable "service_cidr" {{\n  type = string\n  default = "{svc_declared}"\n}}\n'
    (ws / "variables.tf").write_text(body)
    (ws / "envs" / "fake.tfvars").write_text('environment = "fake"\n')
    d: dict = {}
    if cluster_ip:
        d["gibson-workloads"] = {"envoy": {"service": {"clusterIP": cluster_ip}}}
    if overlay_cidrs_value is not None:
        d["global"] = {"networkPolicy": {"apiServerCIDRs": overlay_cidrs_value}}
    p = root / "gitops" / "envs" / "fake" / "values.yaml"
    p.parent.mkdir(parents=True)
    p.write_text(yaml.safe_dump(d))
    return root


def selftest() -> int:
    import tempfile

    cases = 0
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)

        def run(name, **kw):
            sub = {"fake": "bootstrap/fake"}
            return violations(_fixture(tmp / name, **kw), sub)

        # The matching case must be silent, or every assertion below is meaningless.
        ok = run("ok", vpc="10.60.0.0/16", svc_declared="172.20.0.0/16",
                 overlay_cidrs_value=["10.60.0.0/16", "172.20.0.1/32"])
        if ok:
            print(f"SELFTEST FAIL: a correct overlay was reported: {ok}")
            return 1
        cases += 1

        for name, kw, needle in [
            ("empty", dict(vpc="10.60.0.0/16", svc_declared="172.20.0.0/16",
                           overlay_cidrs_value=[]),
             "renders NO egress rule"),
            ("absent", dict(vpc="10.60.0.0/16", svc_declared="172.20.0.0/16",
                            overlay_cidrs_value=None),
             "empty or absent"),
            ("stale", dict(vpc="10.60.0.0/16", svc_declared="172.20.0.0/16",
                           overlay_cidrs_value=["10.40.0.0/16", "172.20.0.1/32"]),
             "fails exactly like an absent one"),
            ("half", dict(vpc="10.60.0.0/16", svc_declared="172.20.0.0/16",
                          overlay_cidrs_value=["10.60.0.0/16"]),
             "derived expects"),
            ("no_vpc", dict(vpc=None, svc_declared="172.20.0.0/16",
                            overlay_cidrs_value=["10.60.0.0/16", "172.20.0.1/32"]),
             "do not guess the range"),
            ("no_service_cidr", dict(vpc="10.60.0.0/16", svc_declared=None,
                                     overlay_cidrs_value=["10.60.0.0/16", "172.20.0.1/32"]),
             "no default for `service_cidr`"),
            ("pinned_clusterip", dict(vpc="10.60.0.0/16", svc_declared="172.20.0.0/16",
                                      cluster_ip="172.20.0.250",
                                      overlay_cidrs_value=["10.60.0.0/16", "172.20.0.1/32"]),
             "still pins a clusterIP"),
            ("other_service_range", dict(vpc="10.60.0.0/16", svc_declared="10.43.0.0/16",
                                         overlay_cidrs_value=["10.60.0.0/16", "172.20.0.1/32"]),
             "derived expects"),
        ]:
            got = run(name, **kw)
            if not any(needle in g for g in got):
                print(f"SELFTEST FAIL: {name} did not produce {needle!r}: {got}")
                return 1
            cases += 1

    if cases != 9:
        print(f"SELFTEST FAIL: ran {cases} of 9 cases")
        return 1
    print("check-apiserver-cidrs: selftest OK — a correct overlay is silent; empty, absent, "
          "stale, half, an underivable range, no service_cidr, a pinned clusterIP and a "
          "Service range the overlay does not name each fail")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        rc = selftest()
        if rc:
            return rc

    # `--env <name>` scopes the check to one environment, so `make preflight
    # ENV=kind` is not failed by another env's overlay. An env with no entry here
    # derives the pair at bringup instead and is a deliberate no-op.
    substrate = dict(SUBSTRATE)
    if "--env" in sys.argv:
        want = sys.argv[sys.argv.index("--env") + 1]
        if want not in SUBSTRATE:
            print(f"check-apiserver-cidrs: {want} has no committed substrate range — its verb "
                  f"derives the apiserver addresses from the live cluster "
                  f"(check-kind-apiserver-cidrs.py). Nothing to check here.")
            return 0
        substrate = {want: SUBSTRATE[want]}

    fails = violations(ROOT, substrate)
    if fails:
        print("the apiserver egress rule does not match the substrate:", file=sys.stderr)
        for f in fails:
            print(f"  {f}", file=sys.stderr)
        return 1
    for env, ws in sorted(substrate.items()):
        want, note = expected_for(env, ws, ROOT)
        print(f"  ✓ {env}: {want[0]} + {want[1]} ({note})")
    print(f"check-apiserver-cidrs: {len(substrate)} cloud overlay(s) name both apiserver "
          "addresses, each derived from its own substrate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
