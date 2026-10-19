#!/usr/bin/env python3
"""check-pull-token-read-only.py: a job token that becomes the GHCR pull token
holds no write permission (review of hosted#44).

The kind exit tests pass the job token into the install as the keyring member
GHCR_PULL_TOKEN (the env GHCR_PULL_TOKEN, or the input ghcr_pull_token of
.github/actions/demo-enrollment-install). The install copies it into the
cluster as an image pull secret. Any workload that can read that Secret then
holds the token for the rest of the job. So the token of such a job may only
read: a write permission would let a workload in the cluster push a branch or
a tag to this public repository.

The rule, for each job that passes `github.token` or `secrets.GITHUB_TOKEN`
as the pull token:
  - its permissions (the job's own, or else the workflow's) are a mapping,
    not `write-all` or `read-all`, and not absent (the default token of a
    repository can be write);
  - no scope is `write`, except `id-token`. An id-token write lets the job
    request an OIDC token through a separate runner credential, which the
    job token does not carry.

Usage:  scripts/check-pull-token-read-only.py [--selftest]
Exit:   0 clean, 1 a job breaks the rule, 2 the self-test is broken or no
        workflow was read
The fixtures are in scripts/testdata/pull-token/.
"""
from __future__ import annotations

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "scripts" / "testdata" / "pull-token"
TOKEN = re.compile(r"\$\{\{\s*(github\.token|secrets\.GITHUB_TOKEN)\s*\}\}")
KEYS = ("GHCR_PULL_TOKEN", "ghcr_pull_token")


def passes_job_token(job: dict) -> bool:
    for step in job.get("steps") or []:
        for section in ("env", "with"):
            for k, v in ((step.get(section) or {}).items()):
                if k in KEYS and isinstance(v, str) and TOKEN.search(v):
                    return True
    for k, v in ((job.get("env") or {}).items()):
        if k in KEYS and isinstance(v, str) and TOKEN.search(v):
            return True
    return False


def findings(path: pathlib.Path) -> list[str]:
    w = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    bad = []
    for name, job in (w.get("jobs") or {}).items():
        if not isinstance(job, dict) or not passes_job_token(job):
            continue
        perms = job.get("permissions", w.get("permissions"))
        where = f"{path.name} job {name}"
        if not isinstance(perms, dict):
            bad.append(f"{where}: passes its token as the pull token with permissions {perms!r}; name each scope, read only")
            continue
        writes = sorted(k for k, v in perms.items() if v == "write" and k != "id-token")
        if writes:
            bad.append(f"{where}: passes its token as the pull token and holds write on {', '.join(writes)}")
    return bad


def selftest() -> int:
    bads = sorted(FIXTURES.glob("bad-*.yml"))
    good = FIXTURES / "good.yml"
    if len(bads) < 4 or not good.is_file():
        print("check-pull-token-read-only: selftest: the fixtures are missing", file=sys.stderr)
        return 2
    for b in bads:
        if len(findings(b)) != 1:
            print(f"check-pull-token-read-only: selftest: {b.name} gave {findings(b)}, want one finding", file=sys.stderr)
            return 2
    if findings(good):
        print(f"check-pull-token-read-only: selftest: good.yml gave {findings(good)}", file=sys.stderr)
        return 2
    print(f"✅ self-test: {len(bads)} jobs that give a writable token to the cluster are refused, and a read-only one passes")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    paths = sorted((ROOT / ".github" / "workflows").glob("*.y*ml"))
    if not paths:
        print("check-pull-token-read-only: no workflow was read", file=sys.stderr)
        return 2
    bad = [f for p in paths for f in findings(p)]
    users = sum(1 for p in paths for j in ((yaml.safe_load(p.read_text()) or {}).get("jobs") or {}).values()
                if isinstance(j, dict) and passes_job_token(j))
    if bad:
        print("❌ a job token that becomes the GHCR pull token must hold no write permission:", file=sys.stderr)
        for b in bad:
            print(f"   {b}", file=sys.stderr)
        return 1
    if users == 0:
        print("check-pull-token-read-only: no job passes the job token as the pull token, so the scan read nothing",
              file=sys.stderr)
        return 1
    print(f"✅ {users} jobs pass the job token as the GHCR pull token, each with read-only permissions")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
