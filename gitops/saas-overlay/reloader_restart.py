#!/usr/bin/env python3
"""reloader_restart.py — the workloads identity policy of a SaaS overlay
admits a restart-only UPDATE by Reloader.

Reloader restarts the overlay Deployment when its Postgres login role
changes (ADR-0171). Without this rule the policy refused the restart, and
Reloader v1.4.6 stops its whole pass on the first refused update, so no
consumer of the login role restarted (drill rotation run 40478619844).

Usage: reloader_restart.py <rendered.yaml> <policy name> <namespace>
Exit:  0 the rule is there, 1 it is not (the reason on stderr)
"""
import sys

import yaml

CLAUSES = (
    "request.operation == 'UPDATE'",
    "!has(object.spec.jobTemplate)",
    "object.spec.template.spec == oldObject.spec.template.spec",
    "object.spec.template.metadata.labels",
    "oldObject.spec.template.metadata.labels",
)


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    path, name, ns = argv[1:]
    principal = '"system:serviceaccount:%s:reloader"' % ns
    for doc in yaml.safe_load_all(open(path)):
        if not doc or doc.get("kind") != "ValidatingAdmissionPolicy" or doc["metadata"]["name"] != name:
            continue
        spec = doc["spec"]
        rule = {v["name"]: v["expression"] for v in spec.get("variables") or []}.get("restartOnly")
        if rule is None:
            print("%s: no variable restartOnly" % name, file=sys.stderr)
            return 1
        missing = [c for c in CLAUSES + ("request.userInfo.username == " + principal,) if c not in rule]
        if missing:
            print("%s: restartOnly lacks %s" % (name, missing), file=sys.stderr)
            return 1
        if not any("|| variables.restartOnly" in v["expression"] for v in spec.get("validations") or []):
            print("%s: no validation admits variables.restartOnly" % name, file=sys.stderr)
            return 1
        return 0
    print("%s: no such ValidatingAdmissionPolicy in %s" % (name, path), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
