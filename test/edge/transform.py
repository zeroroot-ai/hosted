#!/usr/bin/env python3
"""transform.py — turn the RENDERED chart into what the edge harness runs.

The edge harness (test/edge/harness.sh) runs the chart's own Envoy bootstrap
and the chart's own ratelimit config under Docker, with no cluster. Two things
in the render only exist inside a cluster, and this script substitutes
EXACTLY those, prints every substitution it made, and touches nothing else:

  1. The `${DASHBOARD_CLIENT_ID}` placeholder that the render-envoy-config
     init container fills from a Secret at pod start.
  2. The ratelimit_grpc cluster's transport. In the cluster it is SPIFFE mTLS
     from SPIRE SDS, terminated by the ratelimit pod's Envoy sidecar. Under
     Docker there is no SPIRE, so the cluster dials the ratelimit container's
     plaintext gRPC port directly. The filter, its fail-open setting, the
     route actions, the domain and every quota are the rendered bytes.

Everything it emits is derived from the render, so the harness cannot drift
from the chart: the ratelimit container's environment is the Deployment's
environment, the config file is the ConfigMap's, the image is the values'.

Usage: transform.py <rendered-manifests.yaml> <outdir>
Writes: <outdir>/envoy.yaml, <outdir>/ratelimit/config/config.yaml,
        <outdir>/ratelimit.env, <outdir>/harness.json (incl. waf_image: the
        Edge WAF module image the harness copies /plugin.wasm out of)
"""
from __future__ import annotations

import json
import pathlib
import sys

import yaml

PLACEHOLDER = "${DASHBOARD_CLIENT_ID}"


def admin_probe_port(envoy) -> int:
    """The port the harness reaches Envoy's admin surface on.

    Since charts#139 the admin interface binds loopback (127.0.0.1:9902) and a
    listener named `admin_probe` on the pod address forwards exactly /ready
    and /stats/prometheus to it. That listener IS the pod-IP admin surface by
    contract (charts scripts/check-envoy-admin-loopback.py holds it to those
    two paths), so the harness reads its port, never the admin block's: the
    admin block's port answers nothing from another container.
    """
    listeners = envoy["static_resources"]["listeners"]
    probe = [l for l in listeners if l.get("name") == "admin_probe"]
    assert len(probe) == 1, (
        "expected exactly one listener named admin_probe (the pod-IP /ready "
        f"surface, charts#139), got {len(probe)}: {[l.get('name') for l in listeners]}"
    )
    return probe[0]["address"]["socket_address"]["port_value"]


def one(docs, kind, name):
    m = [d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name]
    assert len(m) == 1, f"expected exactly one {kind}/{name}, got {len(m)}"
    return m[0]


def main(src: str, out: str) -> int:
    outdir = pathlib.Path(out)
    (outdir / "ratelimit" / "config").mkdir(parents=True, exist_ok=True)
    docs = [d for d in yaml.safe_load_all(open(src)) if d]
    changes: list[str] = []

    # --- edge bootstrap ---
    raw = one(docs, "ConfigMap", "gibson-envoy")["data"]["envoy.yaml"]
    assert PLACEHOLDER in raw, "render no longer carries the client_id placeholder; update this script"
    raw = raw.replace(PLACEHOLDER, "harness-client-id")
    changes.append(f"substituted {PLACEHOLDER} -> harness-client-id")
    envoy = yaml.safe_load(raw)

    dep = one(docs, "Deployment", "gibson-ratelimit")
    rlc = [c for c in dep["spec"]["template"]["spec"]["containers"] if c["name"] == "ratelimit"][0]
    env = {e["name"]: e.get("value") for e in rlc["env"] if "value" in e}
    local_port = int(env["GRPC_PORT"])

    clusters = [c for c in envoy["static_resources"]["clusters"] if c["name"] == "ratelimit_grpc"]
    assert len(clusters) == 1, "no ratelimit_grpc cluster in the render"
    c = clusters[0]
    assert "transport_socket" in c, "ratelimit_grpc has no transport_socket — the render is not mTLS; refusing to run"
    del c["transport_socket"]
    sa = c["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]["address"]["socket_address"]
    changes.append(f"ratelimit_grpc: dropped SPIFFE mTLS transport (no SPIRE under Docker); {sa['address']}:{sa['port_value']} -> gibson-ratelimit:{local_port} plaintext")
    sa["address"], sa["port_value"] = "gibson-ratelimit", local_port

    (outdir / "envoy.yaml").write_text(yaml.safe_dump(envoy, sort_keys=False))

    # --- ratelimit config + environment, verbatim from the render ---
    cm = one(docs, "ConfigMap", "gibson-ratelimit-config")
    (outdir / "ratelimit" / "config" / "config.yaml").write_text(cm["data"]["config.yaml"])
    # Under Docker there is no sidecar; the Docker network is the boundary.
    env["GRPC_HOST"] = "0.0.0.0"
    changes.append("ratelimit env: GRPC_HOST 127.0.0.1 -> 0.0.0.0 (no sidecar under Docker)")
    # The render reads REDIS_AUTH from a Secret. The env file holds no
    # password: harness.sh passes REDIS_AUTH from its own environment
    # (docker run -e REDIS_AUTH), so the password is never on disk.
    from_secret = [e for e in rlc["env"] if e["name"] == "REDIS_AUTH" and "secretKeyRef" in e.get("valueFrom", {})]
    assert len(from_secret) == 1, "the ratelimit container no longer reads REDIS_AUTH from a Secret; update this script and harness.sh"
    changes.append("ratelimit env: REDIS_AUTH from the Secret -> the harness password, passed by harness.sh from its environment")
    (outdir / "ratelimit.env").write_text("".join(f"{k}={v}\n" for k, v in env.items()))

    # --- what the harness needs to know ---
    dash = [c for c in envoy["static_resources"]["clusters"] if c["name"] == "gibson_dashboard"][0]
    dsa = dash["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]["address"]["socket_address"]
    public = None
    for l in envoy["static_resources"]["listeners"]:
        for fc in l["filter_chains"]:
            names = fc.get("filter_chain_match", {}).get("server_names", [])
            if any(n.startswith("app.") for n in names):
                public = [n for n in names if n.startswith("app.")][0]
    assert public, "no app. SNI chain in the render"
    envoy_dep = one(docs, "Deployment", "gibson-envoy")
    waf_init = [c for c in envoy_dep["spec"]["template"]["spec"]["initContainers"] if c["name"] == "copy-coraza-wasm"]
    assert len(waf_init) == 1, "no copy-coraza-wasm init container in the render"
    # Upstreams the exit tests reach through the edge; the harness runs ONE
    # stub answering 200 on each (host, port), aliased on the Docker network.
    stubs = []
    for c in envoy["static_resources"]["clusters"]:
        if c["name"] in ("gibson_dashboard", "gibson_native_login", "zitadel_upstream"):
            a = c["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"]["address"]["socket_address"]
            stubs.append([a["address"], a["port_value"]])
    api = None
    for l in envoy["static_resources"]["listeners"]:
        for fc in l["filter_chains"]:
            for n in fc.get("filter_chain_match", {}).get("server_names", []):
                if n.startswith("api."):
                    api = n
    assert api, "no api. SNI chain in the render"
    info = {
        "waf_image": waf_init[0]["image"],
        "stub_endpoints": stubs,
        "api_host": api,
        "ratelimit_image": rlc["image"],
        "ratelimit_grpc_port": local_port,
        "redis_host": env["REDIS_URL"].split(":")[0],
        "redis_port": int(env["REDIS_URL"].split(":")[1]),
        "dashboard_host": dsa["address"],
        "dashboard_port": dsa["port_value"],
        "app_host": public,
        "edge_port": envoy["static_resources"]["listeners"][0]["address"]["socket_address"]["port_value"],
        "admin_port": admin_probe_port(envoy),
        "changes": changes,
    }
    (outdir / "harness.json").write_text(json.dumps(info, indent=2))
    for ch in changes:
        print("transform:", ch)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
