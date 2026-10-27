#!/usr/bin/env python3
"""check-env-renders-at-pin.py — each cloud env renders with the chart it pins.

Argo renders the gibson Application of an env from two sources: the umbrella
chart at the version that gitops/envs/<env>/gibson.yaml pins, and the values
of gitops/envs/<env>/values.yaml on hosted `main`. A values change that needs
a newer chart merges green when the checks render charts `main`, and the env
then fails its render on the next bringup (hosted#574):

  * hosted#565 set `auth: query-token` on an extra route. charts 0.142.0
    refuses that mode, so the gibson render of each env failed.
  * hosted#558 moved the billing pod of the SaaS overlay to the egress host
    group `billing`. The group policy comes from a chart that the pin did
    not hold, so the pod had no egress rule at all, and the render passed.

For every env whose `RECREATE_UP_<env>` in the Makefile runs recreate-aws.sh
or recreate-ec2.sh, this guard:

  1. gets the umbrella chart at the pinned version and runs `helm template`
     with the env values file, as Argo does. A render error fails.
  2. renders each SaaS overlay Application of the env
     (gitops/envs/<env>/apps/*.yaml, a source with a path under
     gitops/saas-overlay/) with its value files. A render error fails.
  3. reads the label gibson.zeroroot.ai/egress-fqdn of each pod template
     that an overlay renders. The core render at the pin must hold a Cilium
     policy that selects that group. A group with no policy fails: the pod
     would reach no outside host.
  4. reads the API group and the namespace of each object of the core
     render, of each SaaS overlay render, and of each other Application of
     the env that names a chart of the same repo at its own pin (hosted#622). Argo CD of the env must manage each group, permit each
     namespace and whitelist each cluster-scoped kind: the lists of
     bootstrap/modules/argocd plus the argocd_extra_* lists of the env
     tfvars. A group outside the list is
     dropped in silence, and a namespace outside it fails the whole sync
     (hosted#618, and the ESO generators of charts#602 on 2026-10-12).

  5. reads the OpenBao StatefulSet of the core render. The restore makes the
     TLS volumes of the RESTORED pod optional (scripts/lib/velero-restore.sh,
     OPENBAO_TLS_VOLUMES). Each volume it names must exist in the render,
     mount the Secret it names, and be required. A renamed volume would make
     the restore patch nothing. An optional one would let OpenBao start with
     an empty TLS directory on a normal install.

  6. reads the Reloader Deployment and Role of the core render: the account
     Reloader writes as, and the Deployments and StatefulSets it may patch.
     Each ValidatingAdmissionPolicy of the core and overlay renders that
     matches an UPDATE of such a kind in the release namespace must admit a
     restart-only UPDATE by that account: a variable restartOnly that names
     the account and compares the old and new pod template spec, used by a
     validation. Reloader v1.4.6 stops its whole pass on the first refused
     update, so one policy without it stopped the restart of every consumer
     of a rotated Secret (drill rotation run 40478619844, hosted#162). The
     check fails closed: a policy counts unless each of its bindings
     provably leaves the release namespace out (a name selector that does
     not hold it), or a match condition of a known shape does
     (request.namespace.startsWith('x') or .matches('re'), alone or as one
     term of an &&). An unknown selector or condition counts.
The chart comes from oci://ghcr.io/zeroroot-ai/charts/gibson with `helm pull`,
which needs no login. CHART_TGZ_DIR names a directory that already holds
gibson-<version>.tgz, for a run with no network.

Run:  scripts/check-env-renders-at-pin.py
"""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "gitops" / "envs"
MAKEFILE = ROOT / "Makefile"
OCI_REPO = "ghcr.io/zeroroot-ai/charts"
CHART = "gibson"
GROUP_LABEL = "gibson.zeroroot.ai/egress-fqdn"
OVERLAY_DIR = "gitops/saas-overlay/"
POD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}


def overlay_envs(makefile_text: str) -> list[str]:
    envs = re.findall(
        r"^RECREATE_UP_(\w+)\s*:=\s*scripts/recreate-(?:aws|ec2)\.sh", makefile_text, re.M)
    return sorted(set(envs))


def pinned_version(app_text: str) -> str | None:
    """The targetRevision of the umbrella source of the gibson Application."""
    doc = yaml.safe_load(app_text) or {}
    for src in ((doc.get("spec") or {}).get("sources") or []):
        if src.get("repoURL") == OCI_REPO and src.get("chart") == CHART:
            return str(src.get("targetRevision") or "") or None
    return None


def overlay_sources(app_text: str) -> list[tuple[str, list[str]]]:
    """(chart path, value files) of each SaaS overlay source of an Application.
    A value file `$values/<path>` is a path from the repo root."""
    doc = yaml.safe_load(app_text) or {}
    out = []
    for src in ((doc.get("spec") or {}).get("sources") or []):
        path = str(src.get("path") or "")
        if not path.startswith(OVERLAY_DIR):
            continue
        files = [str(f).removeprefix("$values/")
                 for f in ((src.get("helm") or {}).get("valueFiles") or [])]
        out.append((path, files))
    return out


def chart_apps(app_text: str) -> list[dict]:
    """Each source of an Application that names a chart of OCI_REPO other than
    the umbrella: chart, version, value files (paths from the repo root), the
    inline valuesObject, the release and the destination namespace."""
    doc = yaml.safe_load(app_text) or {}
    spec = doc.get("spec") or {}
    ns = str((spec.get("destination") or {}).get("namespace") or "")
    name = str((doc.get("metadata") or {}).get("name") or "")
    out = []
    for src in (spec.get("sources") or ([spec["source"]] if spec.get("source") else [])):
        if src.get("repoURL") != OCI_REPO or not src.get("chart") or src.get("chart") == CHART:
            continue
        helm = src.get("helm") or {}
        out.append({
            "chart": str(src["chart"]), "version": str(src.get("targetRevision") or ""),
            "files": [str(f).removeprefix("$values/") for f in (helm.get("valueFiles") or [])],
            "object": helm.get("valuesObject") or {}, "release": name or str(src["chart"]),
            "namespace": ns,
        })
    return out


def fetch(version: str, dest: pathlib.Path, chart: str = CHART) -> pathlib.Path:
    tgz = dest / ("%s-%s.tgz" % (chart, version))
    if tgz.is_file():
        return tgz
    local = os.environ.get("CHART_TGZ_DIR")
    if local:
        src = pathlib.Path(local) / tgz.name
        if not src.is_file():
            raise RuntimeError("CHART_TGZ_DIR holds no %s" % tgz.name)
        return src
    res = subprocess.run(
        ["helm", "pull", "oci://%s/%s" % (OCI_REPO, chart), "--version", version,
         "--destination", str(dest)], capture_output=True, text=True, check=False)
    if res.returncode != 0:
        raise RuntimeError("helm pull %s %s failed: %s" % (chart, version, res.stderr.strip()[-400:]))
    return tgz


def render(chart: pathlib.Path, value_files: list[pathlib.Path],
           namespace: str = "gibson", release: str = "gibson") -> tuple[list[dict], str | None]:
    """The documents of `helm template`, or the error line of a failed render."""
    cmd = ["helm", "template", release, str(chart), "--namespace", namespace]
    for f in value_files:
        cmd += ["-f", str(f)]
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        lines = [l for l in res.stderr.splitlines() if l.startswith("Error")] or res.stderr.splitlines()[-1:]
        return [], (lines[0] if lines else "helm template exit %d" % res.returncode)[:600]
    return [d for d in yaml.safe_load_all(res.stdout) if isinstance(d, dict)], None


def policy_groups(docs: list[dict]) -> set[str]:
    """The egress host groups that a Cilium policy of the render selects."""
    groups = set()
    for d in docs:
        if not str(d.get("kind", "")).startswith("Cilium"):
            continue
        spec = d.get("spec") or {}
        for s in [spec] + list(d.get("specs") or []):
            sel = ((s or {}).get("endpointSelector") or {}).get("matchLabels") or {}
            if GROUP_LABEL in sel:
                groups.add(str(sel[GROUP_LABEL]))
    return groups


def pod_groups(docs: list[dict]) -> list[tuple[str, str]]:
    """(workload name, group) for each pod template with a group label."""
    out = []
    for d in docs:
        if d.get("kind") not in POD_KINDS:
            continue
        spec = d.get("spec") or {}
        if d["kind"] == "CronJob":
            spec = ((spec.get("jobTemplate") or {}).get("spec") or {})
        labels = (((spec.get("template") or {}).get("metadata") or {}).get("labels") or {})
        if GROUP_LABEL in labels:
            out.append(("%s/%s" % (d["kind"], (d.get("metadata") or {}).get("name")), str(labels[GROUP_LABEL])))
    return out


def group_failures(env: str, version: str, core: list[dict], overlay: list[dict]) -> list[str]:
    have = policy_groups(core)
    return ["%s: the SaaS overlay pod %s carries egress group %r, and the chart %s that %s pins "
            "renders no policy for it. The pod would reach no outside host. Move the pin to a "
            "chart that renders the group, or keep the old label until the pin moves."
            % (env, name, g, version, env)
            for name, g in pod_groups(overlay) if g not in have]


ARGOCD_MODULE = ROOT / "bootstrap" / "modules" / "argocd"
# The groups the module manages outside argocd_controller_platform_api_groups:
# the core group and rbac (controller-rbac.tf, resource inclusions).
ARGOCD_FIXED_GROUPS = {"", "rbac.authorization.k8s.io"}


VELERO_RESTORE = ROOT / "scripts" / "lib" / "velero-restore.sh"


def restore_tls_volumes(text: str) -> tuple[str, list[str]]:
    """The Secret and the volume names that the restore makes optional."""
    secret = re.search(r'^OPENBAO_TLS_SECRET="([^"]+)"', text, re.M)
    vols = re.search(r'^OPENBAO_TLS_VOLUMES="([^"]+)"', text, re.M)
    return (secret.group(1) if secret else "", vols.group(1).split() if vols else [])


def openbao_tls_failures(env: str, version: str, docs: list[dict], secret: str, vols: list[str]) -> list[str]:
    if not secret or not vols:
        return ["%s: no OPENBAO_TLS_SECRET or OPENBAO_TLS_VOLUMES in %s, so step 5 checked nothing"
                % (env, VELERO_RESTORE.relative_to(ROOT))]
    sts = [d for d in docs if d.get("kind") == "StatefulSet"
           and (d.get("metadata") or {}).get("name") == "gibson-openbao"]
    if len(sts) != 1:
        return ["%s: the render at %s has %d StatefulSet gibson-openbao, not one" % (env, version, len(sts))]
    have = {v.get("name"): v for v in
            ((((sts[0].get("spec") or {}).get("template") or {}).get("spec") or {}).get("volumes") or [])}
    out = []
    for name in vols:
        v = have.get(name)
        src = (v or {}).get("secret") or {}
        if v is None:
            out.append("%s: the OpenBao pod at %s has no volume %s, so the restore patches nothing and "
                       "the restored pod waits on Secret %s" % (env, version, name, secret))
        elif src.get("secretName") != secret:
            out.append("%s: volume %s of the OpenBao pod at %s mounts %r, not Secret %s"
                       % (env, name, version, src.get("secretName"), secret))
        elif src.get("optional"):
            out.append("%s: volume %s of the OpenBao pod at %s is optional in a normal render. Only the "
                       "restored pod may start without its TLS Secret" % (env, name, version))
    return out


def tf_list(text: str, name: str) -> list[str]:
    """The quoted strings of the first `name = [ ... ]` (or concat([ ... ])) of a Terraform text."""
    text = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
    m = re.search(r"\b" + re.escape(name) + r"\s*=\s*(?:concat\(\s*)?\[(.*?)\]", text, re.S)
    return re.findall(r'"([^"]+)"', m.group(1)) if m else []


def env_tfvars(env: str, makefile_text: str) -> pathlib.Path | None:
    m = re.search(r"^RECREATE_UP_" + re.escape(env) + r"\s*:=\s*scripts/recreate-(aws|ec2)\.sh",
                  makefile_text, re.M)
    if not m:
        return None
    root = "eks" if m.group(1) == "aws" else "ec2"
    return ROOT / "bootstrap" / root / "gibson" / "envs" / ("%s.tfvars" % env)


# Cluster-scoped kinds that a chart renders. A doc of one of these kinds must
# be on the project clusterResourceWhitelist (appprojects.tf), or the sync of
# the whole app fails "is not permitted in project".
CLUSTER_KINDS = {
    "Namespace", "CustomResourceDefinition", "ClusterRole", "ClusterRoleBinding",
    "MutatingWebhookConfiguration", "ValidatingWebhookConfiguration",
    "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding", "PriorityClass",
    "CSIDriver", "StorageClass", "RuntimeClass", "ClusterIssuer", "ClusterSecretStore",
    "ClusterSPIFFEID", "CiliumClusterwideNetworkPolicy", "PlatformBootstrap", "SandboxClass",
}


def tf_pairs(text: str) -> set[str]:
    """Each `{ group = "g", kind = "K" }` of a Terraform text, as g/K."""
    text = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
    return {"%s/%s" % gk for gk in re.findall(r'group\s*=\s*"([^"]*)"\s*,\s*kind\s*=\s*"([^"]*)"', text)}


def cluster_whitelist(module: pathlib.Path, tfvars_text: str) -> set[str]:
    projects = (module / "appprojects.tf").read_text(encoding="utf-8")
    m = re.search(r"argocd_baseline_cluster_resources\s*=\s*\[(.*?)^\s*\]", projects, re.S | re.M)
    base = tf_pairs(m.group(1)) if m else set()
    m = re.search(r"argocd_extra_cluster_resources\s*=\s*\[(.*?)^\s*\]", tfvars_text, re.S | re.M)
    return base | (tf_pairs(m.group(1)) if m else set())


# Built-in kinds that live in a namespace. A chart may render one with no
# metadata.namespace: Helm and Argo put it in the release namespace.
NAMESPACED_KINDS = {
    "ConfigMap", "Secret", "Service", "ServiceAccount", "Pod", "Endpoints",
    "PersistentVolumeClaim", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet",
    "Job", "CronJob", "Role", "RoleBinding", "NetworkPolicy", "PodDisruptionBudget",
    "Ingress", "HorizontalPodAutoscaler", "LimitRange", "ResourceQuota", "Lease",
}


def kind_scopes(docs: list[dict]) -> tuple[set[str], set[str]]:
    """(cluster kinds, namespaced kinds): the fixed sets plus the spec.scope of
    each CustomResourceDefinition of the same render."""
    cluster, namespaced = set(CLUSTER_KINDS), set(NAMESPACED_KINDS)
    for d in docs:
        if d.get("kind") != "CustomResourceDefinition":
            continue
        spec = d.get("spec") or {}
        kind = (spec.get("names") or {}).get("kind")
        if kind:
            (cluster if spec.get("scope") == "Cluster" else namespaced).add(kind)
    return cluster, namespaced


def whitelist_failures(env: str, version: str, docs: list[dict], allowed: set[str]) -> list[str]:
    cluster, namespaced = kind_scopes(docs)
    out, seen = [], set()
    for d in docs:
        kind = d.get("kind")
        if (d.get("metadata") or {}).get("namespace") or kind in namespaced:
            continue
        api = str(d.get("apiVersion") or "")
        key = "%s/%s" % (api.split("/", 1)[0] if "/" in api else "", kind)
        if key in seen:
            continue
        seen.add(key)
        if kind not in cluster:
            out.append("%s: the chart %s renders %s with no namespace, and this check does not know "
                       "whether the kind is cluster-scoped. Add it to CLUSTER_KINDS or NAMESPACED_KINDS "
                       "of scripts/check-env-renders-at-pin.py, so the project whitelist is checked for it"
                       % (env, version, key))
        elif key not in allowed:
            out.append("%s: the chart %s renders the cluster-scoped %s, and it is not on the Argo CD "
                       "project whitelist of %s. The whole gibson sync fails. Add it to "
                       "argocd_baseline_cluster_resources or to argocd_extra_cluster_resources"
                       % (env, version, key, env))
    return out


def argocd_scope(module: pathlib.Path, tfvars_text: str) -> tuple[set[str], set[str]]:
    rbac = (module / "controller-rbac.tf").read_text(encoding="utf-8")
    projects = (module / "appprojects.tf").read_text(encoding="utf-8")
    groups = set(tf_list(rbac, "argocd_controller_platform_api_groups")) | ARGOCD_FIXED_GROUPS
    groups |= set(tf_list(tfvars_text, "argocd_extra_managed_api_groups"))
    namespaces = set(tf_list(projects, "argocd_platform_namespaces"))
    namespaces |= set(tf_list(tfvars_text, "argocd_extra_platform_namespaces"))
    return groups, namespaces


def scope_failures(env: str, version: str, docs: list[dict], groups: set[str],
                   namespaces: set[str]) -> list[str]:
    out = []
    seen_g: set[str] = set()
    seen_n: set[str] = set()
    for d in docs:
        api = str(d.get("apiVersion") or "")
        group = api.split("/", 1)[0] if "/" in api else ""
        if group not in groups and group not in seen_g:
            seen_g.add(group)
            out.append("%s: the chart %s renders %s (%s), and Argo CD of %s does not manage the API "
                       "group %r. The controller drops it in silence. Add the group to "
                       "bootstrap/modules/argocd (every env renders it) or to "
                       "argocd_extra_managed_api_groups of the env tfvars"
                       % (env, version, d.get("kind"), api, env, group))
        ns = ((d.get("metadata") or {}).get("namespace"))
        if ns and ns not in namespaces and ns not in seen_n:
            seen_n.add(ns)
            out.append("%s: the chart %s renders %s/%s into namespace %r, and the Argo CD project of %s "
                       "does not permit it. The whole gibson sync fails. Add the namespace to "
                       "argocd_extra_platform_namespaces of the env tfvars"
                       % (env, version, d.get("kind"), (d.get("metadata") or {}).get("name"), ns, env))
    return out


def renders_scope_failures(env: str, renders: list[tuple[str, str, list[dict], str]],
                           groups: set[str], namespaces: set[str], allowed: set[str]) -> list[str]:
    """Step 4 for each render of the env: (where, version, docs, destination namespace)."""
    out = []
    for where, ver, docs, ns in renders:
        label = "%s %s" % (env, where) if where != "the umbrella" else env
        if ns and ns not in namespaces:
            out.append("%s: the Application deploys into namespace %r, and the Argo CD project of %s "
                       "does not permit it" % (label, ns, env))
        out += scope_failures(label, ver, docs, groups, namespaces)
        if allowed:
            out += whitelist_failures(label, ver, docs, allowed)
    return out


def env_failures(env: str, tmp: pathlib.Path) -> list[str]:
    app = ENVS / env / "gibson.yaml"
    if not app.is_file():
        return ["%s: no gitops/envs/%s/gibson.yaml" % (env, env)]
    version = pinned_version(app.read_text(encoding="utf-8"))
    if not version:
        return ["%s: gitops/envs/%s/gibson.yaml pins no %s/%s version" % (env, env, OCI_REPO, CHART)]
    try:
        tgz = fetch(version, tmp)
    except RuntimeError as exc:
        return ["%s: %s" % (env, exc)]
    core, err = render(tgz, [ENVS / env / "values.yaml"])
    if err:
        return ["%s: gitops/envs/%s/values.yaml does not render with the pinned chart %s: %s"
                % (env, env, version, err)]
    out: list[str] = []
    overlay: list[dict] = []
    for app_file in sorted((ENVS / env / "apps").glob("*.yaml")):
        for path, files in overlay_sources(app_file.read_text(encoding="utf-8")):
            docs, err = render(ROOT / path, [ROOT / f for f in files])
            if err:
                out.append("%s: %s does not render with the values of %s: %s"
                           % (env, path, app_file.relative_to(ROOT), err))
            overlay += docs
    # Every other Application of the env that Argo renders from a chart of the
    # same repo, at its own pin, in the same AppProject (hosted#622).
    others: list[tuple[str, str, list[dict], str]] = []
    for app_file in sorted((ENVS / env).glob("*.yaml")):
        for a in chart_apps(app_file.read_text(encoding="utf-8")):
            where = "%s (%s %s)" % (app_file.relative_to(ROOT), a["chart"], a["version"])
            try:
                tgz_other = fetch(a["version"], tmp, a["chart"])
            except RuntimeError as exc:
                out.append("%s: %s: %s" % (env, where, exc))
                continue
            files = [ROOT / f for f in a["files"]]
            if a["object"]:
                obj = tmp / ("%s-%s-values.yaml" % (env, a["release"]))
                obj.write_text(yaml.safe_dump(a["object"]), encoding="utf-8")
                files.append(obj)
            docs, err = render(tgz_other, files, a["namespace"] or "default", a["release"])
            if err:
                out.append("%s: %s does not render: %s" % (env, where, err))
                continue
            others.append((where, a["version"], docs, a["namespace"]))
    tfvars = env_tfvars(env, MAKEFILE.read_text(encoding="utf-8"))
    if tfvars is None or not tfvars.is_file():
        out.append("%s: no stage 1 tfvars %s, so the Argo CD scope of the env cannot be read" % (env, tfvars))
    else:
        groups, namespaces = argocd_scope(ARGOCD_MODULE, tfvars.read_text(encoding="utf-8"))
        if len(groups) <= len(ARGOCD_FIXED_GROUPS) or not namespaces:
            out.append("%s: no Argo CD API group or namespace list was read from %s, so step 4 checked "
                       "nothing" % (env, ARGOCD_MODULE.relative_to(ROOT)))
        else:
            allowed = cluster_whitelist(ARGOCD_MODULE, tfvars.read_text(encoding="utf-8"))
            if not allowed:
                out.append("%s: no project cluster whitelist was read, so step 4 checked nothing" % env)
            renders = [("the umbrella", version, core, "gibson"), ("the SaaS overlays", version, overlay, "gibson")]
            out += renders_scope_failures(env, renders + others, groups, namespaces, allowed)
    secret, vols = restore_tls_volumes(VELERO_RESTORE.read_text(encoding="utf-8"))
    out += openbao_tls_failures(env, version, core, secret, vols)
    out += reloader_admission_failures(env, version, core + overlay)
    return out + group_failures(env, version, core, overlay)


def reloader_targets(docs: list[dict]) -> tuple[str, set[str]]:
    """The account of the Reloader Deployment, and the resources (deployments,
    statefulsets) that its Role lets it patch."""
    principal, kinds = "", set()
    for d in docs:
        md = d.get("metadata") or {}
        if d.get("kind") == "Deployment" and md.get("name") == "reloader":
            sa = (((d.get("spec") or {}).get("template") or {}).get("spec") or {}).get("serviceAccountName") or "default"
            principal = "system:serviceaccount:%s:%s" % (md.get("namespace") or "gibson", sa)
        if d.get("kind") == "Role" and md.get("name") == "reloader":
            for r in d.get("rules") or []:
                if "patch" in (r.get("verbs") or []) and "apps" in (r.get("apiGroups") or []):
                    kinds |= set(r.get("resources") or []) & {"deployments", "statefulsets"}
    return principal, kinds


def binding_excludes(binding: dict, ns: str) -> bool:
    """True only when the namespace selector of the binding provably leaves
    ns out. No selector, or any selector this cannot read, is False."""
    sel = ((binding.get("spec") or {}).get("matchResources") or {}).get("namespaceSelector")
    if not sel:
        return False
    name = "kubernetes.io/metadata.name"
    labels = sel.get("matchLabels") or {}
    if name in labels and labels[name] != ns:
        return True
    for e in sel.get("matchExpressions") or []:
        if e.get("key") != name:
            continue
        values = e.get("values") or []
        if e.get("operator") == "In" and ns not in values:
            return True
        if e.get("operator") == "NotIn" and ns in values:
            return True
    return False


_STARTS = re.compile(r"^request\.namespace\.startsWith\('([^']*)'\)$")
_MATCHES = re.compile(r"^request\.namespace\.matches\('([^']*)'\)$")


def condition_excludes(expr: str, ns: str) -> bool:
    """True only when a term of the && of expr is a known shape that ns
    fails: request.namespace.startsWith('x') or request.namespace.matches('re').
    An expression with || is not a pure && chain: CEL reads a || b && c as
    a || (b && c), so it can hold for ns, and it never excludes (review of
    hosted#165). A term must match the shape exactly, so a negated or a
    parenthesized term never excludes either."""
    if "||" in str(expr):
        return False
    for term in str(expr).split("&&"):
        t = " ".join(term.split())
        m = _STARTS.match(t)
        if m and not ns.startswith(m.group(1)):
            return True
        m = _MATCHES.match(t)
        if m:
            try:
                if not re.search(m.group(1), ns):
                    return True
            except re.error:
                pass
    return False


def reloader_admission_failures(env: str, version: str, docs: list[dict], ns: str = "gibson") -> list[str]:
    principal, kinds = reloader_targets(docs)
    if not principal or not kinds:
        return ["%s: the render at %s holds no Reloader Deployment or no Role that lets it patch a Deployment "
                "or StatefulSet, so step 6 checked nothing" % (env, version)]
    bindings: dict[str, list[dict]] = {}
    for d in docs:
        if d.get("kind") == "ValidatingAdmissionPolicyBinding":
            bindings.setdefault(str((d.get("spec") or {}).get("policyName") or ""), []).append(d)
    out = []
    for d in docs:
        if d.get("kind") != "ValidatingAdmissionPolicy":
            continue
        name = str((d.get("metadata") or {}).get("name") or "")
        spec = d.get("spec") or {}
        rules = ((spec.get("matchConstraints") or {}).get("resourceRules")) or []
        if not any("UPDATE" in (r.get("operations") or []) and "apps" in (r.get("apiGroups") or [])
                   and kinds & set(r.get("resources") or []) for r in rules):
            continue
        bs = bindings.get(name, [])
        if bs and all(binding_excludes(b, ns) for b in bs):
            continue
        if any(condition_excludes(c.get("expression") or "", ns) for c in spec.get("matchConditions") or []):
            continue
        rule = {v.get("name"): str(v.get("expression") or "") for v in spec.get("variables") or []}.get("restartOnly", "")
        ok = ('request.userInfo.username == "%s"' % principal in rule
              and "object.spec.template.spec == oldObject.spec.template.spec" in rule
              and any("variables.restartOnly" in str(v.get("expression") or "") for v in spec.get("validations") or []))
        if not ok:
            out.append("%s: the ValidatingAdmissionPolicy %s at %s matches an UPDATE of %s in %s and does not admit "
                       "a restart-only UPDATE by %s (a variable restartOnly, used by a validation). Reloader stops "
                       "its whole pass on the first refused update, so no consumer of a rotated Secret restarts "
                       "(hosted#162)" % (env, name, version, "/".join(sorted(kinds)), ns, principal))
    return out


# ---------------------------------------------------------------------------
# The failing fixtures, run on every invocation. A guard that cannot fail is
# worse than no guard.
# ---------------------------------------------------------------------------
FIXTURE_CHART = {
    "Chart.yaml": "apiVersion: v2\nname: fx\nversion: 0.1.0\n",
    "values.yaml": "auth: signed-request\n",
    "templates/route.yaml":
        '{{- if not (has .Values.auth (list "signed-request" "own-sign-in")) }}\n'
        '{{- fail "auth must be signed-request or own-sign-in" }}\n{{- end }}\n'
        "apiVersion: cilium.io/v2\nkind: CiliumNetworkPolicy\nmetadata:\n  name: fx-zitadel\n"
        "spec:\n  endpointSelector:\n    matchLabels:\n"
        "      gibson.zeroroot.ai/egress-fqdn: zitadel\n",
}


def overlay_pod(group: str) -> dict:
    return {"kind": "Deployment", "metadata": {"name": "billing"},
            "spec": {"template": {"metadata": {"labels": {GROUP_LABEL: group}}}}}


def self_test(tmp: pathlib.Path) -> list[str]:
    out = []
    chart = tmp / "fx-chart"
    for name, text in FIXTURE_CHART.items():
        (chart / name).parent.mkdir(parents=True, exist_ok=True)
        (chart / name).write_text(text, encoding="utf-8")
    bad = tmp / "fx-bad.yaml"
    bad.write_text("auth: query-token\n", encoding="utf-8")
    good = tmp / "fx-good.yaml"
    good.write_text("auth: signed-request\n", encoding="utf-8")
    docs, err = render(chart, [bad])
    if not err:
        out.append("self-test: a value that the chart refuses (the defect of hosted#565) rendered")
    docs, err = render(chart, [good])
    if err:
        out.append("self-test: a value that the chart takes failed to render: %s" % err)
    if not group_failures("fx", "0.1.0", docs, [overlay_pod("billing")]):
        out.append("self-test: an overlay pod in a group with no policy (the defect of hosted#558) passed")
    if group_failures("fx", "0.1.0", docs, [overlay_pod("zitadel")]):
        out.append("self-test: an overlay pod in a group with a policy failed")
    # Step 4 (hosted#618, charts#602 generators).
    scope_docs = [
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "a", "namespace": "gibson"}},
        {"apiVersion": "generators.external-secrets.io/v1alpha1", "kind": "VaultDynamicSecret",
         "metadata": {"name": "postgres-login-spire", "namespace": "gibson"}},
        {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "setec", "namespace": "setec-system"}},
    ]
    full = {"", "apps", "generators.external-secrets.io"}
    if scope_failures("fx", "0.1.0", scope_docs, full, {"gibson", "setec-system"}):
        out.append("self-test: a render inside the Argo CD scope failed step 4")
    if not scope_failures("fx", "0.1.0", scope_docs, {"", "apps"}, {"gibson", "setec-system"}):
        out.append("self-test: a generator outside the managed groups (the staging stop of 2026-10-12) passed")
    if not scope_failures("fx", "0.1.0", scope_docs, full, {"gibson"}):
        out.append("self-test: a namespace the project does not permit (the drill stop of hosted#618) passed")
    ccnp = [{"apiVersion": "cilium.io/v2", "kind": "CiliumClusterwideNetworkPolicy", "metadata": {"name": "x"}}]
    if not whitelist_failures("fx", "0.1.0", ccnp, {"/Namespace"}):
        out.append("self-test: a cluster-scoped kind off the project whitelist passed")
    if whitelist_failures("fx", "0.1.0", ccnp, {"cilium.io/CiliumClusterwideNetworkPolicy"}):
        out.append("self-test: a cluster-scoped kind on the project whitelist failed")
    unknown = [{"apiVersion": "networking.k8s.io/v1", "kind": "IngressClass", "metadata": {"name": "x"}}]
    if not whitelist_failures("fx", "0.1.0", unknown, {"networking.k8s.io/IngressClass"}):
        out.append("self-test: a kind with no namespace and no known scope passed")
    crd = [{"apiVersion": "apiextensions.k8s.io/v1", "kind": "CustomResourceDefinition",
            "metadata": {"name": "widgets.fx.io"},
            "spec": {"scope": "Cluster", "names": {"kind": "Widget"}}},
           {"apiVersion": "fx.io/v1", "kind": "Widget", "metadata": {"name": "w"}}]
    if not any("fx.io/Widget" in f for f in whitelist_failures(
            "fx", "0.1.0", crd, {"apiextensions.k8s.io/CustomResourceDefinition"})):
        out.append("self-test: a cluster-scoped kind of a rendered CRD off the whitelist passed")
    apps = chart_apps(
        "metadata:\n  name: gibson-velero\nspec:\n  destination:\n    namespace: velero\n  sources:\n"
        "    - repoURL: ghcr.io/zeroroot-ai/charts\n      chart: gibson-velero\n      targetRevision: \"1.2.3\"\n"
        "      helm:\n        valueFiles:\n          - $values/gitops/envs/fx/v.yaml\n"
        "    - repoURL: ghcr.io/zeroroot-ai/charts\n      chart: gibson\n      targetRevision: \"1.2.3\"\n")
    if apps != [{"chart": "gibson-velero", "version": "1.2.3", "files": ["gitops/envs/fx/v.yaml"],
                 "object": {}, "release": "gibson-velero", "namespace": "velero"}]:
        out.append("self-test: chart_apps no longer reads a second Application of the env: %r" % apps)
    # A second Application of the env, out of scope (hosted#622): its group,
    # its destination namespace and its cluster kind are each refused, and
    # the umbrella in scope is not.
    umbrella = [{"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "u", "namespace": "gibson"}}]
    second = [{"apiVersion": "cilium.io/v2", "kind": "CiliumNetworkPolicy", "metadata": {"name": "v"}},
              {"apiVersion": "cilium.io/v2", "kind": "CiliumClusterwideNetworkPolicy", "metadata": {"name": "w"}}]
    got = renders_scope_failures("fx", [("the umbrella", "0.1.0", umbrella, "gibson"),
                                        ("gibson-velero.yaml (gibson-velero 0.1.0)", "0.1.0", second, "velero")],
                                 {""}, {"gibson"}, {"/Namespace"})
    if not any("'velero'" in g for g in got) or not any("'cilium.io'" in g for g in got) \
            or not any("CiliumClusterwideNetworkPolicy" in g for g in got) \
            or any(g.startswith("fx:") for g in got):
        out.append("self-test: a second Application out of scope was not refused on each count: %r" % got)
    tf = 'locals {\n  x = concat(\n    [\n      "argocd", # c\n      "gibson",\n    ],\n    var.y,\n  )\n}\n'
    if tf_list(tf, "x") != ["argocd", "gibson"]:
        out.append("self-test: tf_list no longer reads a concat list: %r" % tf_list(tf, "x"))
    src = overlay_sources(
        "spec:\n  sources:\n    - path: gitops/saas-overlay/x\n      helm:\n        valueFiles:\n"
        "          - $values/gitops/envs/fx/values.yaml\n    - ref: values\n")
    if src != [("gitops/saas-overlay/x", ["gitops/envs/fx/values.yaml"])]:
        out.append("self-test: overlay_sources no longer reads an overlay Application: %r" % src)
    # Step 5: the OpenBao TLS volumes that the restore patches.
    def bao(vols: list[dict]) -> list[dict]:
        return [{"kind": "StatefulSet", "metadata": {"name": "gibson-openbao"},
                 "spec": {"template": {"spec": {"volumes": vols}}}}]
    req = [{"name": "tls", "secret": {"secretName": "s"}}, {"name": "openbao-ca", "secret": {"secretName": "s"}}]
    if openbao_tls_failures("fx", "0.1.0", bao(req), "s", ["tls", "openbao-ca"]):
        out.append("self-test: two required TLS volumes failed step 5")
    opt = [{"name": "tls", "secret": {"secretName": "s", "optional": True}}, req[1]]
    if not openbao_tls_failures("fx", "0.1.0", bao(opt), "s", ["tls", "openbao-ca"]):
        out.append("self-test: an optional TLS volume in a normal render passed step 5")
    if not openbao_tls_failures("fx", "0.1.0", bao(req[1:]), "s", ["tls", "openbao-ca"]):
        out.append("self-test: a TLS volume that the chart renamed passed step 5")
    other = [{"name": "tls", "secret": {"secretName": "another-secret"}}, req[1]]
    if not openbao_tls_failures("fx", "0.1.0", bao(other), "s", ["tls", "openbao-ca"]):
        out.append("self-test: a TLS volume that mounts another Secret passed step 5")
    sample = 'OPENBAO_TLS_SECRET="s"\nOPENBAO_TLS_VOLUMES="tls openbao-ca"\n'
    if restore_tls_volumes(sample) != ("s", ["tls", "openbao-ca"]):
        out.append("self-test: restore_tls_volumes no longer reads velero-restore.sh")
    if not openbao_tls_failures("fx", "0.1.0", bao(req), "", []):
        out.append("self-test: step 5 passed with no volume list")
    # Step 6: each workloads policy in the release namespace admits Reloader.
    rl = [{"kind": "Deployment", "metadata": {"name": "reloader", "namespace": "gibson"},
           "spec": {"template": {"spec": {"serviceAccountName": "reloader"}}}},
          {"kind": "Role", "metadata": {"name": "reloader"},
           "rules": [{"apiGroups": ["apps"], "resources": ["deployments"], "verbs": ["patch"]}]}]
    def vap(name: str, restart: bool, sel: dict | None = None, cond: str = "") -> list[dict]:
        spec: dict = {"matchConstraints": {"resourceRules": [
            {"apiGroups": ["apps"], "operations": ["UPDATE"], "resources": ["deployments"]}]},
            "validations": [{"expression": "x" + (" || variables.restartOnly" if restart else "")}]}
        if restart:
            spec["variables"] = [{"name": "restartOnly", "expression":
                'request.userInfo.username == "system:serviceaccount:gibson:reloader" '
                "&& object.spec.template.spec == oldObject.spec.template.spec"}]
        if cond:
            spec["matchConditions"] = [{"name": "c", "expression": cond}]
        b = {"kind": "ValidatingAdmissionPolicyBinding", "metadata": {"name": name},
             "spec": {"policyName": name, "matchResources": {"namespaceSelector": sel} if sel else {}}}
        return [{"kind": "ValidatingAdmissionPolicy", "metadata": {"name": name}, "spec": spec}, b]
    own = {"matchLabels": {"kubernetes.io/metadata.name": "gibson"}}
    if reloader_admission_failures("fx", "0.1.0", rl + vap("good", True, own)):
        out.append("self-test: a workloads policy that admits Reloader failed step 6")
    if not reloader_admission_failures("fx", "0.1.0", rl + vap("bad", False, own)):
        out.append("self-test: a workloads policy in the release namespace that refuses Reloader passed step 6")
    if not reloader_admission_failures("fx", "0.1.0", rl + vap("open", False)):
        out.append("self-test: an unscoped workloads policy that refuses Reloader passed step 6")
    if reloader_admission_failures("fx", "0.1.0", rl + vap("tenant", False, None, "request.namespace.startsWith('tenant-')")):
        out.append("self-test: a policy scoped to tenant namespaces by its match condition failed step 6")
    if reloader_admission_failures("fx", "0.1.0", rl + vap("other", False, {"matchLabels": {"kubernetes.io/metadata.name": "x"}})):
        out.append("self-test: a policy bound to another namespace failed step 6")
    if not reloader_admission_failures("fx", "0.1.0", vap("good", True, own)):
        out.append("self-test: step 6 passed with no Reloader in the render")
    # Fail closed: an unknown selector or condition counts.
    if not reloader_admission_failures("fx", "0.1.0", rl + vap("lbl", False, {"matchLabels": {"team": "x"}})):
        out.append("self-test: a policy bound by a label that may hold the release namespace passed step 6")
    if not reloader_admission_failures("fx", "0.1.0", rl + vap("eq", False, None, "request.namespace == 'gibson'")):
        out.append("self-test: a policy whose match condition names the release namespace passed step 6")
    if not reloader_admission_failures("fx", "0.1.0", rl + vap("notin", False, {"matchExpressions": [
            {"key": "kubernetes.io/metadata.name", "operator": "NotIn", "values": ["kube-system"]}]})):
        out.append("self-test: a NotIn selector that holds the release namespace passed step 6")
    if reloader_admission_failures("fx", "0.1.0", rl + vap("notin2", False, {"matchExpressions": [
            {"key": "kubernetes.io/metadata.name", "operator": "NotIn", "values": ["gibson"]}]})):
        out.append("self-test: a NotIn selector that leaves the release namespace out failed step 6")
    if reloader_admission_failures("fx", "0.1.0", rl + vap("plug", False, None, "request.namespace.matches('^tenant-.+-plugins$')")):
        out.append("self-test: a policy scoped to plugin namespaces by matches() failed step 6")
    if reloader_admission_failures("fx", "0.1.0", rl + vap("tr", False, None,
            "request.namespace.startsWith('tenant-') && !request.namespace.endsWith('-plugins')")):
        out.append("self-test: a policy whose && starts with a tenant prefix failed step 6")
    if not reloader_admission_failures("fx", "0.1.0", rl + vap("or", False, None,
            "request.userInfo.username == 'x' || request.operation == 'UPDATE' && request.namespace.startsWith('tenant-')")):
        out.append("self-test: a match condition with || passed step 6 as if it left the namespace out")
    if not reloader_admission_failures("fx", "0.1.0", rl + vap("neg", False, None, "!request.namespace.startsWith('tenant-')")):
        out.append("self-test: a negated startsWith passed step 6 as if it left the namespace out")
    if not reloader_admission_failures("fx", "0.1.0", rl + vap("gpref", False, None, "request.namespace.startsWith('gib')")):
        out.append("self-test: a startsWith prefix that the release namespace has passed step 6")
    return out


def main() -> int:
    with tempfile.TemporaryDirectory() as t:
        tmp = pathlib.Path(t)
        failures = self_test(tmp)
        envs = overlay_envs(MAKEFILE.read_text(encoding="utf-8"))
        if not envs:
            failures.append("the Makefile names no env whose stage 2 is the git overlay; "
                            "this guard would check nothing")
        for env in envs:
            failures += env_failures(env, tmp)
    if failures:
        for f in failures:
            print("::error::" + f)
        return 1
    print("ok: %s render with the chart each one pins, Argo CD of each manages every group and namespace "
          "of its render, each SaaS overlay egress group has a policy, and the OpenBao TLS volumes that a "
          "restore patches are required in a normal render"
          % ", ".join(envs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
