#!/usr/bin/env bash
# gitops#498 + gitops#363: decide whether a promotion actually landed, from an
# `argocd app get <app> -o json` document.
#
# THE PROBLEM WITH GATING ON `Synced`
#
# staging runs `prune: false` (the gitops#448 blast-radius guard), so every
# resource whose chart source was retired stays live and keeps the Application
# OutOfSync until a deliberate, reviewed prune. After the 0.113.0 convergence
# that was 11 orphans (the Bitnami redis set, an old envoy PDB, the pre-v0.110
# setec leader-election Role/Binding). The app is Healthy, the operation
# Succeeded, every managed object matches the promoted chart — and
# `argocd app wait --sync` still never returns, because sync status reads
# OutOfSync by design. A gate that can never go green is not a gate.
#
# WHAT COUNTS AS LANDED, THEN
#
#   - the last operation Succeeded, and
#   - it ran at the revision the Application's spec asks for, and
#   - the app is Healthy, and
#   - every resource is Synced EXCEPT ones that are only OutOfSync because
#     they require pruning AND the env's prune allowlist names them.
#
# That is the criterion the 2026-08-14 promotion verification applied by hand,
# with the last clause tightened by gitops#522: this script used to tolerate
# ANY resource carrying `requiresPruning`, which is why a ConfigMap orphaned by
# a deleted dashboard template sat unnoticed until a human happened to read a
# resource list during a promotion. Reviewed residue is listed in
# `envs/<env>/prune-allowlist.yaml` and warns; unreviewed residue fails, on the
# first promotion after it appears. `scripts/prune-orphans.sh` is the other
# half — it renders the scoped `argocd app sync --prune` that clears an
# allowlisted entry, and fails on entries whose prune has already landed.
#
# It stays strict about the failure mode gitops#363 exists for: a sync that
# reports success having skipped the very resources the new chartVersion
# changed shows up here as a managed resource OutOfSync WITHOUT requiresPruning
# — which fails. Run it after a hard refresh so the comparison is fresh.
#
# Usage:
#   scripts/check-promotion-landed.sh <app-get-json-file> [<prune-allowlist>]
#   argocd app get gibson -o json | scripts/check-promotion-landed.sh -
#   scripts/check-promotion-landed.sh --selftest
#
# Omitting the allowlist means NOTHING is sanctioned — the right default for a
# prune:true env, where residue should never persist in the first place.
set -euo pipefail

# shellcheck source=scripts/lib/prune-allowlist.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/prune-allowlist.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

assert_landed() {
  local doc="$1" allowlist="${2:-}"

  local health phase op_revision spec_revision
  health="$(jq -r '.status.health.status // "Unknown"' "$doc")"
  phase="$(jq -r '.status.operationState.phase // "Unknown"' "$doc")"
  # The revision the last operation actually ran, and the one the spec asks
  # for. A promotion that reports success at the PREVIOUS revision is the
  # gitops#448 race, and it must fail here.
  #
  # MULTI-SOURCE: every Application under envs/ is multi-source (OCI chart +
  # this repo as $values), and Argo reports those in `revisions[]`, leaving the
  # singular `revision` an EMPTY STRING — not null, so a jq `//` chain happily
  # returns "" and the check fails every promotion it is asked about. Take the
  # first non-empty of both shapes. `revisions[0]` is the OCI chart source, the
  # single promotion marker (gitops#448); the $values ref is revisions[1] and
  # is not what a promotion moves.
  op_revision="$(jq -r '
    [ .status.operationState.syncResult.revisions[0]?,
      .status.operationState.syncResult.revision?,
      .status.sync.revisions[0]?,
      .status.sync.revision? ]
    | map(select(. != null and . != "")) | first // ""' "$doc")"
  spec_revision="$(jq -r '
    [ .spec.sources[0].targetRevision?, .spec.source.targetRevision? ]
    | map(select(. != null and . != "")) | first // ""' "$doc")"

  local failures=0

  if [ "$phase" != "Succeeded" ]; then
    echo "${RED}✗${NC} last operation phase is ${phase}, want Succeeded"
    failures=$((failures + 1))
  fi

  if [ "$health" != "Healthy" ]; then
    echo "${RED}✗${NC} app health is ${health}, want Healthy"
    failures=$((failures + 1))
  fi

  if [ -z "$spec_revision" ]; then
    echo "${RED}✗${NC} cannot read spec targetRevision from the document"
    failures=$((failures + 1))
  elif [ "$op_revision" != "$spec_revision" ]; then
    echo "${RED}✗${NC} the completed operation ran revision '${op_revision}', but the spec asks for '${spec_revision}' — the sync predates this promotion (gitops#448)"
    failures=$((failures + 1))
  fi

  # Managed drift: OutOfSync and NOT merely awaiting a prune.
  local drifted
  drifted="$(jq -r '
    [ .status.resources[]?
      | select((.status // "Synced") != "Synced")
      | select((.requiresPruning // false) != true)
      | "\(.kind)/\(.namespace // "-")/\(.name) [\(.status)]"
    ] | .[]' "$doc")"

  if [ -n "$drifted" ]; then
    echo "${RED}✗${NC} live objects differ from the promoted chart:"
    printf '    %s\n' "$drifted"
    failures=$((failures + 1))
  fi

  # Prune residue. Reviewed residue (named in the env's prune allowlist) warns;
  # residue nobody reviewed fails (gitops#522). Helm hooks also carry
  # `requiresPruning` but have no sync status, so the OutOfSync filter keeps
  # them out of both buckets — they are not part of the comparison and never
  # make the app OutOfSync.
  local allowed residue key sanctioned="" unsanctioned=""
  allowed="$(prune_allowlist_keys "$allowlist")"
  residue="$(jq -r '
    .status.resources[]?
    | select((.status // "Synced") != "Synced")
    | select((.requiresPruning // false) == true)
    | "\(.group // "")|\(.kind)|\(.namespace // "")|\(.name)"' "$doc")"

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if [ -n "$allowed" ] && grep -Fxq -- "$key" <<<"$allowed"; then
      sanctioned+="    $(prune_key_human "$key")"$'\n'
    else
      unsanctioned+="    $(prune_key_human "$key")"$'\n'
    fi
  done <<<"$residue"

  if [ -n "$unsanctioned" ]; then
    echo "${RED}✗${NC} live objects await a prune nobody reviewed — the chart stopped rendering them (gitops#522):"
    printf '%s' "$unsanctioned"
    echo "    → review each into ${allowlist:-envs/<env>/prune-allowlist.yaml}, then"
    echo "      gitops/scripts/prune-orphans.sh plan <env> <app.json>"
    failures=$((failures + 1))
  fi

  if [ -n "$sanctioned" ]; then
    echo "${YELLOW}!${NC} reviewed prune residue awaiting the operator command (gitops#507):"
    printf '%s' "$sanctioned"
  fi

  if [ "$failures" -ne 0 ]; then
    return 1
  fi

  echo "${GREEN}✓${NC} promotion landed: operation Succeeded at ${spec_revision}, Healthy, no unmanaged drift"
}

# ---------------------------------------------------------------------------
# selftest — fixtures for every verdict this script has to get right.
# ---------------------------------------------------------------------------
fixture() {
  # $1 phase, $2 health, $3 op revision, $4 spec revision, $5 extra resources JSON
  cat <<EOF
{
  "spec": { "sources": [ { "targetRevision": "$4" } ] },
  "status": {
    "health": { "status": "$2" },
    "operationState": { "phase": "$1", "syncResult": { "revision": "$3" } },
    "sync": { "revision": "$3" },
    "resources": $5
  }
}
EOF
}

# The shape every Application under envs/ actually has: multi-source, so the
# revision lives in `revisions[]` and the singular field is an empty string.
# Copied from a live `argocd app get gibson -o json` on staging.
multisource_fixture() { # $1 op chart revision, $2 spec targetRevision, $3 resources JSON
  cat <<EOF
{
  "spec": { "sources": [ { "targetRevision": "$2" }, { "ref": "values" } ] },
  "status": {
    "health": { "status": "Healthy" },
    "operationState": {
      "phase": "Succeeded",
      "syncResult": { "revision": "", "revisions": ["$1", "536f797a4cfff360a1613dc33bd9d104672d29b6"] }
    },
    "sync": { "revisions": ["$1", "536f797a4cfff360a1613dc33bd9d104672d29b6"] },
    "resources": $3
  }
}
EOF
}

SYNCED_ONLY='[{"kind":"Deployment","namespace":"gibson","name":"gibson","status":"Synced"}]'
PRUNE_RESIDUE='[{"kind":"Deployment","namespace":"gibson","name":"gibson","status":"Synced"},
  {"group":"apps","kind":"StatefulSet","namespace":"gibson","name":"gibson-redis-master","status":"OutOfSync","requiresPruning":true},
  {"group":"policy","kind":"PodDisruptionBudget","namespace":"gibson","name":"gibson-envoy","status":"OutOfSync","requiresPruning":true}]'
REAL_DRIFT='[{"kind":"Deployment","namespace":"gibson","name":"gibson","status":"Synced"},
  {"kind":"ConfigMap","namespace":"gibson","name":"gibson-envoy","status":"OutOfSync"},
  {"group":"apps","kind":"StatefulSet","namespace":"gibson","name":"gibson-redis-master","status":"OutOfSync","requiresPruning":true}]'
# Bringup Jobs and their RBAC are Helm hooks: `requiresPruning` forever, no
# sync status, not part of the comparison. Live staging carries 21 of them.
HOOKS='[{"kind":"Deployment","namespace":"gibson","name":"gibson","status":"Synced"},
  {"group":"batch","kind":"Job","namespace":"gibson","name":"gibson-zitadel-init","requiresPruning":true},
  {"kind":"ServiceAccount","namespace":"gibson","name":"postgres-exec","requiresPruning":true}]'

# The allowlist that sanctions exactly the two objects in PRUNE_RESIDUE.
RESIDUE_ALLOWLIST='resources:
  - group: apps
    kind: StatefulSet
    namespace: gibson
    name: gibson-redis-master
    retiredBy: deploy#1343
    reason: bitnami redis dependency deleted
    observed: "2026-08-14"
  - group: policy
    kind: PodDisruptionBudget
    namespace: gibson
    name: gibson-envoy
    retiredBy: gitops#381
    reason: single-replica PDB retired
    observed: "2026-08-14"'

selftest() {
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  local failures=0

  check() { # name, expected exit, fixture file, [grep pattern], [allowlist file]
    local name="$1" want="$2" file="$3" pattern="${4:-}" allowlist="${5:-}"
    local out rc
    set +e
    out="$(assert_landed "$file" "$allowlist" 2>&1)"; rc=$?
    set -e
    if [ "$rc" -ne "$want" ]; then
      echo "::error::[selftest] ${name}: exit ${rc}, want ${want}"
      printf '%s\n' "${out//$'\n'/$'\n'}"
      failures=$((failures + 1))
      return
    fi
    if [ -n "$pattern" ] && ! grep -q "$pattern" <<<"$out"; then
      echo "::error::[selftest] ${name}: output missing /${pattern}/"
      printf '%s\n' "${out//$'\n'/$'\n'}"
      failures=$((failures + 1))
    fi
  }

  fixture Succeeded Healthy 0.113.0 0.113.0 "$SYNCED_ONLY"   >"$tmp/clean.json"
  fixture Succeeded Healthy 0.113.0 0.113.0 "$PRUNE_RESIDUE" >"$tmp/residue.json"
  fixture Succeeded Healthy 0.113.0 0.113.0 "$REAL_DRIFT"    >"$tmp/drift.json"
  fixture Succeeded Healthy 0.109.2 0.113.0 "$SYNCED_ONLY"   >"$tmp/stale.json"
  fixture Failed    Healthy 0.113.0 0.113.0 "$SYNCED_ONLY"   >"$tmp/failedop.json"
  fixture Succeeded Degraded 0.113.0 0.113.0 "$SYNCED_ONLY"  >"$tmp/degraded.json"
  fixture Succeeded Healthy 0.113.0 0.113.0 "$HOOKS"         >"$tmp/hooks.json"
  printf '%s\n' "$RESIDUE_ALLOWLIST" >"$tmp/allowlist.yaml"
  printf 'resources: []\n'           >"$tmp/empty-allowlist.yaml"

  # Everything synced -> pass.
  check "fully synced" 0 "$tmp/clean.json" "promotion landed"
  # THE POINT (gitops#498): reviewed prune residue is not a failed promotion.
  check "reviewed prune residue" 0 "$tmp/residue.json" "reviewed prune residue" "$tmp/allowlist.yaml"
  # THE gitops#522 POINT: residue nobody reviewed IS a failed promotion — that
  # is the only thing that would have caught the orphaned dashboard ConfigMap
  # before a human happened to read a resource list.
  check "unreviewed prune residue" 1 "$tmp/residue.json" "nobody reviewed" "$tmp/empty-allowlist.yaml"
  check "no allowlist sanctions nothing" 1 "$tmp/residue.json" "nobody reviewed"
  # Helm hooks carry requiresPruning forever and are NOT part of the sync
  # comparison. Treating them as residue would fail every promotion.
  check "helm hooks are not residue" 0 "$tmp/hooks.json" "promotion landed"
  # THE OTHER POINT (gitops#363): real drift still fails, even next to residue.
  check "managed drift beside residue" 1 "$tmp/drift.json" "ConfigMap/gibson/gibson-envoy" "$tmp/allowlist.yaml"
  # gitops#448: a success reported at the previous revision is not a promotion.
  check "operation at a stale revision" 1 "$tmp/stale.json" "predates this promotion"

  # Multi-source is not a variant here, it is THE shape: with the singular
  # `revision` field empty on every real Application, reading it alone made the
  # revision assertion fail every promotion it was pointed at.
  multisource_fixture 0.115.0 0.115.0 "$SYNCED_ONLY" >"$tmp/multi.json"
  multisource_fixture 0.114.0 0.115.0 "$SYNCED_ONLY" >"$tmp/multi-stale.json"
  check "multi-source promotion landed" 0 "$tmp/multi.json" "operation Succeeded at 0.115.0"
  check "multi-source at a stale chart revision" 1 "$tmp/multi-stale.json" "ran revision '0.114.0'"
  check "failed operation" 1 "$tmp/failedop.json" "phase is Failed"
  check "degraded health" 1 "$tmp/degraded.json" "health is Degraded"

  if [ "$failures" -ne 0 ]; then
    echo "[selftest] ${failures} case(s) failed"
    return 1
  fi
  echo "[selftest] every promotion verdict behaves"
}

main() {
  case "${1:-}" in
    --selftest) selftest ;;
    "" | -h | --help)
      echo "usage: $0 <app-get-json|-> [<prune-allowlist>] | $0 --selftest" >&2
      exit 2
      ;;
    -)
      tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT; cat >"$tmp"
      assert_landed "$tmp" "${2:-}"
      ;;
    *) assert_landed "$1" "${2:-}" ;;
  esac
}

main "$@"
