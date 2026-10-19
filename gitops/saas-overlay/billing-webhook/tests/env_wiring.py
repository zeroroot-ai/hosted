#!/usr/bin/env python3
"""env_wiring.py: each env wires the billing service end to end (hosted#440).

The billing service crosses two charts. The core chart (zeroroot-ai/charts)
renders the edge routes, the daemon config, the dashboard texts and the OIDC
client from the env's values.yaml. The overlay chart in this repo renders the
billing pod. This check renders both from the env files and compares them.

For each env that deploys the billing overlay:

  1. TEXTS. The dashboard Deployment carries each approved text byte for byte
     (APPROVED below, from hosted#440, owner approval of 2026-10-05). The env
     sets no dashboard.billing value.
  2. ROUTES. The Envoy config has one exact-path route for each billing path,
     to the cluster of the overlay Service and port. Each env entry states the
     expected auth mode.
  3. DAEMON. The daemon gets the signup step URL on the app host, and the one
     signup step completer is the SPIFFE ID of the overlay ClusterSPIFFEID.
  4. SIGN-IN. The gibson-billing OIDC client redirects to the callback URL that
     the overlay pod uses, and its Secret is the one the overlay pod reads.
  5. OVERLAY. The overlay chart renders with the env files, as Argo renders it.
  6. EGRESS. The billing pod carries an egress-fqdn label and no
     egress-internet label (D76, hosted#525). The core chart renders the
     policy of that group from global.networkPolicy.egressHostGroups, and the
     policy opens the payment provider API, the sign-in issuer and the API
     host of the pod, each on 443.

The core chart is rendered from CHARTS_ROOT (charts main in CI): the values
must be right for the chart that the next pin brings. Only the keys this
check is about are taken from the env file, on top of the chart's baseline
render inputs, so an unrelated key of an older pin does not hide a result.

Usage: env_wiring.py <envs-dir>
Env:   CHARTS_ROOT  a checkout of zeroroot-ai/charts (default ../charts)
Exit:  0 each env is wired · 1 a mismatch · 2 could not render
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
CHART = HERE.parent
ROOT = CHART.parent.parent.parent
CHARTS_ROOT = Path(os.environ.get("CHARTS_ROOT") or (ROOT.parent / "charts")).resolve()

# The approved texts of hosted#440. Do not change a word.
APPROVED = {
    "DASHBOARD_ACCOUNT_LINK_LABEL": "Plan and payment",
    "DASHBOARD_SIGNUP_STEP_TITLE": "Payment details",
    "DASHBOARD_SIGNUP_STEP_TEXT": (
        "You add your payment details on a secure page from our payment provider. "
        "You return here after that."
    ),
    "DASHBOARD_SIGNUP_STEP_BUTTON_LABEL": "Continue",
    "DASHBOARD_SIGNUP_STEP_WAITING_TEXT": "We are confirming your payment details. This takes a few seconds.",
    "DASHBOARD_SIGNUP_STEP_FAILURE_TEXT": "We could not confirm your payment details. No account was created.",
    "DASHBOARD_SIGNUP_STEP_RETRY_LABEL": "Try again",
}

# path -> (auth mode, rewrite). The binary serves /webhook, /signup-step,
# /account and /account/callback (billing cmd/billing-webhook).
ROUTES = {
    "/api/billing/webhook": ("signed-request", "/webhook"),
    "/signup-step": ("query-token", None),
    "/account": ("own-sign-in", None),
    "/account/callback": ("own-sign-in", None),
}

SHOW = {
    "dashboard": "charts/gibson-workloads/templates/dashboard/deployment.yaml",
    "envoy": "charts/gibson-workloads/templates/envoy/configmap.yaml",
    "daemon": "charts/gibson-workloads/templates/gibson/statefulset.yaml",
    "bootstrap": "charts/gibson-operators/templates/platform-operator/platformbootstrap.yaml",
    "network": "templates/network-policies.yaml",
}

# The outside host that billing calls besides the hosts of the install: the
# API of the payment provider (billing internal/stripe).
PROVIDER_API = "api.stripe.com"
EGRESS_FQDN = "gibson.zeroroot.ai/egress-fqdn"
EGRESS_INTERNET = "gibson.zeroroot.ai/egress-internet"


def die(msg: str) -> None:
    print(f"::error::{msg}")
    sys.exit(2)


def dig(d, *keys, default=None):
    for k in keys:
        if not isinstance(d, dict) or k not in d:
            return default
        d = d[k]
    return d


def merge(a: dict, b: dict) -> dict:
    out = dict(a)
    for k, v in b.items():
        out[k] = merge(out[k], v) if isinstance(out.get(k), dict) and isinstance(v, dict) else v
    return out


def ensure_deps() -> None:
    umbrella = CHARTS_ROOT / "helm" / "gibson"
    if not (umbrella / "Chart.yaml").is_file():
        die(f"no chart at {umbrella}. Set CHARTS_ROOT to a checkout of zeroroot-ai/charts")
    if list((umbrella / "charts").glob("gibson-workloads-*.tgz")):
        return
    out = subprocess.run(["make", "-C", str(CHARTS_ROOT), "chart-deps"], capture_output=True, text=True)
    if out.returncode != 0:
        die(f"make chart-deps in {CHARTS_ROOT} failed:\n{out.stderr.strip()[-1500:]}")


def helm(args: list[str]) -> list[dict]:
    out = subprocess.run(["helm", "template", *args], capture_output=True, text=True)
    if out.returncode != 0:
        die(f"helm template {' '.join(args[:2])} failed:\n{out.stderr.strip()[-2000:]}")
    return [d for d in yaml.safe_load_all(out.stdout) if isinstance(d, dict)]


def env_of(container: dict) -> dict:
    return {e["name"]: e.get("value") for e in container.get("env") or [] if "value" in e}


def container(docs: list[dict], kind: str, name_part: str) -> dict:
    for d in docs:
        if d.get("kind") != kind:
            continue
        for c in dig(d, "spec", "template", "spec", "containers", default=[]) or []:
            if name_part in c.get("name", ""):
                return c
    return {}


def routes_of(node) -> list[dict]:
    """Every Envoy route object (a dict with match + route) in the config."""
    found = []
    if isinstance(node, dict):
        if isinstance(node.get("match"), dict) and isinstance(node.get("route"), dict):
            found.append(node)
        for v in node.values():
            found += routes_of(v)
    elif isinstance(node, list):
        for v in node:
            found += routes_of(v)
    return found


def cluster_names(node) -> set[str]:
    names = set()
    if isinstance(node, dict):
        clusters = node.get("clusters")
        if isinstance(clusters, list):
            names |= {c.get("name") for c in clusters if isinstance(c, dict)}
        for v in node.values():
            names |= cluster_names(v)
    elif isinstance(node, list):
        for v in node:
            names |= cluster_names(v)
    return names


def check_env(env_dir: Path, tmp: Path) -> list[str]:
    name = env_dir.name
    fail: list[str] = []
    umbrella = yaml.safe_load((env_dir / "values.yaml").read_text()) or {}
    overlay_env = yaml.safe_load((env_dir / "saas-overlay-billing-webhook-values.yaml").read_text()) or {}
    overlay = merge(yaml.safe_load((CHART / "values.yaml").read_text()) or {}, overlay_env)

    domain = dig(umbrella, "global", "domain")
    td = dig(umbrella, "global", "spire", "trustDomain")
    if not domain or not td:
        return [f"{name}: values.yaml sets no global.domain or global.spire.trustDomain"]
    app = f"https://app.{domain}"
    gw = umbrella.get("gibson-workloads") or {}

    if "billing" in (gw.get("dashboard") or {}):
        fail.append(f"{name}: gibson-workloads.dashboard.billing is set. The dashboard holds no Stripe value (charts#375)")

    # Only the keys this check is about, on top of the chart's render inputs.
    subset = {
        "global": {
            "domain": domain,
            "spire": {"trustDomain": td},
            "networkPolicy": {
                "egressHostGroups": dig(umbrella, "global", "networkPolicy", "egressHostGroups", default={}) or {}
            },
        },
        "gibson-workloads": {
            "dashboard": {k: gw.get("dashboard", {}).get(k) for k in ("accountLink", "signupStep")},
            "envoy": {"extraRoutes": dig(gw, "envoy", "extraRoutes", default=[])},
            "gibson": {"connectionPoints": dig(gw, "gibson", "connectionPoints", default={})},
        },
        "gibson-operators": {
            "platformBootstrap": {
                "oidcClients": dig(umbrella, "gibson-operators", "platformBootstrap", "oidcClients", default=[])
            }
        },
    }
    subset_file = tmp / f"{name}-subset.yaml"
    subset_file.write_text(yaml.safe_dump(subset))
    core = CHARTS_ROOT / "helm" / "gibson"
    base = [
        "billing", str(core), "--namespace", "gibson",
        "-f", str(CHARTS_ROOT / "helm" / "testdata" / "render-inputs" / "gibson.yaml"),
        "-f", str(core / "values-baseline.yaml"),
        "-f", str(subset_file),
    ]
    for show in SHOW.values():
        base += ["--show-only", show]
    docs = helm(base)

    # 1. TEXTS
    dash = env_of(container(docs, "Deployment", "dashboard"))
    for key, want in APPROVED.items():
        got = dash.get(key)
        if got != want:
            fail.append(f"{name}: {key} renders {got!r}, the approved text is {want!r}")
    if dash.get("DASHBOARD_ACCOUNT_URL") != f"{app}/account":
        fail.append(f"{name}: DASHBOARD_ACCOUNT_URL renders {dash.get('DASHBOARD_ACCOUNT_URL')!r}, want {app}/account")

    # 2. ROUTES
    entries = {r.get("path"): r for r in dig(gw, "envoy", "extraRoutes", default=[]) or []}
    svc, port = overlay.get("fullnameOverride"), overlay.get("port")
    want_cluster = f"extra_{svc.replace('-', '_')}_{port}"
    cm = next((d for d in docs if d.get("kind") == "ConfigMap" and "envoy.yaml" in (d.get("data") or {})), None)
    if cm is None:
        return fail + [f"{name}: the core chart rendered no Envoy ConfigMap"]
    envoy = yaml.safe_load(cm["data"]["envoy.yaml"])
    rendered = [r for r in routes_of(envoy) if "path" in r["match"]]
    if want_cluster not in cluster_names(envoy):
        fail.append(f"{name}: the Envoy config has no cluster {want_cluster} for {svc}:{port}")
    for path, (auth, rewrite) in ROUTES.items():
        e = entries.get(path)
        if e is None:
            fail.append(f"{name}: envoy.extraRoutes has no entry for {path}")
            continue
        if (e.get("service"), e.get("port")) != (svc, port):
            fail.append(f"{name}: {path} dials {e.get('service')}:{e.get('port')}, the overlay serves {svc}:{port}")
        if e.get("auth") != auth:
            fail.append(f"{name}: {path} states auth {e.get('auth')!r}, want {auth!r}")
        hits = [r for r in rendered if r["match"]["path"] == path]
        if len(hits) != 1:
            fail.append(f"{name}: the Envoy config has {len(hits)} routes for {path}, want 1")
            continue
        if hits[0]["route"].get("cluster") != want_cluster:
            fail.append(f"{name}: the route {path} goes to {hits[0]['route'].get('cluster')}, want {want_cluster}")
        if hits[0]["route"].get("prefix_rewrite") != rewrite:
            fail.append(f"{name}: the route {path} rewrites to {hits[0]['route'].get('prefix_rewrite')!r}, want {rewrite!r}")

    # 3. DAEMON
    completer = f"spiffe://{td}/{overlay['spiffe']['path'].lstrip('/')}"
    daemon = env_of(container(docs, "StatefulSet", "gibson"))
    if daemon.get("GIBSON_SIGNUP_STEP_URL") != f"{app}/signup-step":
        fail.append(f"{name}: GIBSON_SIGNUP_STEP_URL renders {daemon.get('GIBSON_SIGNUP_STEP_URL')!r}, want {app}/signup-step")
    if daemon.get("GIBSON_SIGNUP_STEP_COMPLETER_SVID") != completer:
        fail.append(f"{name}: GIBSON_SIGNUP_STEP_COMPLETER_SVID renders "
                    f"{daemon.get('GIBSON_SIGNUP_STEP_COMPLETER_SVID')!r}, the billing SPIFFE ID is {completer!r}")

    # 4. SIGN-IN
    callback = f"{app}{overlay['accountCallbackPath']}"
    pb = next((d for d in docs if d.get("kind") == "PlatformBootstrap"), {})
    client = [c for c in dig(pb, "spec", "oidcClients", default=[]) or [] if c.get("name") == "gibson-billing"]
    if len(client) != 1:
        fail.append(f"{name}: the PlatformBootstrap has {len(client)} gibson-billing OIDC clients, want 1")
    else:
        c = client[0]
        if c.get("redirectURIs") != [callback]:
            fail.append(f"{name}: gibson-billing redirects to {c.get('redirectURIs')}, the pod uses {callback}")
        if dig(c, "secretRef", "name") != overlay["oidc"]["secretName"]:
            fail.append(f"{name}: gibson-billing writes {dig(c, 'secretRef', 'name')}, the pod reads {overlay['oidc']['secretName']}")
        if c.get("applicationType") != "WEB":
            fail.append(f"{name}: gibson-billing is {c.get('applicationType')!r}, a sign-in client with a secret is WEB")

    # 5. OVERLAY, rendered the way the Application renders it.
    odocs = helm(["gibson-billing-webhook", str(CHART), "--namespace", "gibson",
                  "-f", str(env_dir / "values.yaml"),
                  "-f", str(env_dir / "saas-overlay-billing-webhook-values.yaml")])
    pod = env_of(container(odocs, "Deployment", "billing-webhook"))
    want_pod = {
        "BILLING_ACCOUNT_CALLBACK_URL": callback,
        "OIDC_ISSUER": app,
        "GIBSON_API_ADDR": f"api.{domain}:443",
    }
    for k, v in want_pod.items():
        if pod.get(k) != v:
            fail.append(f"{name}: the overlay pod sets {k}={pod.get(k)!r}, want {v!r}")
    ids = [dig(d, "spec", "spiffeIDTemplate") for d in odocs if d.get("kind") == "ClusterSPIFFEID"]
    if ids != [completer]:
        fail.append(f"{name}: the overlay ClusterSPIFFEID mints {ids}, the daemon accepts {completer!r}")

    # 6. EGRESS
    dep = next((d for d in odocs if d.get("kind") == "Deployment"), {})
    labels = dig(dep, "spec", "template", "metadata", "labels", default={}) or {}
    if EGRESS_INTERNET in labels:
        fail.append(f"{name}: the billing pod carries {EGRESS_INTERNET}. It reaches named hosts only (D76, hosted#525)")
    group = labels.get(EGRESS_FQDN)
    if not group:
        return fail + [f"{name}: the billing pod carries no {EGRESS_FQDN} label, so it reaches no outside host"]
    pols = [d for d in docs if d.get("kind") == "CiliumNetworkPolicy"
            and dig(d, "spec", "endpointSelector", "matchLabels", default={}) == {EGRESS_FQDN: group}]
    if len(pols) != 1:
        return fail + [f"{name}: the core chart renders {len(pols)} policies for the egress group {group!r}, want 1. "
                       f"Set global.networkPolicy.egressHostGroups.{group} in values.yaml"]
    opened = set()
    for rule in dig(pols[0], "spec", "egress", default=[]) or []:
        ports = {p.get("port") for tp in rule.get("toPorts") or [] for p in tp.get("ports") or []}
        for f in rule.get("toFQDNs") or []:
            opened |= {(f.get("matchName"), p) for p in ports}
    issuer = pod.get("OIDC_ISSUER") or ""
    api = (pod.get("GIBSON_API_ADDR") or "").rsplit(":", 1)[0]
    for host in (PROVIDER_API, issuer.split("://", 1)[-1].split("/", 1)[0], api):
        if (host, "443") not in opened:
            fail.append(f"{name}: the egress group {group!r} does not open {host}:443, which the billing pod calls")
    return fail


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    envs = sorted(p.parent for p in Path(sys.argv[1]).glob("*/saas-overlay-billing-webhook-values.yaml"))
    if not envs:
        die(f"no env under {sys.argv[1]} deploys the billing overlay: this check is blind")
    ensure_deps()
    fail: list[str] = []
    with tempfile.TemporaryDirectory() as d:
        for env_dir in envs:
            fail += check_env(env_dir, Path(d))
    for f in fail:
        print(f"::error::{f}")
    if fail:
        return 1
    print(f"OK billing wiring: {', '.join(e.name for e in envs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
