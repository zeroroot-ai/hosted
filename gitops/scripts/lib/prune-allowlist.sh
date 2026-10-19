# shellcheck shell=bash
# Shared reader for envs/<env>/prune-allowlist.yaml (gitops#498/#507/#522).
# Sourced, not executed.
#
# The allowlist is the reviewed, merged authorisation to delete named live
# objects on an env that deliberately runs `syncPolicy.automated.prune: false`.
# Two consumers need to answer the same question — "is THIS live orphan one we
# already agreed to remove?" — from two different directions:
#
#   check-promotion-landed.sh  fails a promotion on residue that is NOT listed
#   prune-orphans.sh           emits the scoped prune command for residue that IS
#
# so the matching key is defined once, here. Argo's `.status.resources[]` and
# the YAML entries are both normalised to
#
#     group|kind|namespace|name
#
# with an empty group for core objects and an empty namespace for cluster-scoped
# ones, which is exactly how Argo reports them (absent field, not "core"/"").
# Do not compare on rendered display strings — a `Kind/ns/name` label is lossy
# the moment two API groups ship the same kind.

# prune_key_human <key>
#
# `group|kind|namespace|name` -> the form a human reads in a failure message.
# Core objects lose the empty group segment rather than printing a bare `/`,
# and cluster-scoped ones print `-` for the namespace, matching how the rest of
# these scripts render resources.
prune_key_human() {
  local group kind namespace name
  IFS='|' read -r group kind namespace name <<<"$1"
  printf '%s%s/%s/%s' "${group:+${group}:}" "$kind" "${namespace:--}" "$name"
}

# prune_allowlist_path <env>
#
# Where an env's allowlist lives. Absent is legal and means "nothing is
# authorised for pruning here" — the strict default, and the right answer for
# every prune:true env.
prune_allowlist_path() {
  echo "envs/${1}/prune-allowlist.yaml"
}

# prune_allowlist_keys <file>
#
# One normalised key per entry, in file order. A missing file yields nothing.
prune_allowlist_keys() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  python3 - "$file" <<'PY'
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1])) or {}
for r in doc.get("resources") or []:
    print("|".join(str(r.get(f) or "") for f in ("group", "kind", "namespace", "name")))
PY
}

# prune_allowlist_validate <file>
#
# Structural validation, no cluster needed. Prints one `::error::` line per
# problem and returns 1 if any. An entry without a reason and a provenance
# trail is not a review, so those fields are required rather than encouraged.
prune_allowlist_validate() {
  local file="${1:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  python3 - "$file" <<'PY'
import sys
import yaml

path = sys.argv[1]
problems = []
try:
    doc = yaml.safe_load(open(path))
except yaml.YAMLError as exc:
    print(f"::error::{path}: not valid YAML: {exc}")
    sys.exit(1)

if doc is None:
    doc = {}
if not isinstance(doc, dict):
    problems.append("top level must be a mapping with a `resources:` list")
    doc = {}

unknown_top = set(doc) - {"resources"}
if unknown_top:
    problems.append(f"unknown top-level key(s): {', '.join(sorted(unknown_top))}")

resources = doc.get("resources")
if resources is None:
    resources = []
if not isinstance(resources, list):
    problems.append("`resources:` must be a list")
    resources = []

required = ("kind", "name", "retiredBy", "reason", "observed")
known = {"group", "kind", "namespace", "name", "retiredBy", "reason", "observed"}
seen = {}
for i, entry in enumerate(resources):
    where = f"resources[{i}]"
    if not isinstance(entry, dict):
        problems.append(f"{where}: must be a mapping")
        continue
    for field in required:
        if not str(entry.get(field) or "").strip():
            problems.append(f"{where}: missing required field `{field}`")
    unknown = set(entry) - known
    if unknown:
        problems.append(f"{where}: unknown field(s): {', '.join(sorted(unknown))}")
    key = "|".join(str(entry.get(f) or "") for f in ("group", "kind", "namespace", "name"))
    if key in seen:
        problems.append(f"{where}: duplicate of resources[{seen[key]}] ({key})")
    else:
        seen[key] = i

for p in problems:
    print(f"::error::{path}: {p}")
sys.exit(1 if problems else 0)
PY
}
