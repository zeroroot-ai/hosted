#!/usr/bin/env python3
"""check-csi-excludes.py: each pod of a rendered overlay that mounts a SPIFFE
CSI volume keeps it out of the Velero backup.

Velero copies pod volumes as files. A volume of the driver csi.spiffe.io holds
the socket of the SPIRE agent, never data, and a restored pod gets a new one
from the driver. A backup that holds it makes the restore stop at the volume
with no class (drill run 39448187284, hosted#83). The pod template names the
volume in the annotation backup.velero.io/backup-volumes-excludes.

Usage: check-csi-excludes.py <rendered.yaml>
Exit:  0 every such volume is excluded, 1 one is not, 2 no pod had one (the
       scan read nothing)
"""
import sys

import yaml

ANN = "backup.velero.io/backup-volumes-excludes"


def main(path: str) -> int:
    bad, seen = [], 0
    for doc in yaml.safe_load_all(open(path)):
        if not doc or doc.get("kind") not in ("Deployment", "StatefulSet", "DaemonSet"):
            continue
        tpl = (doc.get("spec") or {}).get("template") or {}
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
    print(f"ok {seen} SPIFFE CSI volume(s), each kept out of the backup")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
