#!/usr/bin/env python3
"""Print which manager owns which field of one object (hosted#758).

Reads `kubectl get <kind> <name> -o json` on stdin. A manager name alone
does not say why Argo reads the object as OutOfSync. The field paths do:
a field that another manager changed after the Argo apply is the drift.
Status is left out. It is never part of the desired state.
"""

import json
import sys

MAX_PATHS = 40


def paths(node, prefix=""):
    """Yield the dotted field paths of a fieldsV1 tree, leaves only."""
    if not isinstance(node, dict) or not node:
        yield prefix or "(no fields)"
        return
    leaf = True
    for key, child in node.items():
        if key == ".":
            continue
        leaf = False
        if key.startswith(("k:", "v:", "i:")):
            # A list item: by key, by value or by index.
            name = "[" + key[2:] + "]"
            yield from paths(child, f"{prefix}{name}")
            continue
        name = key[2:] if key.startswith("f:") else key
        yield from paths(child, f"{prefix}.{name}" if prefix else name)
    if leaf:
        yield prefix or "(no fields)"


def main() -> int:
    try:
        d = json.load(sys.stdin)
    except json.JSONDecodeError:
        print("    the object could not be read (gone, or no access)")
        return 0
    for mf in d.get("metadata", {}).get("managedFields") or []:
        print(f"    manager={mf.get('manager')} op={mf.get('operation')}"
              f" sub={mf.get('subresource') or ''} time={mf.get('time')}")
        owned = [p for p in paths(mf.get("fieldsV1") or {})
                 if not p.startswith("status")]
        for p in owned[:MAX_PATHS]:
            print(f"      {p}")
        if len(owned) > MAX_PATHS:
            print(f"      ... and {len(owned) - MAX_PATHS} more")
    gen = d.get("metadata", {}).get("generation")
    print(f"    generation={gen} resourceVersion={d.get('metadata', {}).get('resourceVersion')}")
    if d.get("kind") == "Application":
        op = d.get("operation")
        if op:
            # Only who asked and for which revision. A manual sync can carry
            # inline Helm values in operation.sync.source, and a value there
            # can be a secret, so the rest is never printed.
            sync = op.get("sync") or {}
            print("    operation (requested, not yet taken):"
                  f" initiatedBy={json.dumps(op.get('initiatedBy'))}"
                  f" retry={json.dumps(op.get('retry'))}"
                  f" revision={sync.get('revision')} revisions={sync.get('revisions')}")
        ann = d.get("metadata", {}).get("annotations") or {}
        for k in sorted(ann):
            # An annotation key: the part before the slash names its owner.
            if k.split("/", 1)[0] == "argocd.argoproj.io":
                print(f"    annotation {k}={ann[k][:120]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
