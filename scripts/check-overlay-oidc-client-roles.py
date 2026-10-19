#!/usr/bin/env python3
"""check-overlay-oidc-client-roles.py: every overlay OIDC client declares its roles (hosted#191, hosted#207).

WHY THIS EXISTS
gibson's platform-operator grants a machine user exactly the Zitadel roles its
OIDCClient lists, and revokes every other role. An empty or missing list means
no role. A Helm values overlay that sets platformBootstrap.oidcClients replaces
the chart's whole list, so an overlay entry without `roles` silently drops the
chart's roles. On 2026-09-26 every gitops overlay did that: promoting the chart
would have left the daemon and the tenant-operator with no Zitadel role.

hosted#199 and hosted#200 then narrowed gibson-daemon and gibson-tenant-operator
to IAM_ORG_MANAGER in every overlay (hosted#219). Nothing stopped a later
overlay edit from putting IAM_OWNER, or another instance-administrator role,
back on one of them, or handing one to a new entry. This guard makes that a
build failure the same way charts' own check-instance-admin-roles-scoped.py
does for the chart's values.

WHAT IT CHECKS
  Every values file under gitops/ that sets oidcClients:
    1. each entry has a literal `roles` key. An empty list is a deliberate
       answer and passes.
    2. no entry's `roles` contains an instance-administrator role (IAM_OWNER,
       IAM_OWNER_VIEWER, IAM_ADMIN_IMPERSONATOR, IAM_END_USER_IMPERSONATOR,
       SYSTEM_OWNER). No overlay OIDCClient is a bootstrap identity — the one
       bootstrap identity (gibson-system-bot) is provisioned through
       SystemAPIUsers, which no overlay here sets.

USAGE
  scripts/check-overlay-oidc-client-roles.py             check gitops/
  scripts/check-overlay-oidc-client-roles.py --selftest  prove a missing key and a leaked admin role both fail
Exit: 0 pass · 1 a problem found · 2 self-test broke
"""
from __future__ import annotations

import glob
import os
import sys
import tempfile

import yaml

INSTANCE_ADMIN_ROLES = {
    "IAM_OWNER",
    "IAM_OWNER_VIEWER",
    "IAM_ADMIN_IMPERSONATOR",
    "IAM_END_USER_IMPERSONATOR",
    "SYSTEM_OWNER",
}


def _clients(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "oidcClients" and isinstance(value, list):
                yield value
            else:
                yield from _clients(value)
    elif isinstance(node, list):
        for item in node:
            yield from _clients(item)


def check(root: str) -> list[str]:
    problems: list[str] = []
    for path in sorted(glob.glob(os.path.join(root, "gitops", "**", "*.yaml"), recursive=True)):
        with open(path, encoding="utf-8") as f:
            try:
                docs = list(yaml.safe_load_all(f))
            except yaml.YAMLError:
                continue
        for doc in docs:
            for clients in _clients(doc):
                for i, client in enumerate(clients):
                    name = client.get("name") if isinstance(client, dict) else None
                    if not isinstance(client, dict) or "roles" not in client:
                        problems.append(f"{path}: oidcClients[{name or i}] has no `roles` key "
                                        "(use roles: [] for none; an overlay list replaces the chart's)")
                        continue
                    roles = client.get("roles") or []
                    bad = sorted(set(roles) & INSTANCE_ADMIN_ROLES)
                    if bad:
                        problems.append(f"{path}: oidcClients[{name or i}] declares "
                                        f"instance-administrator role(s) {bad}")
    return problems


def selftest() -> int:
    cases = {
        "all_declared": ([{"name": "gibson-daemon", "roles": ["IAM_ORG_MANAGER"]},
                          {"name": "gibson-dashboard", "roles": []}], True),
        "one_missing": ([{"name": "gibson-daemon", "roles": ["IAM_ORG_MANAGER"]},
                         {"name": "gibson-tenant-operator", "applicationType": "MACHINE_USER"}], False),
        "nested_missing": ([{"name": "gibson-native-login"}], False),
        "admin_role_leaks_back_in": ([{"name": "gibson-daemon", "roles": ["IAM_OWNER"]}], False),
        "admin_impersonator": ([{"name": "gibson-tenant-operator", "roles": ["IAM_ADMIN_IMPERSONATOR"]}], False),
    }
    for name, (clients, want_ok) in cases.items():
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "gitops", "envs", "x"))
            with open(os.path.join(d, "gitops", "envs", "x", "values.yaml"), "w", encoding="utf-8") as f:
                yaml.safe_dump({"gibson": {"platformBootstrap": {"oidcClients": clients}}}, f)
            got_ok = not check(d)
            if got_ok != want_ok:
                print(f"GUARD BROKEN: fixture {name} expected {'pass' if want_ok else 'fail'}", file=sys.stderr)
                return 2
    print("✅ self-test: an overlay OIDC client without `roles`, or declaring an instance-administrator role, is rejected")
    return 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    problems = check(".")
    if problems:
        print("❌ an overlay OIDC client has no `roles`, or declares an instance-administrator role")
        for p in problems:
            print("   " + p)
        return 1
    print("✅ every overlay OIDC client declares its roles, and none declares an instance-administrator role")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
