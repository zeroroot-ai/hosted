#!/usr/bin/env python3
"""check-overlay-disk-repo.py — each cloud overlay names the disk registry of its stage 0.

The setec chart refuses to render without `setec.launcher.diskRepo`, the
registry repository of the signed sandbox disks (ADR-0166). On AWS, stage 0
makes one private ECR repository per environment (D85,
substrate/gibson-bootstrap/ecr.tf):

    <aws_account_id>.dkr.ecr.<aws_region>.amazonaws.com/zeroroot-ai-<environment>-setec-disks

The overlay of the env names that URL as a reviewed commit, because Argo reads
the overlay from git and no bringup step can write into it. So two places name
one repository, and this guard keeps them the same. A wrong name is a disk
builder that cannot push and a kubelet that cannot pull, which nothing sees
until the first Sandbox of a rebuilt environment.

For every env whose `RECREATE_UP_<env>` in the Makefile runs recreate-aws.sh
or recreate-ec2.sh, the guard reads:

  1. `gibson-workloads.setec.launcher.diskRepo` in gitops/envs/<env>/values.yaml,
  2. `aws_account_id`, `environment` and `aws_region` (default from
     variables.tf) in substrate/gibson-bootstrap/envs/<env>.tfvars,

and fails when the overlay names another URL, or none. The kind row runs
recreate-kind.sh, which reads SETEC_DISK_REPO from its substrate.env.

The public key beside it (`diskBuilder.publicKeys`) is not checked here. It
derives from the keyring seed, which no file in this repo holds. The recreate
verb checks it against the keyring seed (hosted#521).

Run:  scripts/check-overlay-disk-repo.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "gitops" / "envs"
STAGE0 = ROOT / "substrate" / "gibson-bootstrap"
MAKEFILE = ROOT / "Makefile"


def executable(text: str) -> str:
    """The lines that are not comments. Prose naming a repository proves nothing."""
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def overlay_envs(makefile_text: str) -> list[str]:
    envs = re.findall(
        r"^RECREATE_UP_(\w+)\s*:=\s*scripts/recreate-(?:aws|ec2)\.sh", makefile_text, re.M)
    return sorted(set(envs))


def tfvar(text: str, name: str) -> str | None:
    m = re.search(r'^\s*%s\s*=\s*"([^"]*)"' % re.escape(name), executable(text), re.M)
    return m.group(1) if m else None


def default_region(variables_text: str) -> str | None:
    m = re.search(r'variable\s+"aws_region"\s*\{(.*?)\n\}', variables_text, re.S)
    if not m:
        return None
    d = re.search(r'^\s*default\s*=\s*"([^"]+)"', m.group(1), re.M)
    return d.group(1) if d else None


def want_repo(tfvars_text: str, region_default: str | None) -> str | None:
    account = tfvar(tfvars_text, "aws_account_id")
    env = tfvar(tfvars_text, "environment")
    region = tfvar(tfvars_text, "aws_region") or region_default
    if not (account and env and region):
        return None
    return "%s.dkr.ecr.%s.amazonaws.com/zeroroot-ai-%s-setec-disks" % (account, region, env)


def overlay_disk_repo(values_text: str) -> str | None:
    """`gibson-workloads.setec.launcher.diskRepo`, read by indentation.

    A small indentation walk, not a YAML parser, so this runs wherever
    `make check` runs with no third-party import. Comment lines are dropped
    first, so a commented-out key is absent.
    """
    path = ["gibson-workloads", "setec", "launcher", "diskRepo"]
    stack: list[tuple[int, str]] = []
    for line in executable(values_text).splitlines():
        m = re.match(r"^(\s*)([A-Za-z0-9_.-]+):(.*)$", line)
        if not m:
            continue
        indent, key, rest = len(m.group(1)), m.group(2), m.group(3)
        while stack and stack[-1][0] >= indent:
            stack.pop()
        stack.append((indent, key))
        if [k for _, k in stack] == path:
            value = rest.split(" #", 1)[0].strip().strip('"').strip("'")
            return value or None
    return None


def env_failures(env: str, values_text: str | None, tfvars_text: str | None,
                 region_default: str | None) -> list[str]:
    """Failures for one env. Takes text, not paths, so the self-test below
    goes through the same code as a real env."""
    if tfvars_text is None:
        return ["%s has no substrate/gibson-bootstrap/envs/%s.tfvars, so no stage 0 "
                "names its disk registry." % (env, env)]
    want = want_repo(tfvars_text, region_default)
    if want is None:
        return ["substrate/gibson-bootstrap/envs/%s.tfvars does not name aws_account_id "
                "and environment, so the disk registry URL cannot be derived." % env]
    if values_text is None:
        return ["gitops/envs/%s/values.yaml does not exist." % env]
    got = overlay_disk_repo(values_text)
    if got is None:
        return ["gitops/envs/%s/values.yaml sets no gibson-workloads.setec.launcher.diskRepo. "
                "The setec chart refuses to render. Set it to %s (D85)." % (env, want)]
    if got != want:
        return ["gitops/envs/%s/values.yaml names the disk registry %s, but stage 0 of %s "
                "makes %s (substrate/gibson-bootstrap/ecr.tf)." % (env, got, env, want)]
    return []


def read(p: pathlib.Path) -> str | None:
    return p.read_text(encoding="utf-8") if p.is_file() else None


# The failing fixtures, run on every invocation. A guard that cannot fail is
# worse than no guard.
TFVARS = 'environment    = "fx"\naws_account_id = "111122223333"\n'
TFVARS_REGION = TFVARS + 'aws_region = "us-west-2"\n'
GOOD = "111122223333.dkr.ecr.us-east-1.amazonaws.com/zeroroot-ai-fx-setec-disks"


def values(repo: str, commented: bool = False) -> str:
    key = "      # diskRepo" if commented else "      diskRepo"
    return ("gibson-workloads:\n  setec:\n    enabled: true\n    launcher:\n"
            '%s: "%s"\n      diskBuilder:\n        publicKeys:\n          - "x"\n'
            "gibson-operators:\n  setec:\n    launcher:\n      diskRepo: other\n" % (key, repo))


SELF_TEST = [
    # (name, values, tfvars, expect failure)
    ("the defect of hosted#521: no diskRepo at all",
     "gibson-workloads:\n  setec:\n    enabled: true\n", TFVARS, True),
    ("diskRepo only in a comment", values(GOOD, commented=True), TFVARS, True),
    ("the repository of another env",
     values(GOOD.replace("-fx-", "-prod-")), TFVARS, True),
    ("another account", values(GOOD.replace("1111", "9999")), TFVARS, True),
    ("the default region when tfvars sets another", values(GOOD), TFVARS_REGION, True),
    ("no stage 0 tfvars", values(GOOD), None, True),
    ("the URL that stage 0 makes", values(GOOD), TFVARS, False),
]


def self_test() -> list[str]:
    out = []
    for name, vals, tfv, want_fail in SELF_TEST:
        got = env_failures("fx", vals, tfv, "us-east-1")
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
    region_default = default_region(read(STAGE0 / "variables.tf") or "")
    if region_default is None:
        failures.append("substrate/gibson-bootstrap/variables.tf has no aws_region default; "
                        "this guard cannot derive the registry host")
    envs = overlay_envs(MAKEFILE.read_text(encoding="utf-8"))
    if not envs:
        failures.append("the Makefile names no env whose stage 2 is the git overlay; "
                        "this guard would check nothing")
    for env in envs:
        failures += env_failures(env, read(ENVS / env / "values.yaml"),
                                 read(STAGE0 / "envs" / f"{env}.tfvars"), region_default)
    if failures:
        for f in failures:
            print("::error::" + f)
        return 1
    print("ok: the overlay of %s names the disk registry of its stage 0" % ", ".join(envs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
