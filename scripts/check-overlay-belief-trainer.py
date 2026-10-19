#!/usr/bin/env python3
"""check-overlay-belief-trainer.py — each cloud overlay pins the trainer copy of its stage 0.

The SaaS belief trainer image (ghcr.io/zeroroot-ai/billing-belief-trainer) is
private, and the trainer CronJob of each tenant namespace has no image pull
secret (gibson#31). So the node pulls a copy from the private ECR repository
of the env with its instance role (substrate/gibson-bootstrap/ecr.tf):

    <aws_account_id>.dkr.ecr.<aws_region>.amazonaws.com/zeroroot-ai-<environment>-belief-trainer

scripts/belief-trainer-image.sh copies the pinned image there. For every env
whose `RECREATE_UP_<env>` in the Makefile runs recreate-aws.sh or
recreate-ec2.sh, this guard reads
`gibson-operators.tenantOperator.beliefTrainer.image` of
gitops/envs/<env>/values.yaml. When the overlay sets it, the guard fails when:

  1. the repository is not the ECR repository of the env: the node cannot
     pull it with no secret;
  2. the tag is not `<tag>@sha256:<64 hex>`: the copy keeps the digest, and
     an immutable tag must name exactly one.

A missing trainer image is a failure only in a change set (--base), and
only when two things are true:

  3. the chart that the env pins reads the key (its gibson-operators
     defaults declare tenantOperator.beliefTrainer). The chart default is the
     public gibson image, with no curated model;
  4. this change set does not move the pin of the env. A pin bump must not
     touch values.yaml (gitops/scripts/check-promotion-isolation.sh), and a
     chart before charts#578 refuses the key (check-overlay-values-read.py).
     So the value lands in the change set right after the pin bump, and each
     later change set fails until it lands.

With no --base (make check, a push to main) the guard checks rules 1 and 2
only, offline. With --base the pinned chart comes from
oci://ghcr.io/zeroroot-ai/charts/gibson with `helm pull`, or from
CHART_TGZ_DIR for a run with no network.

Run:  scripts/check-overlay-belief-trainer.py [--base <git ref>]
"""

from __future__ import annotations

import importlib.util
import io
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "gitops" / "envs"
STAGE0 = ROOT / "substrate" / "gibson-bootstrap"
MAKEFILE = ROOT / "Makefile"
OCI_REPO = "ghcr.io/zeroroot-ai/charts"
CHART = "gibson"
TAG = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}@sha256:[0-9a-f]{64}$")


def _disk_repo_guard():
    """The tfvars readers of check-overlay-disk-repo.py: one copy of them."""
    spec = importlib.util.spec_from_file_location(
        "check_overlay_disk_repo", ROOT / "scripts" / "check-overlay-disk-repo.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


DISK = _disk_repo_guard()


def want_repo(tfvars_text: str, region_default: str | None) -> str | None:
    disks = DISK.want_repo(tfvars_text, region_default)
    return disks.removesuffix("-setec-disks") + "-belief-trainer" if disks else None


def trainer_image(values: dict) -> dict | None:
    ops = values.get("gibson-operators") or {}
    image = (((ops.get("tenantOperator") or {}).get("beliefTrainer") or {}).get("image"))
    return image if isinstance(image, dict) else None


def chart_reads_trainer(tgz: bytes) -> bool:
    with tarfile.open(fileobj=io.BytesIO(tgz), mode="r:gz") as tar:
        f = tar.extractfile("%s/charts/gibson-operators/values.yaml" % CHART)
        defaults = yaml.safe_load(f.read() if f else b"") or {}
    return "beliefTrainer" in (defaults.get("tenantOperator") or {})


def pinned_version(app_text: str) -> str | None:
    doc = yaml.safe_load(app_text) or {}
    for src in ((doc.get("spec") or {}).get("sources") or []):
        if src.get("repoURL") == OCI_REPO and src.get("chart") == CHART:
            return str(src.get("targetRevision") or "") or None
    return None


def fetch(version: str) -> bytes:
    local = os.environ.get("CHART_TGZ_DIR")
    name = "%s-%s.tgz" % (CHART, version)
    if local:
        return (pathlib.Path(local) / name).read_bytes()
    with tempfile.TemporaryDirectory() as tmp:
        res = subprocess.run(
            ["helm", "pull", "oci://%s/%s" % (OCI_REPO, CHART), "--version", version,
             "--destination", tmp], capture_output=True, text=True, check=False)
        if res.returncode != 0:
            raise RuntimeError("helm pull %s %s failed: %s" % (CHART, version, res.stderr.strip()[-400:]))
        return (pathlib.Path(tmp) / name).read_bytes()


def base_text(base: str, rel: str) -> str:
    """The file at the base ref, or "" when the base has no such file."""
    res = subprocess.run(["git", "-C", str(ROOT), "show", "%s:%s" % (base, rel)],
                         capture_output=True, text=True, check=False)
    return res.stdout if res.returncode == 0 else ""


def env_failures(env: str, values: dict, want: str | None,
                 reads: bool = False, pin_moved: bool = True) -> list[str]:
    """Failures for one env. Takes parsed inputs, so the self-test below goes
    through the same code as a real env. The defaults are the offline mode:
    no change set, so a missing image is not checked."""
    image = trainer_image(values)
    key = "gitops/envs/%s/values.yaml gibson-operators.tenantOperator.beliefTrainer.image" % env
    if image is None:
        if reads and not pin_moved:
            return ["%s is not set, and the chart that %s pins reads it. The chart default is the "
                    "public gibson image, with no curated model (gibson#31). Set it in this change "
                    "set: the pin bump before it could not (check-promotion-isolation)." % (key, env)]
        return []
    if want is None:
        return ["substrate/gibson-bootstrap/envs/%s.tfvars does not name aws_account_id and "
                "environment, so the trainer repository cannot be derived." % env]
    out = []
    if image.get("repository") != want:
        out.append("%s.repository is %r, and stage 0 of %s makes %s. A tenant namespace has no "
                   "pull secret, so the node can pull only that repository." % (key, image.get("repository"), env, want))
    if not TAG.match(str(image.get("tag") or "")):
        out.append("%s.tag is %r. Pin '<tag>@sha256:<digest>': the copy keeps the digest, and the "
                   "immutable tag must name one." % (key, image.get("tag")))
    return out


# The failing fixtures, run on every invocation. A guard that cannot fail is
# worse than no guard.
TFVARS = 'environment    = "fx"\naws_account_id = "111122223333"\n'
GOOD_REPO = "111122223333.dkr.ecr.us-east-1.amazonaws.com/zeroroot-ai-fx-belief-trainer"
GOOD_TAG = "sha-9797812@sha256:" + "a" * 64


def values(repo: str | None, tag: str | None) -> dict:
    if repo is None:
        return {"gibson-operators": {"tenantOperator": {}}}
    return {"gibson-operators": {"tenantOperator": {"beliefTrainer": {"image": {"repository": repo, "tag": tag}}}}}


SELF_TEST = [
    # (name, values, chart reads the key, pin moved in this change set, expect failure)
    ("the defect of gibson#31: the private GHCR image, which no tenant pod can pull",
     values("ghcr.io/zeroroot-ai/billing-belief-trainer", GOOD_TAG), True, False, True),
    ("the repository of another env",
     values(GOOD_REPO.replace("-fx-", "-prod-"), GOOD_TAG), True, False, True),
    ("a tag with no digest", values(GOOD_REPO, "sha-9797812"), True, False, True),
    ("no image in the change set after the pin bump", values(None, None), True, False, True),
    ("no image in the pin bump itself", values(None, None), True, True, False),
    ("no image while the chart does not read the key", values(None, None), False, False, False),
    ("no image in the offline mode", values(None, None), False, True, False),
    ("the copy of stage 0 with a digest", values(GOOD_REPO, GOOD_TAG), True, False, False),
]


def self_test() -> list[str]:
    out = []
    want = want_repo(TFVARS, "us-east-1")
    if want != GOOD_REPO:
        out.append("self-test: want_repo gives %r, not %r" % (want, GOOD_REPO))
    for name, vals, reads, moved, want_fail in SELF_TEST:
        got = env_failures("fx", vals, want, reads, moved)
        if bool(got) != want_fail:
            out.append("self-test %r: expected %s, got %s" % (
                name, "a failure" if want_fail else "a pass", got or "a pass"))
    return out


def change_set(env: str, base: str) -> tuple[bool, bool, str | None]:
    """(chart reads the key, pin moved since base, failure) for one env."""
    rel = "gitops/envs/%s/gibson.yaml" % env
    head = pinned_version(DISK.read(ROOT / rel) or "")
    if not head:
        return False, False, "%s pins no chart version" % rel
    moved = pinned_version(base_text(base, rel)) != head
    try:
        return chart_reads_trainer(fetch(head)), moved, None
    except (RuntimeError, OSError, KeyError) as exc:
        return False, moved, "%s: could not read the pinned chart %s: %s" % (env, head, exc)


def main(argv: list[str]) -> int:
    base = None
    if argv[:1] == ["--base"] and len(argv) == 2:
        base = argv[1]
    elif argv:
        print("usage: check-overlay-belief-trainer.py [--base <git ref>]", file=sys.stderr)
        return 2
    failures = self_test()
    region_default = DISK.default_region(DISK.read(STAGE0 / "variables.tf") or "")
    envs = DISK.overlay_envs(MAKEFILE.read_text(encoding="utf-8"))
    if not envs:
        failures.append("the Makefile names no env whose stage 2 is the git overlay; "
                        "this guard would check nothing")
    for env in envs:
        tfvars = DISK.read(STAGE0 / "envs" / f"{env}.tfvars")
        want = want_repo(tfvars, region_default) if tfvars else None
        vals = yaml.safe_load(DISK.read(ENVS / env / "values.yaml") or "") or {}
        reads, moved = False, True
        if base:
            reads, moved, err = change_set(env, base)
            if err:
                failures.append(err)
                continue
        failures += env_failures(env, vals, want, reads, moved)
    if failures:
        for f in failures:
            print("::error::" + f)
        return 1
    print("ok: the overlay of %s pins the belief trainer copy of its stage 0%s"
          % (", ".join(envs), ", or its pin moves here, or its chart reads none" if base
             else ", or no trainer image (offline: no change set)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
