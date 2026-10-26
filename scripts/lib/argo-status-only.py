#!/usr/bin/env python3
"""argo-status-only.py: the Applications of `kubectl get applications -o json`
with no key that can hold a source (hosted#24).

The source of an Argo Application can carry inline Helm values, and the values
can carry a secret. The spec, the requested operation, and status fields such
as sync.comparedTo, history and operationState.operation all hold a source. A
run artifact of hosted is public, so this filter keeps the name of each
Application, its managedFields (which manager wrote which field path, with no
value) and its status, and drops every key of the status that names a source
or values, at any depth.

Usage: kubectl get applications -o json | argo-status-only.py
       argo-status-only.py --selftest
"""
from __future__ import annotations

import json
import sys

DROP = {"source", "sources", "values", "valuesObject", "valueFiles", "parameters",
        "helm", "kustomize", "plugin", "directory", "fileParameters"}


def scrub(v):
    if isinstance(v, dict):
        return {k: scrub(x) for k, x in v.items() if k not in DROP}
    if isinstance(v, list):
        return [scrub(x) for x in v]
    return v


def fields(entry: dict) -> dict:
    """One managedFields entry: who wrote which field paths, and when. A path
    names a field, never its value."""
    return {k: entry.get(k) for k in ("manager", "operation", "subresource", "time", "fieldsV1")}


def status_only(doc: dict) -> dict:
    return {"items": [{"name": (i.get("metadata") or {}).get("name"),
                       # When the object was made and how often its spec
                       # changed: a recreate shows as a new creation time.
                       **{k: (i.get("metadata") or {}).get(k)
                          for k in ("creationTimestamp", "generation", "resourceVersion")},
                       "managedFields": [fields(m) for m in (i.get("metadata") or {}).get("managedFields") or []],
                       "status": scrub(i.get("status") or {})}
                      for i in doc.get("items", [])]}


def selftest() -> int:
    doc = {"items": [{"metadata": {"name": "gibson", "annotations": {"x": "y"}},
                      "spec": {"source": {"helm": {"values": "password: hunter2"}}},
                      "operation": {"sync": {"source": {"helm": {"values": "password: hunter2"}}}},
                      "status": {"sync": {"status": "Synced", "comparedTo": {"source": {"helm": {"values": "password: hunter2"}}}},
                                 "history": [{"sources": [{"helm": {"valuesObject": {"password": "hunter2"}}}]}],
                                 "operationState": {"phase": "Running", "message": "waiting",
                                                    "operation": {"sync": {"source": {"helm": {"parameters": [{"value": "hunter2"}]}}}}}}}]}
    doc["items"][0]["metadata"]["managedFields"] = [
        {"manager": "argocd-controller", "operation": "Apply", "time": "t",
         "fieldsV1": {"f:spec": {"f:sources": {}}}}]
    out = json.dumps(status_only(doc))
    doc["items"][0]["metadata"]["creationTimestamp"] = "2026-10-26T17:00:00Z"
    out = json.dumps(status_only(doc))
    if '"creationTimestamp": "2026-10-26T17:00:00Z"' not in out:
        print("argo-status-only: selftest: the creation time was lost", file=sys.stderr)
        return 2
    if '"manager": "argocd-controller"' not in out or '"f:sources"' not in out:
        print("argo-status-only: selftest: the managedFields were lost", file=sys.stderr)
        return 2
    if "hunter2" in out:
        print("argo-status-only: selftest: a value survived", file=sys.stderr)
        return 2
    if '"phase": "Running"' not in out or '"name": "gibson"' not in out or '"Synced"' not in out:
        print("argo-status-only: selftest: the status was lost", file=sys.stderr)
        return 2
    print("✅ self-test: no value survives in spec, operation, comparedTo, history or operationState; the status stays")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    try:
        doc = json.load(sys.stdin)
    except ValueError:
        print("argo-status-only: the input is not JSON", file=sys.stderr)
        return 2
    json.dump(status_only(doc), sys.stdout, indent=1)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
