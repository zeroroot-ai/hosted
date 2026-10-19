#!/usr/bin/env python3
"""check-overlay-velero-bucket.py — an AWS overlay gives gibson-velero its bucket.

The gibson-velero chart refuses to render without `bucket.name`:

    bucket.name is required: Velero writes to the durable bucket stage 0
    created. There is no default that is safe to invent.

That refusal is correct, but it happens inside Argo, on the live cluster. The
staging and prod Applications passed no values at all, so on staging the app
sat at `Unknown` with that error, no Velero was installed, and the environment
took no backups. Nothing in CI rendered the overlay, so nobody saw it
(hosted#226).

This is the gate. For every env whose stage 2 is the git overlay, the
gibson-velero Application must:

  1. read at least one value file through the `$values` source, and every
     value file it names must exist in this repo,
  2. set a non-empty `bucket.name` in those files,
  3. keep any `bucket.prefix` under `backups/`, which is the only prefix the
     bucket's lifecycle rule covers,
  4. name the SAME bucket as the env's Postgres archive
     (`platformPostgres.backup.destinationPath` in values.yaml). Both write to
     stage 0's one durable bucket, so two names mean one of them is wrong.

Which envs: the ones whose `RECREATE_UP_<env>` in the Makefile runs
recreate-aws.sh or recreate-ec2.sh. Those read their Applications from git.
The kind row runs recreate-kind.sh, which builds its Velero Application inline
with the substrate bucket, so no overlay reaches it.

Run:  scripts/check-overlay-velero-bucket.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "gitops" / "envs"
MAKEFILE = ROOT / "Makefile"
CHART = "gibson-velero"


def executable(text: str) -> str:
    """The lines that are not comments. Prose naming a bucket proves nothing."""
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def overlay_envs(makefile_text: str) -> list[str]:
    envs = re.findall(
        r"^RECREATE_UP_(\w+)\s*:=\s*scripts/recreate-(?:aws|ec2)\.sh", makefile_text, re.M)
    return sorted(set(envs))


def value_files(app_text: str) -> list[str]:
    """Repo-relative paths of every `$values/...` value file."""
    return re.findall(r"^\s*-\s*\$values/(\S+)", executable(app_text), re.M)


def block_value(values_text: str, block: str, key: str) -> str | None:
    """`<block>.<key>` from a small values file, or None when it is absent.

    A regular expression, not a YAML parser, so this runs wherever `make check`
    runs with no third-party import. It reads one top-level block and one key
    directly under it, which is all these files hold.
    """
    body = executable(values_text)
    m = re.search(r"^%s:\s*\n((?:[ \t]+.*\n?|\s*\n)*)" % re.escape(block), body, re.M)
    if not m:
        return None
    k = re.search(r"^[ \t]+%s:[ \t]*(.*)$" % re.escape(key), m.group(1), re.M)
    if not k:
        return None
    return k.group(1).strip().strip('"').strip("'")


def archive_bucket(env_values_text: str) -> str | None:
    m = re.search(r'destinationPath:\s*"?s3://([^/"\s]+)', executable(env_values_text))
    return m.group(1) if m else None


def env_failures(env: str, app_text: str | None, files: dict[str, str | None],
                 env_values_text: str) -> list[str]:
    """Failures for one env. `files` maps each named value file to its text,
    or None when it does not exist. Takes text, not paths, so the self-test
    below goes through the same code as a real env."""
    if app_text is None:
        return ["envs/%s declares no %s Application. Its stage 2 is the git "
                "overlay, so nothing else installs the backup plane." % (env, CHART)]
    named = value_files(app_text)
    if not named:
        return ["envs/%s/%s.yaml reads no value file through $values. The chart "
                "refuses to render without bucket.name." % (env, CHART)]
    out, bucket, prefix = [], None, None
    for rel in named:
        text = files.get(rel)
        if text is None:
            out.append("envs/%s/%s.yaml names %s, which does not exist." % (env, CHART, rel))
            continue
        bucket = block_value(text, "bucket", "name") or bucket
        prefix = block_value(text, "bucket", "prefix") or prefix
    if out:
        return out
    if not bucket:
        return ["envs/%s: no value file of %s sets bucket.name. The chart refuses "
                "to render, and the env takes no backups." % (env, CHART)]
    if prefix is not None and not prefix.startswith("backups/"):
        out.append("envs/%s: bucket.prefix %r is not under backups/, the only "
                   "prefix the bucket's lifecycle rule covers." % (env, prefix))
    archive = archive_bucket(env_values_text)
    if archive and archive != bucket:
        out.append("envs/%s: Velero writes to %s but the Postgres archive writes to "
                   "%s. Both belong in stage 0's one durable bucket." % (env, bucket, archive))
    return out


def find_app(env: str) -> pathlib.Path | None:
    for p in (ENVS / env / f"{CHART}.yaml", ENVS / env / "apps" / f"{CHART}.yaml"):
        if p.is_file():
            return p
    return None


def read(p: pathlib.Path) -> str | None:
    return p.read_text(encoding="utf-8") if p.is_file() else None


# The failing fixtures, run on every invocation. A guard that cannot fail is
# worse than no guard.
APP_OK = """\
spec:
  sources:
    - repoURL: ghcr.io/zeroroot-ai/charts
      chart: gibson-velero
      targetRevision: "0.131.0"
      helm:
        valueFiles:
          - $values/gitops/envs/fx/gibson-velero-values.yaml
    - repoURL: https://github.com/zeroroot-ai/hosted
      targetRevision: main
      ref: values
"""
APP_NO_VALUES = """\
spec:
  sources:
    - repoURL: ghcr.io/zeroroot-ai/charts
      chart: gibson-velero
      targetRevision: "0.131.0"
      # - $values/gitops/envs/fx/gibson-velero-values.yaml   (a comment is not a value file)
"""
VF = "gitops/envs/fx/gibson-velero-values.yaml"
ENV_VALUES = 'platformPostgres:\n  backup:\n    destinationPath: "s3://fx-durable/backups/postgres/"\n'
SELF_TEST = [
    # (name, app, files, env values, expect failure)
    ("the staging defect: no values at all", APP_NO_VALUES, {}, ENV_VALUES, True),
    ("a value file that does not exist", APP_OK, {VF: None}, ENV_VALUES, True),
    ("bucket.name left empty", APP_OK, {VF: 'bucket:\n  name: ""\n'}, ENV_VALUES, True),
    ("bucket.name only in a comment", APP_OK, {VF: 'bucket:\n  # name: fx-durable\n  region: us-east-1\n'}, ENV_VALUES, True),
    ("a bucket other than the archive's", APP_OK, {VF: 'bucket:\n  name: "other"\n'}, ENV_VALUES, True),
    ("a prefix outside backups/", APP_OK, {VF: 'bucket:\n  name: fx-durable\n  prefix: velero\n'}, ENV_VALUES, True),
    ("no Application at all", None, {}, ENV_VALUES, True),
    ("a correct overlay", APP_OK, {VF: 'bucket:\n  name: "fx-durable"\n  endpoint: ""\n'}, ENV_VALUES, False),
]


def self_test() -> list[str]:
    out = []
    for name, app, files, env_values, want_fail in SELF_TEST:
        got = env_failures("fx", app, files, env_values)
        if bool(got) != want_fail:
            out.append("self-test %r: expected %s, got %s" % (
                name, "a failure" if want_fail else "a pass", got or "a pass"))
    if overlay_envs("RECREATE_UP_kind := scripts/recreate-kind.sh x\n"
                    "RECREATE_UP_staging := scripts/recreate-ec2.sh x staging\n"
                    "RECREATE_UP_prod    := scripts/recreate-aws.sh x prod\n") != ["prod", "staging"]:
        out.append("self-test: overlay_envs no longer reads the recreate rows")
    return out


def main() -> int:
    failures = self_test()
    envs = overlay_envs(MAKEFILE.read_text(encoding="utf-8"))
    if not envs:
        failures.append("the Makefile names no env whose stage 2 is the git overlay; "
                        "this guard would check nothing")
    for env in envs:
        app = find_app(env)
        app_text = read(app) if app else None
        files = {rel: read(ROOT / rel) for rel in (value_files(app_text) if app_text else [])}
        failures += env_failures(env, app_text, files,
                                 read(ENVS / env / "values.yaml") or "")
    if failures:
        for f in failures:
            print("::error::" + f)
        return 1
    print("ok: gibson-velero has its bucket in %s" % ", ".join(envs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
