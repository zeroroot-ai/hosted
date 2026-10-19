#!/usr/bin/env python3
"""check-plain-cluster-edge.py — the edge an environment asks for is an edge
its cluster can actually give it (ADR-0095, hosted#159).

Staging is one EC2 instance running k3s with servicelb disabled. A
`type: LoadBalancer` Service there stays Pending for ever, and the failure is
an environment that comes up Healthy and answers nothing. The overlay must
ask for a NodePort on the real port, and stage 1 must start k3s with a port
range that admits it.

Four assertions, each one a way the two halves drift apart:

  1. The overlay's edge Service is NodePort, never LoadBalancer.
  2. Its nodePort is inside the range stage 1 gives k3s.
  3. The overlay carries no cloud load-balancer annotation, because no
     controller reads them here.
  4. The edge Service pins no ClusterIP. charts#163 deleted the value: a client
     dials the Envoy Service by name (ADR-0092).
  5. Every storage class the overlay names is one this cluster has. k3s
     ships `local-path` and nothing else, and a claim naming `gp3` stays
     Pending for ever.
  6. The API-server range the NetworkPolicies allow covers the VPC this
     estate actually runs in. kube-proxy rewrites the destination before a
     policy is evaluated, so the allowed range must contain the node
     address, not only the Service address.

Run:  scripts/check-plain-cluster-edge.py [--selftest]
"""
from __future__ import annotations

import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
OVERLAY = pathlib.Path("gitops/envs/staging/values.yaml")
NODE_INIT = pathlib.Path("bootstrap/ec2/gibson/templates/node-init.sh.tftpl")
TFVARS = pathlib.Path("bootstrap/ec2/gibson/envs/staging.tfvars")
# What k3s provides on this substrate. local-path is its built-in provisioner
# and the only class a single-node cluster has.
CLUSTER_STORAGE_CLASSES = {"local-path"}
# The VPC range stage 1 builds when an environment names none.
DEFAULT_VPC_CIDR = "10.60.0.0/16"


def edge_block(text: str) -> str:
    """The envoy.service block of the overlay, as written."""
    m = re.search(r"\n    service:\n(?P<body>(?:      .*\n|\n)+)", text)
    return m.group("body") if m else ""


def port_range(node_init: str) -> tuple[int, int] | None:
    m = re.search(r"service-node-port-range=(\d+)-(\d+)", node_init)
    return (int(m.group(1)), int(m.group(2))) if m else None


def offenders(root: pathlib.Path) -> list[str]:
    bad: list[str] = []
    try:
        overlay = (root / OVERLAY).read_text()
        node_init = (root / NODE_INIT).read_text()
        tfvars = (root / TFVARS).read_text()
    except FileNotFoundError as e:
        return [f"GUARD BROKEN: {e.filename} is missing — the tree moved"]

    block = edge_block(overlay)
    if not block:
        return ["GUARD BROKEN: no envoy.service block found in the overlay — the tree moved"]

    if re.search(r"^\s*type:\s*LoadBalancer", block, re.M):
        bad.append(
            f"{OVERLAY}: the edge Service asks for a LoadBalancer. This cluster runs k3s with "
            "servicelb disabled, so the Service would stay Pending for ever and the environment "
            "would answer nothing (ADR-0095)"
        )
    if not re.search(r"^\s*type:\s*NodePort", block, re.M):
        bad.append(f"{OVERLAY}: the edge Service names no NodePort type")

    m = re.search(r"^\s*nodePort:\s*(\d+)", block, re.M)
    if not m:
        bad.append(f"{OVERLAY}: the edge Service pins no nodePort, so the host port is whatever k3s picks")
    else:
        rng = port_range(node_init)
        if rng is None:
            bad.append(f"{NODE_INIT}: k3s is started with no service-node-port-range, so a low nodePort is refused")
        elif not rng[0] <= int(m.group(1)) <= rng[1]:
            bad.append(
                f"{OVERLAY}: nodePort {m.group(1)} is outside the range {rng[0]}-{rng[1]} that "
                f"{NODE_INIT} gives k3s. The API server refuses the Service"
            )

    for ann in re.findall(r"service\.beta\.kubernetes\.io/aws-load-balancer[\w.-]*", block):
        bad.append(
            f"{OVERLAY}: the edge Service carries the cloud annotation {ann}. No controller reads "
            "it on a plain cluster, so it is a promise nothing keeps"
        )

    # Every storage class the overlay names must exist on this cluster. k3s
    # provides local-path and nothing else. `gp3` is the EKS EBS class: a
    # claim naming it stays Pending for ever, OpenBao never schedules, and
    # the only sign is one scheduler event (measured 2026-09-22).
    for m_sc in re.finditer(r'^\s*storageClass(?:Name)?:\s*"?([\w-]+)"?', overlay, re.M):
        if m_sc.group(1) not in CLUSTER_STORAGE_CLASSES:
            bad.append(
                f"{OVERLAY}: the overlay asks for storage class {m_sc.group(1)!r}, which this "
                f"cluster does not have. k3s provides {', '.join(sorted(CLUSTER_STORAGE_CLASSES))}. "
                "A claim naming another class stays Pending for ever (ADR-0095)"
            )

    # The API-server range must cover the VPC the instance runs in. A packet
    # to the kubernetes Service leaves as the API server's REAL address
    # because kube-proxy rewrites it before the policy is evaluated. A stale
    # range denies every egress to the API, and the symptom is nothing to do
    # with networking: OpenBao cannot run a TokenReview, so every login
    # answers 403 and the platform never seeds (measured 2026-09-23).
    cidrs = re.search(r'^\s*apiServerCIDRs:\s*\n((?:\s*#.*\n|\s*-\s*"[^"]+"\s*\n)+)', overlay, re.M)
    if not cidrs:
        bad.append(f"{OVERLAY}: the overlay names no global.networkPolicy.apiServerCIDRs, so the umbrella default of none denies every egress to the API server")
    else:
        listed = re.findall(r'-\s*"([^"]+)"', cidrs.group(1))
        vpc = re.search(r'^\s*vpc_cidr\s*=\s*"([^"]+)"', tfvars, re.M)
        want = vpc.group(1) if vpc else DEFAULT_VPC_CIDR
        if not any(c == want for c in listed):
            bad.append(
                f"{OVERLAY}: the API-server range {listed} does not contain this estate's VPC {want!r}. "
                "kube-proxy rewrites the destination before the policy is evaluated, so every egress to "
                "the API server is denied and every Kubernetes-auth login answers 403 (ADR-0095)"
            )

    ip = re.search(r'^\s*clusterIP:\s*"([^"]+)"', block, re.M)
    if ip:
        bad.append(
            f"{OVERLAY}: the edge Service pins the ClusterIP {ip.group(1)}. charts#163 deleted "
            "envoy.service.clusterIP, and the chart refuses it: a client dials the Envoy "
            "Service by name (ADR-0092)"
        )
    return bad


FIXTURE_OVERLAY = """\
  envoy:
    service:
      type: NodePort
      httpsPort: 443
      nodePort: 443
      annotations: {}
  platformPostgres:
    persistence:
      storageClass: local-path
  networkPolicy:
    apiServerCIDRs:
      - "10.60.0.0/16"
      - "172.20.0.1/32"
"""
FIXTURE_NODE_INIT = "  --kube-apiserver-arg=service-node-port-range=80-32767 \\\n"
FIXTURE_TFVARS = 'environment = "staging"\n'


def write_fixture(d: pathlib.Path, overlay: str = FIXTURE_OVERLAY,
                  node_init: str = FIXTURE_NODE_INIT, tfvars: str = FIXTURE_TFVARS) -> None:
    for rel, body in ((OVERLAY, overlay), (NODE_INIT, node_init), (TFVARS, tfvars)):
        (d / rel).parent.mkdir(parents=True, exist_ok=True)
        (d / rel).write_text(body)


def selftest() -> int:
    def broken(msg: str) -> int:
        print(f"GUARD BROKEN: {msg}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        write_fixture(d)
        if offenders(d):
            return broken(f"a clean fixture was rejected: {offenders(d)}")

        cases = [
            ("a LoadBalancer edge", FIXTURE_OVERLAY.replace("type: NodePort", "type: LoadBalancer"),
             FIXTURE_NODE_INIT, "asks for a LoadBalancer"),
            ("a nodePort outside the range", FIXTURE_OVERLAY.replace("nodePort: 443", "nodePort: 79"),
             FIXTURE_NODE_INIT, "outside the range"),
            ("a cloud annotation", FIXTURE_OVERLAY.replace(
                "annotations: {}",
                "annotations:\n        service.beta.kubernetes.io/aws-load-balancer-type: external"),
             FIXTURE_NODE_INIT, "carries the cloud annotation"),
            ("a pinned ClusterIP",
             FIXTURE_OVERLAY.replace("nodePort: 443\n", 'nodePort: 443\n      clusterIP: "172.20.0.250"\n'),
             FIXTURE_NODE_INIT, "pins the ClusterIP"),
            ("k3s with no port range", FIXTURE_OVERLAY,
             "  --disable servicelb \\\n", "no service-node-port-range"),
            ("an API range from another estate",
             FIXTURE_OVERLAY.replace('"10.60.0.0/16"', '"10.40.0.0/16"'),
             FIXTURE_NODE_INIT, "does not contain this estate"),
            ("no API range at all",
             FIXTURE_OVERLAY.replace("  networkPolicy:\n    apiServerCIDRs:\n      - \"10.60.0.0/16\"\n      - \"172.20.0.1/32\"\n", ""),
             FIXTURE_NODE_INIT, "names no global.networkPolicy.apiServerCIDRs"),
            ("a cloud storage class",
             FIXTURE_OVERLAY.replace("storageClass: local-path", "storageClass: gp3"),
             FIXTURE_NODE_INIT, "which this cluster does not have"),
        ]
        for name, overlay, node_init, want in cases:
            write_fixture(d, overlay=overlay, node_init=node_init)
            got = offenders(d)
            if not any(want in g for g in got):
                return broken(f"{name} was accepted (got {got})")

        write_fixture(d)
        (d / OVERLAY).unlink()
        if not any(g.startswith("GUARD BROKEN") for g in offenders(d)):
            return broken("a missing overlay was not reported as a broken guard")

    print("✅ self-test: a LoadBalancer edge, a nodePort out of range, a cloud annotation, "
          "a pinned ClusterIP and a missing port range are all rejected")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    bad = offenders(ROOT)
    if any(b.startswith("GUARD BROKEN") for b in bad):
        for b in bad:
            print(b, file=sys.stderr)
        return 2
    if bad:
        print("❌ the staging edge cannot work on the cluster staging runs (ADR-0095):")
        for b in bad:
            print("   ", b)
        return 1
    print("✅ the staging edge is a NodePort in range, with no cloud annotation, "
          "and it pins no ClusterIP")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
