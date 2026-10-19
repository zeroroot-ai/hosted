#!/usr/bin/env python3
"""check-secret-contract.py: hosted vendors the chart's secret contract and reads it both ways.

The secret contract describes the chart, so the one source lives in
zeroroot-ai/charts at `helm/gibson/secret-contract.yaml` (charts#433,
charts#472, hosted#422). charts runs the full check against its own golden
renders. Each release of the umbrella chart ships the file, and hosted vendors
it at the staging pin: `vendor/charts/secret-contract.yaml` holds the bytes,
and `vendor/charts/secret-contract.version` names the release.
`scripts/vendor-secret-contract.sh` writes both, and promote-bump.yml runs it
on each staging promotion.

Six assertions:

  1. COPY. hosted has no `secret-contract.yaml` at its root. The hosted copy of
     old drifted from the chart and was a second source.
  2. VERSION. The vendored release is the staging pin. Chart releases before
     FIRST_RELEASE ship no contract, so while the staging pin is older the
     vendored release is FIRST_RELEASE.
  3. DRIFT. The vendored bytes equal `helm/gibson/secret-contract.yaml` at the
     tag `v<release>` of the charts checkout (`CHARTS_ROOT`). The guard fetches
     the tag when a shallow checkout lacks it.
  4. DECLARED. Each key that an ExternalSecret in `gitops/` reads from the
     platform secret store is a `secrets` entry of the vendored contract. A
     SaaS overlay chart counts as rendered with its CI fixture, and as
     rendered for each env Application that deploys it, with the value files
     of that Application (hosted#543). An
     ExternalSecret that reads through a namespaced SecretStore of this repo
     with the `kubernetes` provider reads a Kubernetes Secret by name, not a
     backend key, so it is out of scope. `gitops/unmanaged/` is not deployed.
  5. READ. The charts guard trusts a consumer in hosted (`gitops:` or
     `staging:`) and leaves the check to hosted. Each entry that names one has
     an ExternalSecret in `gitops/` that reads its key, or a line
     `read:<name> <reason>` in scripts/.secret-contract-exemptions.txt.
  6. STALE. An exemption that silences nothing fails, so the list cannot rot.

  check-secret-contract.py             exit 1 on a violation
  check-secret-contract.py --selftest  prove each assertion fails, then check the tree
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CONTRACT = "helm/gibson/secret-contract.yaml"
VENDORED = Path("vendor") / "charts" / "secret-contract.yaml"
VENDORED_VERSION = Path("vendor") / "charts" / "secret-contract.version"
STAGING_APP = Path("gitops") / "envs" / "staging" / "gibson.yaml"
OCI_REPO = "ghcr.io/zeroroot-ai/charts"
EXEMPTIONS = Path("scripts") / ".secret-contract-exemptions.txt"
# The first chart release that ships the contract. v0.137.0 has none.
FIRST_RELEASE = "0.138.0"
# The consumer prefixes that name a reader in this repo. The charts guard
# accepts them on trust (charts scripts/check-secret-contract.py, HOSTED).
HOSTED = ("gitops:", "staging:")


def semver(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in v.split("-")[0].split("."))


def load_exemptions(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        line = line.split("#")[0].strip()
        if line:
            spec, _, reason = line.partition(" ")
            out[spec] = reason.strip()
    return out


def staging_pin(root: Path) -> str:
    app = yaml.safe_load((root / STAGING_APP).read_text()) or {}
    pins = [s.get("targetRevision") for s in (app.get("spec") or {}).get("sources") or []
            if s.get("repoURL") == OCI_REPO and s.get("chart") == "gibson"]
    return str(pins[0]) if len(pins) == 1 else ""


def chart_contract_at(charts_root: Path, version: str) -> bytes | None:
    """The contract bytes at tag v<version> of the charts checkout, or None."""
    ref = f"v{version}:{CONTRACT}"

    def show():
        return subprocess.run(["git", "-C", str(charts_root), "show", ref],
                              capture_output=True, check=False)

    p = show()
    if p.returncode != 0:
        subprocess.run(["git", "-C", str(charts_root), "fetch", "--quiet", "--depth", "1", "origin",
                        f"refs/tags/v{version}:refs/tags/v{version}"],
                       capture_output=True, check=False)
        p = show()
    return p.stdout if p.returncode == 0 else None


def _docs(path: Path) -> list:
    try:
        return [d for d in yaml.safe_load_all(path.read_text(errors="replace")) if isinstance(d, dict)]
    except yaml.YAMLError:
        return []


OVERLAY_CHARTS = Path("gitops") / "saas-overlay"
OVERLAY_FIXTURE = Path("ci") / "values-saas-render-test.yaml"
ENV_APPS = Path("gitops") / "envs"


def _render(root: Path, where: Path, cdir: Path, files: list[Path]) -> list[tuple[Path, dict]]:
    cmd = ["helm", "template", cdir.name, str(cdir), "--namespace", "gibson"]
    for f in files:
        cmd += ["-f", str(f)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"::error::helm template {where.relative_to(root)} failed: {res.stderr.strip()[-800:]}")
        sys.exit(2)
    return [(where, d) for d in yaml.safe_load_all(res.stdout) if isinstance(d, dict)]


def _env_overlay_apps(root: Path) -> list[tuple[Path, Path, list[Path]]]:
    """(Application file, overlay chart dir, value files) for each env Application of an overlay chart.

    Argo renders an overlay chart with the value files of its Application, so
    an env may set another backend key than the CI fixture. `$values/` is the
    root of this repo (the `ref: values` source).
    """
    out = []
    for app in sorted((root / ENV_APPS).glob("*/apps/*.yaml")):
        for d in _docs(app):
            if d.get("kind") != "Application":
                continue
            for src in (d.get("spec") or {}).get("sources") or [(d.get("spec") or {}).get("source") or {}]:
                path = str(src.get("path") or "")
                if not path.startswith(str(OVERLAY_CHARTS) + "/"):
                    continue
                files = [root / str(f).replace("$values/", "", 1)
                         for f in (src.get("helm") or {}).get("valueFiles") or []]
                missing = [str(f.relative_to(root)) for f in files if not f.is_file()]
                if missing:
                    print(f"::error::{app.relative_to(root)} names value files that do not exist: {missing}")
                    sys.exit(2)
                out.append((app, root / path, files))
    return out


def _overlay_docs(root: Path) -> list[tuple[Path, dict]]:
    """The rendered objects of each SaaS overlay chart (hosted#440, hosted#543).

    A template is not YAML until Helm renders it, so a plain read of the chart
    directory sees no ExternalSecret in it. The billing overlay owns the
    reader of gibson-stripe-credentials as a template. Render each overlay
    chart with its CI fixture, as the overlay render tests do, and once for
    each env Application with the value files of that env, as Argo does.
    """
    out = []
    for chart in sorted((root / OVERLAY_CHARTS).glob("*/Chart.yaml")):
        cdir = chart.parent
        fixture = cdir / OVERLAY_FIXTURE
        out += _render(root, cdir, cdir, [fixture] if fixture.is_file() else [])
    for app, cdir, files in _env_overlay_apps(root):
        out += _render(root, app, cdir, files)
    return out


def _gitops_docs(root: Path) -> list[tuple[Path, dict]]:
    base = root / "gitops"
    if not base.is_dir():
        return []
    out = []
    for f in sorted(base.rglob("*.yaml")):
        if "unmanaged" in f.relative_to(base).parts:
            continue
        out.extend((f, d) for d in _docs(f))
    return out + _overlay_docs(root)


def _kubernetes_stores(docs: list[tuple[Path, dict]]) -> set[str]:
    out = set()
    for _, d in docs:
        if d.get("kind") != "SecretStore":
            continue
        if "kubernetes" in ((d.get("spec") or {}).get("provider") or {}):
            out.add((d.get("metadata") or {}).get("name") or "")
    return out


def backend_refs(root: Path) -> dict[str, set[str]]:
    """Backend key -> the gitops ExternalSecrets that read it."""
    docs = _gitops_docs(root)
    kube = _kubernetes_stores(docs)
    refs: dict[str, set[str]] = {}
    for f, d in docs:
        if d.get("kind") != "ExternalSecret":
            continue
        spec = d.get("spec") or {}
        store = spec.get("secretStoreRef") or {}
        if store.get("kind") == "SecretStore" and store.get("name") in kube:
            continue
        name = (d.get("metadata") or {}).get("name") or "<unnamed>"
        keys = [(e.get("remoteRef") or {}).get("key") for e in spec.get("data") or []]
        keys += [(e.get("extract") or {}).get("key") for e in spec.get("dataFrom") or []]
        for k in filter(None, keys):
            # A gitops key carries a path prefix (gibson/staging/arc-github-app).
            # The contract names the bare key.
            refs.setdefault(k.rsplit("/", 1)[-1], set()).add(f"{name} ({f.relative_to(root)})")
    return refs


def violations(root: Path, charts_root: Path) -> list[str]:
    fail = []
    if (root / "secret-contract.yaml").exists():
        fail.append("[copy] secret-contract.yaml is in hosted. The source is zeroroot-ai/charts "
                    f"{CONTRACT}, and hosted vendors it at {VENDORED}. Delete the root copy.")
    vendored, version_file = root / VENDORED, root / VENDORED_VERSION
    if not (vendored.is_file() and version_file.is_file()):
        fail.append(f"[vendor] no {VENDORED} and {VENDORED_VERSION}. "
                    "Run scripts/vendor-secret-contract.sh <staging pin>.")
        return fail
    version = version_file.read_text().strip()
    pin = staging_pin(root)
    if not pin:
        fail.append(f"[version] {STAGING_APP} has no single {OCI_REPO}/gibson pin")
        return fail
    want = pin if semver(pin) >= semver(FIRST_RELEASE) else FIRST_RELEASE
    if version != want:
        fail.append(f"[version] the vendored contract is of chart {version}, and the staging pin {pin} "
                    f"needs {want}. Run scripts/vendor-secret-contract.sh {want}.")
    chart = chart_contract_at(charts_root, version)
    if chart is None:
        fail.append(f"[drift] cannot read {CONTRACT} at tag v{version} in the charts checkout "
                    f"{charts_root}. Set CHARTS_ROOT to a git checkout of zeroroot-ai/charts.")
    elif chart != vendored.read_bytes():
        fail.append(f"[drift] {VENDORED} differs from charts {CONTRACT} at v{version}. "
                    f"Run scripts/vendor-secret-contract.sh {version}. Never edit the copy.")

    contract = yaml.safe_load(vendored.read_text()) or {}
    entries = [e for e in contract.get("secrets") or [] if isinstance(e, dict)]
    declared = {e.get("name") for e in entries}
    refs = backend_refs(root)
    for key, holders in sorted(refs.items()):
        if key not in declared:
            fail.append(f"[declared] {key}: read by {sorted(holders)} and not a secrets entry of the "
                        f"vendored contract (chart {version}). Declare it in charts first.")
    exempt = load_exemptions(root / EXEMPTIONS)
    used = set()
    for e in entries:
        mine = [str(c) for c in e.get("consumers") or [] if str(c).startswith(HOSTED)]
        if not mine or e.get("name") in refs:
            continue
        spec = f"read:{e.get('name')}"
        if spec in exempt:
            used.add(spec)
            continue
        fail.append(f"[read] {e.get('name')}: the contract names the hosted consumers {mine}, and no "
                    "ExternalSecret in gitops/ reads it. Add the reader, or correct the consumer in charts.")
    for spec in sorted(set(exempt) - used):
        fail.append(f"[stale] {spec}: the exemption silences nothing. Delete the line from {EXEMPTIONS}.")
    return fail


# ---------------------------------------------------------------- selftest ---

def _es(name: str, key: str, store: str = "gibson-secrets", kind: str = "ClusterSecretStore") -> str:
    return (
        "apiVersion: external-secrets.io/v1\nkind: ExternalSecret\n"
        f"metadata:\n  name: {name}\nspec:\n  secretStoreRef:\n    name: {store}\n    kind: {kind}\n"
        f"  data:\n    - secretKey: x\n      remoteRef:\n        key: {key}\n---\n"
    )


def _extract(name: str, key: str) -> str:
    return (
        "apiVersion: external-secrets.io/v1\nkind: ExternalSecret\n"
        f"metadata:\n  name: {name}\nspec:\n  secretStoreRef:\n    name: gibson-secrets\n"
        f"    kind: ClusterSecretStore\n  dataFrom:\n    - extract:\n        key: {key}\n---\n"
    )


KUBE_STORE = (
    "apiVersion: external-secrets.io/v1\nkind: SecretStore\n"
    "metadata:\n  name: in-cluster\nspec:\n  provider:\n    kubernetes:\n"
    "      remoteNamespace: gibson\n---\n"
)

CONTRACT_FIXTURE = yaml.safe_dump(
    {"secrets": [{"name": "declared-key", "consumers": ["gitops:reader"]},
                 {"name": "chart-only", "consumers": ["chart:x/y"]}],
     "operator_produced": [{"name": "minted"}]})


def _charts_repo(tmp: Path) -> Path:
    """A git repo with the contract at tags v0.138.0 and v0.140.0."""
    charts = tmp / "charts"
    (charts / CONTRACT).parent.mkdir(parents=True)

    def git(*a):
        subprocess.run(["git", "-C", str(charts), *a], check=True, capture_output=True)

    git("init", "-q")
    git("config", "user.email", "selftest@example.com")
    git("config", "user.name", "selftest")
    (charts / CONTRACT).write_text("# 0.138.0\n" + CONTRACT_FIXTURE)
    git("add", "-A")
    git("commit", "-qm", "a")
    git("tag", "v0.138.0")
    (charts / CONTRACT).write_text("# 0.140.0\n" + CONTRACT_FIXTURE)
    git("commit", "-qam", "b")
    git("tag", "v0.140.0")
    return charts


def _fixture(tmp: Path, charts: Path, gitops: str, *, pin: str = "0.140.0", version: str = "0.140.0",
             copy: bool = False, exempt: str = "", edit: bool = False, overlay: str = "",
             env_key: str = "") -> Path:
    root = tmp / "hosted"
    (root / STAGING_APP).parent.mkdir(parents=True)
    (root / "gitops" / "unmanaged").mkdir(parents=True)
    (root / STAGING_APP).write_text(yaml.safe_dump({"spec": {"sources": [
        {"repoURL": OCI_REPO, "chart": "gibson", "targetRevision": pin},
        {"repoURL": "https://github.com/zeroroot-ai/hosted", "targetRevision": "main"}]}}))
    (root / "gitops" / "envs" / "staging" / "es.yaml").write_text(gitops)
    (root / "gitops" / "unmanaged" / "es.yaml").write_text(_es("ignored", "not-deployed"))
    (root / VENDORED).parent.mkdir(parents=True)
    body = f"# {version}\n" + CONTRACT_FIXTURE + ("# edited\n" if edit else "")
    (root / VENDORED).write_text(body)
    (root / VENDORED_VERSION).write_text(version + "\n")
    if overlay:
        chart = root / OVERLAY_CHARTS / "fixture"
        (chart / "templates").mkdir(parents=True)
        (chart / "Chart.yaml").write_text("apiVersion: v2\nname: fixture\nversion: 0.1.0\n")
        # A template that is not YAML before Helm renders it.
        (chart / "templates" / "es.yaml").write_text("{{/* a template */}}\n" + overlay)
    if env_key:
        # An overlay chart whose backend key is a value: the CI fixture sets a
        # declared key, and the staging Application sets env_key.
        chart = root / OVERLAY_CHARTS / "valued"
        (chart / "templates").mkdir(parents=True)
        (chart / "ci").mkdir()
        (chart / "Chart.yaml").write_text("apiVersion: v2\nname: valued\nversion: 0.1.0\n")
        (chart / "templates" / "es.yaml").write_text(_es("valued", "{{ .Values.remoteKey }}"))
        (chart / OVERLAY_FIXTURE).write_text("remoteKey: declared-key\n")
        env = root / ENV_APPS / "staging"
        (env / "apps").mkdir(parents=True, exist_ok=True)
        (env / "saas-overlay-valued-values.yaml").write_text(f"remoteKey: {env_key}\n")
        (env / "apps" / "valued.yaml").write_text(yaml.safe_dump({
            "apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": {"name": "valued"},
            "spec": {"sources": [
                {"repoURL": "https://github.com/zeroroot-ai/hosted", "targetRevision": "main",
                 "path": str(OVERLAY_CHARTS / "valued"),
                 "helm": {"valueFiles": ["$values/gitops/envs/staging/saas-overlay-valued-values.yaml"]}},
                {"repoURL": "https://github.com/zeroroot-ai/hosted", "targetRevision": "main", "ref": "values"}]}}))
    if copy:
        (root / "secret-contract.yaml").write_text("secrets: []\n")
    if exempt:
        (root / EXEMPTIONS).parent.mkdir(parents=True, exist_ok=True)
        (root / EXEMPTIONS).write_text(exempt)
    return root


def selftest() -> int:
    import tempfile

    good = _es("good", "declared-key")
    cases = [
        ("a declared key with a path prefix passes",
         dict(gitops=_es("good", "gibson/staging/declared-key")), []),
        ("a declared key read through dataFrom.extract passes",
         dict(gitops=_extract("good", "gibson/staging/declared-key")), []),
        ("an undeclared key fails",
         dict(gitops=good + _es("rogue", "never-declared")), ["declared"]),
        ("an undeclared key read through dataFrom.extract fails",
         dict(gitops=good + _extract("rogue", "never-declared")), ["declared"]),
        ("an operator_produced name is not a backend key",
         dict(gitops=good + _es("opprod", "minted")), ["declared"]),
        ("a key read through a kubernetes SecretStore is out of scope",
         dict(gitops=good + KUBE_STORE + _es("k8s", "gibson-email-smtp", "in-cluster", "SecretStore")), []),
        ("a key read through a namespaced store that is not kubernetes is in scope",
         dict(gitops=good + _es("ns", "never-declared", "other", "SecretStore")), ["declared"]),
        ("a hosted root copy of the contract fails",
         dict(gitops=good, copy=True), ["copy"]),
        ("an entry with a gitops: consumer and no reader fails",
         dict(gitops=_es("other", "chart-only")), ["read"]),
        ("an exemption silences a missing reader",
         dict(gitops=_es("other", "chart-only"), exempt="read:declared-key tracked in hosted#1\n"), []),
        ("an exemption that silences nothing fails",
         dict(gitops=good, exempt="read:declared-key tracked in hosted#1\n"), ["stale"]),
        ("a reader in a SaaS overlay chart template counts once rendered",
         dict(gitops=_es("other", "chart-only"), overlay=_es("overlay", "declared-key")), []),
        ("an undeclared key in a SaaS overlay chart template fails",
         dict(gitops=good, overlay=_es("overlay", "never-declared")), ["declared"]),
        ("an overlay chart rendered with the values of an env reads a declared key",
         dict(gitops=good, env_key="declared-key"), []),
        ("an env that sets an undeclared key for an overlay chart fails",
         dict(gitops=good, env_key="never-declared"), ["declared"]),
        ("a hand edit of the vendored copy fails",
         dict(gitops=good, edit=True), ["drift"]),
        ("a vendored release that is not the staging pin fails",
         dict(gitops=good, pin="0.140.0", version="0.138.0"), ["version"]),
        ("a staging pin older than the first contract vendors the first release",
         dict(gitops=good, pin="0.136.8", version="0.138.0"), []),
        ("a release with no tag in charts fails",
         dict(gitops=good, pin="0.141.0", version="0.141.0"), ["drift"]),
    ]
    with tempfile.TemporaryDirectory() as d:
        charts = _charts_repo(Path(d))
        for i, (what, kw, want) in enumerate(cases):
            root = _fixture(Path(d) / str(i), charts, **kw)
            got = sorted({f.split("]")[0].lstrip("[") for f in violations(root, charts)})
            if got != want:
                print(f"SELFTEST FAIL: {what}: want {want}, got {got}")
                return 1
        root = _fixture(Path(d) / "none", charts, good)
        (root / VENDORED).unlink()
        if not any(f.startswith("[vendor]") for f in violations(root, charts)):
            print("SELFTEST FAIL: a tree with no vendored contract was accepted")
            return 1
    print(f"✅ self-test: {len(cases) + 1} planted cases give the expected result")
    return 0


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    charts_root = Path(os.environ.get("CHARTS_ROOT", ROOT.parent / "charts"))
    fail = violations(ROOT, charts_root)
    for f in fail:
        print("::error::" + f)
    if fail:
        return 1
    print(f"ok: {VENDORED} is the contract of the staging chart, each backend key that hosted reads "
          "is in it, and each hosted consumer it names has a reader")
    return 0


if __name__ == "__main__":
    sys.exit(main())
