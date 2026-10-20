#!/usr/bin/env python3
"""check-csi-excludes.py: each pod of a rendered overlay that mounts a SPIFFE
CSI volume keeps it out of the Velero backup.

Velero copies pod volumes as files. A volume of the driver csi.spiffe.io holds
the socket of the SPIRE agent, never data, and a restored pod gets a new one
from the driver. A backup that holds it makes the restore stop at the volume
with no class (drill run 39448187284, hosted#83). The pod template names the
volume in the annotation backup.velero.io/backup-volumes-excludes.

The pod template is read from each kind that has one: spec.template of a
Deployment, StatefulSet, DaemonSet, ReplicaSet and Job, spec.jobTemplate.spec.template
of a CronJob, and the Pod itself.

Usage: check-csi-excludes.py <rendered.yaml> [--expect N]
Exit:  0 every such volume is excluded (and, with --expect, there are N of
       them), 1 a volume is not excluded or the count differs, 2 the input
       is missing or is not YAML, or no pod had such a volume (the scan read
       nothing)
"""
import sys

import yaml

ANN = "backup.velero.io/backup-volumes-excludes"


def template_of(doc: dict):
    """The pod (metadata and spec) of a workload, or None."""
    kind, spec = doc.get("kind"), doc.get("spec") or {}
    if kind == "Pod":
        return doc
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        return spec.get("template") or {}
    if kind == "CronJob":
        return ((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}
    return None


def main(path: str, expect: int | None) -> int:
    try:
        docs = list(yaml.safe_load_all(open(path)))
    except (OSError, yaml.YAMLError) as e:
        print(f"check-csi-excludes: cannot read {path}: {e}", file=sys.stderr)
        return 2
    bad, seen = [], 0
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        tpl = template_of(doc)
        if tpl is None:
            continue
        excluded = {v.strip() for v in (((tpl.get("metadata") or {}).get("annotations") or {}).get(ANN, "")).split(",")}
        for vol in (tpl.get("spec") or {}).get("volumes") or []:
            if (vol.get("csi") or {}).get("driver") == "csi.spiffe.io":
                seen += 1
                if vol["name"] not in excluded:
                    bad.append(f"{doc['kind']}/{doc['metadata']['name']}: volume {vol['name']} is not in {ANN}")
    if bad:
        print("\n".join(bad), file=sys.stderr)
        return 1
    if seen == 0:
        print("no pod mounts a SPIFFE CSI volume, so the scan read nothing", file=sys.stderr)
        return 2
    if expect is not None and seen != expect:
        print(f"{seen} SPIFFE CSI volume(s) found, {expect} expected: a pod lost its volume, or a new one needs a decision", file=sys.stderr)
        return 1
    print(f"ok {seen} SPIFFE CSI volume(s), each kept out of the backup")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    want = None
    if "--expect" in args:
        i = args.index("--expect")
        want = int(args[i + 1])
        del args[i:i + 2]
    if len(args) != 1:
        print("usage: check-csi-excludes.py <rendered.yaml> [--expect N]", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(args[0], want))
