#!/usr/bin/env bash
# gitops#498 / #507 / #522: the deliberate-prune mechanism for an env that runs
# `syncPolicy.automated.prune: false`.
#
# THE GAP THIS CLOSES
#
# `envs/staging/gibson.yaml` sets `prune: false` on purpose (the gitops#448
# blast-radius guard: a fast selfHeal path must never delete on a transient or
# misread diff) and says "pruning stays a deliberate, reviewed action via the
# manual promotion flow instead." That flow contained no prune step — `grep -i
# prune` over the workflows and scripts matched nothing (gitops#507). So every
# retired chart source left a live object that Argo owns, reports extraneous,
# and can never remove: 11 after the 0.113.0 convergence (#498), a twelfth from
# a deleted dashboard template (#522), each found by a human squinting at a
# resource list.
#
# THE MECHANISM
#
# `envs/<env>/prune-allowlist.yaml` is the review: a merged entry authorises
# deleting exactly one named live object. This script is the two halves that
# make the authorisation real.
#
#   audit  — fail when live prune residue is NOT allowlisted (an orphan nobody
#            reviewed), and when an allowlist entry matches nothing live (the
#            prune landed; the entry is now debt). Consumed by
#            check-promotion-landed.sh, which used to wave through ANY
#            `requiresPruning` resource — which is why #522 went unnoticed.
#   plan   — render the exact, scoped `argocd app sync --prune --resource ...`
#            for the allowlisted-and-still-live intersection.
#
# It never touches a cluster. `plan` prints a command; a human runs it.
#
# WHY SCOPED SYNC AND NOT A POLICY FLIP
#
# `automated.prune: false` governs AUTOMATED syncs only — a manual sync may
# still prune, and `--resource` bounds it to exactly the named objects. So the
# blast-radius guard stays exactly as it is: no window in which the automated
# path is allowed to delete anything.
#
# Usage:
#   gitops/scripts/prune-orphans.sh plan  <env> <app-get-json|->
#   gitops/scripts/prune-orphans.sh audit <env> <app-get-json|->
#   gitops/scripts/prune-orphans.sh --lint [<repo-root>]
#   gitops/scripts/prune-orphans.sh --selftest
#
# Get the app document with:
#   argocd app get gibson --hard-refresh -o json > app.json
# (hard-refresh matters: `.status.resources[]` is otherwise a cached verdict —
# the gitops#363 lesson.)
#
# Requires: jq, python3 (+pyyaml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/prune-allowlist.sh
. "${HERE}/lib/prune-allowlist.sh"

# envs/<env>/ is relative to the gitops root, so run from there whatever the
# caller's directory is. Measured 2026-10-02: an `audit` run from the repo root
# read ZERO allowlist entries, because envs/ did not resolve, and reported four
# reviewed orphans as "a prune that nobody reviewed". A path that silently
# resolves to nothing must not read as an empty authorisation.
cd "${HERE}/.."

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

APP="${APP:-gibson}"

# ---------------------------------------------------------------------------
# live residue
# ---------------------------------------------------------------------------

# residue_keys <app-json>
#
# The live objects Argo holds the app OutOfSync over purely because they want
# pruning. Helm hooks also carry `requiresPruning: true` but have NO sync
# status — they are not part of the comparison and never make the app
# OutOfSync, so they must not be planned for deletion or reported as drift.
# The `(.status // "Synced") != "Synced"` filter is what excludes them, and it
# is the same filter check-promotion-landed.sh uses.
residue_keys() {
  jq -r '
    .status.resources[]?
    | select((.status // "Synced") != "Synced")
    | select((.requiresPruning // false) == true)
    | "\(.group // "")|\(.kind)|\(.namespace // "")|\(.name)"
  ' "$1"
}

# selector <key>
#
# Argo's `--resource` form: GROUP:KIND:NAME, with NAMESPACE/NAME for namespaced
# objects and a blank group for core ones.
selector() {
  local group kind namespace name
  IFS='|' read -r group kind namespace name <<<"$1"
  if [ -n "$namespace" ]; then
    printf '%s:%s:%s/%s' "$group" "$kind" "$namespace" "$name"
  else
    printf '%s:%s:%s' "$group" "$kind" "$name"
  fi
}

human() { prune_key_human "$1"; }

# ---------------------------------------------------------------------------
# audit / plan
# ---------------------------------------------------------------------------

# compare <allowlist-file> <app-json>
#
# Sets the globals SANCTIONED / UNSANCTIONED / STALE (newline-separated keys).
compare() {
  local allowlist="$1" doc="$2"
  local allowed live key
  allowed="$(prune_allowlist_keys "$allowlist")"
  live="$(residue_keys "$doc")"

  SANCTIONED=""; UNSANCTIONED=""; STALE=""

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if [ -n "$allowed" ] && grep -Fxq -- "$key" <<<"$allowed"; then
      SANCTIONED+="${key}"$'\n'
    else
      UNSANCTIONED+="${key}"$'\n'
    fi
  done <<<"$live"

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if [ -z "$live" ] || ! grep -Fxq -- "$key" <<<"$live"; then
      STALE+="${key}"$'\n'
    fi
  done <<<"$allowed"
}

report_lines() { # prefix, keys
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '    %s\n' "$(human "$key")"
  done <<<"$2"
}

audit() {
  local env="$1" doc="$2"
  local allowlist; allowlist="$(prune_allowlist_path "$env")"
  compare "$allowlist" "$doc"
  local failures=0

  if [ -n "$UNSANCTIONED" ]; then
    echo "${RED}✗${NC} live objects await a prune that nobody reviewed:"
    report_lines "" "$UNSANCTIONED"
    echo "    → the chart stopped rendering them and ${env} runs prune:false, so they"
    echo "      persist forever. Review each into gitops/${allowlist} (that IS the review),"
    echo "      or find out why the chart dropped them."
    failures=$((failures + 1))
  fi

  if [ -n "$STALE" ]; then
    echo "${RED}✗${NC} allowlist entries match nothing live — the prune has landed:"
    report_lines "" "$STALE"
    echo "    → delete them from gitops/${allowlist}. A standing authorisation to delete an"
    echo "      object that no longer exists is a licence waiting for a name collision."
    failures=$((failures + 1))
  fi

  if [ -n "$SANCTIONED" ]; then
    echo "${YELLOW}!${NC} reviewed prune residue, still awaiting the operator command:"
    report_lines "" "$SANCTIONED"
    echo "    → gitops/scripts/prune-orphans.sh plan ${env} <app.json>"
  fi

  [ "$failures" -eq 0 ] || return 1
  echo "${GREEN}✓${NC} prune residue on ${env} is exactly what gitops/${allowlist} authorises"
}

plan() {
  local env="$1" doc="$2"
  local allowlist; allowlist="$(prune_allowlist_path "$env")"
  compare "$allowlist" "$doc"

  if [ -n "$UNSANCTIONED" ]; then
    echo "${YELLOW}!${NC} NOT in the plan — live orphans this allowlist does not authorise:"
    report_lines "" "$UNSANCTIONED"
    echo "    → review them into gitops/${allowlist} first; this plan will not delete them."
  fi
  if [ -n "$STALE" ]; then
    echo "${YELLOW}!${NC} allowlist entries with nothing live behind them (already pruned?):"
    report_lines "" "$STALE"
    echo "    → delete them from gitops/${allowlist}."
  fi

  if [ -z "$SANCTIONED" ]; then
    echo "${GREEN}✓${NC} nothing to prune on ${env}"
    return 0
  fi

  local args="" key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    args+=" \\"$'\n'"    --resource '$(selector "$key")'"
  done <<<"$SANCTIONED"

  cat <<EOF
Run these on ${env}, in order, as a human with argocd creds (gitops#507):

  # 1. preview — must list ONLY the resources above, and only as pruned
  argocd app sync ${APP} --grpc-web --prune --dry-run${args}

  # 2. the prune itself
  argocd app sync ${APP} --grpc-web --prune${args}

  # 3. verify: the objects are gone and the app is Synced
  argocd app get ${APP} --hard-refresh --grpc-web -o json > /tmp/${APP}-app.json
  gitops/scripts/prune-orphans.sh audit ${env} /tmp/${APP}-app.json   # fails until the entries are deleted
  gitops/scripts/check-promotion-landed.sh /tmp/${APP}-app.json gitops/envs/${env}/prune-allowlist.yaml

Then open the PR that deletes the pruned entries from gitops/envs/${env}/prune-allowlist.yaml.
EOF
}

# ---------------------------------------------------------------------------
# lint — static, no cluster
# ---------------------------------------------------------------------------

# app_prune <application-yaml> — "true" / "false" / "" (no automated policy)
app_prune() {
  python3 - "$1" <<'PY'
import sys
import yaml

for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(doc, dict) or doc.get("kind") != "Application":
        continue
    automated = ((doc.get("spec") or {}).get("syncPolicy") or {}).get("automated")
    if isinstance(automated, dict) and "prune" in automated:
        print("true" if automated["prune"] else "false")
    break
PY
}

lint() {
  local root="${1:-.}"
  local failures=0 scanned=0 env_dir env app_file prune allowlist candidate

  for env_dir in "${root}"/envs/*/; do
    [ -d "$env_dir" ] || continue
    scanned=$((scanned + 1))
    env="$(basename "$env_dir")"
    app_file=""
    for candidate in "${env_dir}gibson.yaml" "${env_dir}apps/gibson.yaml"; do
      [ -f "$candidate" ] && { app_file="$candidate"; break; }
    done
    allowlist="${env_dir}prune-allowlist.yaml"

    if [ -z "$app_file" ]; then
      if [ -f "$allowlist" ]; then
        echo "::error::${allowlist}: no gibson Application in envs/${env}/ to prune against"
        failures=$((failures + 1))
      fi
      continue
    fi

    prune="$(app_prune "$app_file")"

    if [ "$prune" = "false" ] && [ ! -f "$allowlist" ]; then
      echo "::error::${app_file}: runs automated.prune:false but envs/${env}/ has no prune-allowlist.yaml — retired chart sources would strand OutOfSync forever with no reviewed way to remove them (gitops#507)"
      failures=$((failures + 1))
    fi

    if [ "$prune" != "false" ] && [ -f "$allowlist" ]; then
      echo "::error::${allowlist}: envs/${env}/ prunes automatically (prune:${prune:-unset}), so a deliberate-prune allowlist is dead weight that will read as sanctioned drift — delete it"
      failures=$((failures + 1))
    fi

    prune_allowlist_validate "$allowlist" || failures=$((failures + 1))
  done

  # A lint that found no env at all is not a pass, it is a lost path. The
  # `envs/<env>/` lookup is relative, so a wrong root reports "all clear" over
  # nothing — which is how an `audit` run from the repo root read ZERO
  # allowlist entries and called four reviewed orphans unreviewed.
  if [ "$scanned" -eq 0 ]; then
    echo "${RED}✗${NC} no envs/<env>/ directories under ${root} — refusing to report a vacuous pass"
    return 1
  fi

  [ "$failures" -eq 0 ] || { echo "${RED}✗${NC} ${failures} prune-allowlist problem(s)"; return 1; }
  echo "${GREEN}✓${NC} ${scanned} env(s) scanned: every prune:false env has a valid, reviewed prune allowlist"
}

# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------

app_fixture() { # $1 resources JSON
  cat <<EOF
{ "status": { "resources": $1 } }
EOF
}

ORPHAN='{"kind":"ConfigMap","namespace":"gibson","name":"gibson-gibson-workloads-dashboard-spiffe-helper-conf","status":"OutOfSync","requiresPruning":true}'
CLUSTER_ORPHAN='{"group":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"gibson-velero-legacy","status":"OutOfSync","requiresPruning":true}'
HOOK='{"group":"batch","kind":"Job","namespace":"gibson","name":"gibson-zitadel-init","requiresPruning":true}'
SYNCED='{"kind":"Deployment","namespace":"gibson","name":"gibson","status":"Synced"}'

allowlist_fixture() { # $1 target file, $2 entries YAML (may be empty)
  {
    echo "resources:"
    if [ -n "$2" ]; then printf '%s\n' "$2"; fi
  } >"$1"
}

ENTRY_CM='  - group: ""
    kind: ConfigMap
    namespace: gibson
    name: gibson-gibson-workloads-dashboard-spiffe-helper-conf
    retiredBy: deploy#1536
    reason: dashboard spiffe-helper codepath deleted
    observed: "2026-08-15"'

selftest() {
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  local failures=0

  check() { # name, expected exit, pattern, command...
    local name="$1" want="$2" pattern="$3"; shift 3
    local out rc
    set +e
    out="$("$@" 2>&1)"; rc=$?
    set -e
    if [ "$rc" -ne "$want" ]; then
      echo "::error::[selftest] ${name}: exit ${rc}, want ${want}"
      printf '%s\n' "$out"
      failures=$((failures + 1))
      return
    fi
    if [ -n "$pattern" ] && ! grep -q -- "$pattern" <<<"$out"; then
      echo "::error::[selftest] ${name}: output missing /${pattern}/"
      printf '%s\n' "$out"
      failures=$((failures + 1))
    fi
  }

  # --- audit / plan, against a fake envs/ tree -----------------------------
  mkdir -p "$tmp/envs/staging"
  app_fixture "[$SYNCED,$HOOK]"           >"$tmp/hooks-only.json"
  app_fixture "[$SYNCED,$HOOK,$ORPHAN]"   >"$tmp/orphan.json"
  app_fixture "[$SYNCED,$CLUSTER_ORPHAN]" >"$tmp/cluster-orphan.json"

  # Run the real code paths in a subshell rooted at the fake tree, so the
  # relative envs/<env>/prune-allowlist.yaml lookup is exercised for real.
  run_in() { ( cd "$tmp" && "$@" ); }

  allowlist_fixture "$tmp/envs/staging/prune-allowlist.yaml" ""
  # A Helm hook carries requiresPruning but no sync status: not residue, so an
  # EMPTY allowlist is still correct. If this ever fails, the app would be
  # reported as drifting on every bringup Job it has ever run.
  check "hooks are never residue" 0 "exactly what" run_in audit staging hooks-only.json
  # THE #522 CASE: an orphan nobody reviewed must fail, not warn.
  check "unreviewed orphan fails" 1 "nobody reviewed" run_in audit staging orphan.json

  allowlist_fixture "$tmp/envs/staging/prune-allowlist.yaml" "$ENTRY_CM"
  # THE POINT: once reviewed and merged, the same orphan passes.
  check "reviewed orphan passes" 0 "awaiting the operator command" run_in audit staging orphan.json
  # THE DIRECTORY CASE: envs/<env>/ is relative, so the script roots itself at
  # the gitops directory rather than trusting the caller's. Run as a
  # subprocess from elsewhere, `audit` must reach the real envs/ tree and give
  # the same verdict it gives from the gitops root. Before this, the same
  # command from the repo root read no allowlist at all and called every
  # reviewed orphan unreviewed.
  check "audit reaches envs/ from any directory" 1 "nobody reviewed" \
    env -C "$tmp" bash "${HERE}/prune-orphans.sh" audit staging "$tmp/orphan.json"

  # And a lint rooted where there is no envs/ tree must refuse rather than
  # report all-clear over nothing. The copy puts HERE/.. somewhere empty.
  mkdir -p "$tmp/copy/scripts/lib"
  cp "${HERE}/prune-orphans.sh" "$tmp/copy/scripts/"
  cp "${HERE}/lib/prune-allowlist.sh" "$tmp/copy/scripts/lib/"
  check "a lint that scanned no env refuses" 1 "vacuous pass" \
    bash "$tmp/copy/scripts/prune-orphans.sh" --lint

  # A STALE ENTRY IS A FAILURE — the debt cannot outlive the prune.
  check "stale entry fails" 1 "the prune has landed" run_in audit staging hooks-only.json
  # The plan renders Argo's selector exactly; a typo here deletes nothing (or,
  # with a wildcard, far too much).
  check "plan emits the scoped selector" 0 ":ConfigMap:gibson/gibson-gibson-workloads-dashboard-spiffe-helper-conf" run_in plan staging orphan.json
  check "plan previews before it prunes" 0 "dry-run" run_in plan staging orphan.json
  check "plan is empty without residue" 0 "nothing to prune" run_in plan staging cluster-orphan.json
  # Cluster-scoped objects have no namespace segment in the selector.
  allowlist_fixture "$tmp/envs/staging/prune-allowlist.yaml" '  - group: rbac.authorization.k8s.io
    kind: ClusterRole
    name: gibson-velero-legacy
    retiredBy: deploy#0000
    reason: fixture
    observed: "2026-08-15"'
  check "cluster-scoped selector omits the namespace" 0 "rbac.authorization.k8s.io:ClusterRole:gibson-velero-legacy" run_in plan staging cluster-orphan.json

  # --- lint ---------------------------------------------------------------
  local root="$tmp/lintroot"
  mk_app() { # $1 env, $2 prune
    mkdir -p "${root}/envs/${1}"
    cat >"${root}/envs/${1}/gibson.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: gibson, namespace: argocd }
spec:
  syncPolicy:
    automated:
      prune: ${2}
      selfHeal: true
EOF
  }

  rm -rf "$root"; mk_app staging false
  # The gitops#507 hole itself: prune:false with no reviewed way to prune.
  check "prune:false without an allowlist fails" 1 "no prune-allowlist.yaml" lint "$root"

  allowlist_fixture "${root}/envs/staging/prune-allowlist.yaml" "$ENTRY_CM"
  check "prune:false with an allowlist passes" 0 "every prune:false env" lint "$root"

  rm -rf "$root"; mk_app prod true
  allowlist_fixture "${root}/envs/prod/prune-allowlist.yaml" "$ENTRY_CM"
  # An allowlist on a prune:true env sanctions drift that Argo already removes.
  check "allowlist on a prune:true env fails" 1 "dead weight" lint "$root"

  rm -rf "$root"; mk_app staging false
  allowlist_fixture "${root}/envs/staging/prune-allowlist.yaml" '  - kind: ConfigMap
    name: half-an-entry'
  check "entry without a reason fails" 1 "missing required field" lint "$root"

  rm -rf "$root"; mk_app staging false
  allowlist_fixture "${root}/envs/staging/prune-allowlist.yaml" "${ENTRY_CM}
${ENTRY_CM}"
  check "duplicate entries fail" 1 "duplicate of" lint "$root"

  rm -rf "$root"; mk_app staging false
  allowlist_fixture "${root}/envs/staging/prune-allowlist.yaml" '  - kind: ConfigMap
    name: typo
    namesapce: gibson
    retiredBy: x#1
    reason: y
    observed: "2026-08-15"'
  # A misspelled field would silently widen the match to every namespace.
  check "unknown field fails" 1 "unknown field" lint "$root"

  # The repo's own files must pass their own guard.
  check "this repo lints clean" 0 "every prune:false env" lint "${HERE}/.."

  if [ "$failures" -ne 0 ]; then
    echo "[selftest] ${failures} case(s) failed"
    return 1
  fi
  echo "[selftest] the deliberate-prune mechanism behaves"
}

# ---------------------------------------------------------------------------

read_doc() { # "-" or a path -> a path
  if [ "$1" = "-" ]; then
    DOC_TMP="$(mktemp)"; cat >"$DOC_TMP"; echo "$DOC_TMP"
  else
    echo "$1"
  fi
}

usage() {
  cat >&2 <<EOF
usage:
  $0 plan  <env> <app-get-json|->    render the scoped argocd prune command
  $0 audit <env> <app-get-json|->    fail on unreviewed residue or stale entries
  $0 --lint [<repo-root>]            static check of every prune-allowlist.yaml
  $0 --selftest                      prove the mechanism can still fail
EOF
  exit 2
}

main() {
  case "${1:-}" in
    --selftest) selftest ;;
    --lint) lint "${2:-.}" ;;
    plan | audit)
      [ $# -eq 3 ] || usage
      local doc; doc="$(read_doc "$3")"
      "$1" "$2" "$doc"
      ;;
    *) usage ;;
  esac
}

main "$@"
