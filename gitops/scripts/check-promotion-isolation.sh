#!/usr/bin/env bash
# gitops#448: a promotion must never touch an env's $values file.
#
# THE INVARIANT: no single change set may move an env's OCI umbrella
# targetRevision (in envs/<env>/gibson.yaml or envs/<env>/apps/gibson.yaml)
# AND touch that env's $values overlay (envs/<env>/values.yaml).
#
# WHY: the gibson Application and the app-of-apps that applies its spec both
# watch this repo's main branch with no ordering between them. A commit that
# changes both makes both apps stale at once; when the gibson app reconciles
# first it renders the OLD chart against the NEW $values revision, and a failed
# sync pinned to that stale revision retries to exhaustion (selfHeal cannot
# re-target an in-flight operation). Three promotions stalled exactly this way
# (#449, #453, #458) before the chartVersion marker was removed from
# values.yaml. This guard keeps a future hand-edit from reintroducing the
# race: split such a change into two PRs.
#
# The guard is scoped to targetRevision moves, not any touch of the
# Application file — a comment edit beside an untouched pin renders
# identically in the stale window and cannot race.
#
# Usage:
#   scripts/check-promotion-isolation.sh <base-ref>   # checks base...HEAD
#   scripts/check-promotion-isolation.sh --selftest
set -euo pipefail

# shellcheck source=scripts/lib/chart-version.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/chart-version.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'

# ---------------------------------------------------------------------------
# env_verdict <env> <values-changed:0|1> <base-rev> <head-rev>
# Returns 1 (race) iff the env's values.yaml changed AND the pin moved.
# Factored pure so the selftest can exercise every combination.
# ---------------------------------------------------------------------------
env_verdict() {
  local env="$1" values_changed="$2" base_rev="$3" head_rev="$4"
  if [ "$values_changed" = "1" ] && [ "$base_rev" != "$head_rev" ]; then
    echo "::error::change set moves the ${env} OCI umbrella pin (${base_rev:-<absent>} -> ${head_rev:-<absent>}) AND touches envs/${env}/values.yaml — that is the gitops#448 promotion race. A promotion and a \$values change must land as separate main revisions; split this into two PRs."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# selftest — the guard must FAIL on the race shape and PASS on the safe ones.
# A guard that has never been observed failing is not a guard.
# ---------------------------------------------------------------------------
selftest() {
  local rc=0 pass=0
  ok()  { printf '  %s[PASS]%s %s\n' "$GREEN" "$NC" "$1"; pass=$((pass + 1)); }
  bad() { printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$1"; rc=1; }

  # Mutation case: pin moves + values change — MUST refuse.
  if env_verdict staging 1 "0.112.3" "0.112.4" >/dev/null 2>&1; then
    bad 'guard PASSED a pin move riding with a values.yaml change — the guard cannot fail'
  else
    ok 'guard refuses a pin move + values.yaml change in one diff'
  fi

  # Pin appearing from nothing (new Application) + values change is still the
  # race shape — MUST refuse.
  if env_verdict dev 1 "" "0.112.4" >/dev/null 2>&1; then
    bad 'guard PASSED a newly-added pin riding with a values.yaml change'
  else
    ok 'guard refuses a newly-added pin + values.yaml change'
  fi

  # A base ref that cannot be resolved MUST fail loudly with exit 2, never
  # exit 1 with no message (gitops#561, shallow-fetch race).
  if main "refs/no-such-base-$$" >/dev/null 2>&1; then
    bad 'guard PASSED with an unresolvable base ref'
  elif [ "$(main "refs/no-such-base-$$" >/dev/null 2>&1; echo $?)" = "2" ]; then
    ok 'guard fails loudly (exit 2) when the merge-base cannot be computed'
  else
    bad 'guard failed on an unresolvable base ref with the wrong exit code'
  fi

  # Pin move alone — a normal promotion — MUST pass.
  if env_verdict prod 0 "0.112.3" "0.112.4" >/dev/null 2>&1; then
    ok 'guard passes a promotion (pin move, values.yaml untouched)'
  else
    bad 'guard refused a clean promotion'
  fi

  # values.yaml change alone — a normal overlay change — MUST pass.
  if env_verdict staging 1 "0.112.4" "0.112.4" >/dev/null 2>&1; then
    ok 'guard passes a values-only change (pin unmoved)'
  else
    bad 'guard refused a values-only change'
  fi

  # Comment-only Application edit + values change: pin unmoved — MUST pass
  # (renders identically in the stale window; cannot race).
  if env_verdict staging 1 "0.112.4" "0.112.4" >/dev/null 2>&1 && \
     env_verdict prod 0 "" "" >/dev/null 2>&1; then
    ok 'guard passes comment-only Application edits beside values changes'
  else
    bad 'guard refused a non-promotion Application edit'
  fi

  # The live-tree wiring: every env must resolve through the same reader the
  # real run uses, so a file-shape change cannot silently disarm the guard.
  local env v
  for env in staging drill prod; do
    if v="$(env_chart_version "$env" 2>/dev/null)" && [ -n "$v" ]; then
      ok "${env}: pin readable at ${v}"
    else
      bad "${env}: cannot read the OCI umbrella pin the guard compares"
    fi
  done

  # -- change-set fixtures: a real git history under gitops/envs ------------
  # The env_verdict cases above never read a path. These run main against a
  # scratch repo with the tree under gitops/, the layout of this repo.
  local repo
  repo="$(mktemp -d)"
  fx_app() { mkdir -p "${repo}/gitops/envs/$1"; printf 'spec:\n  sources:\n    - repoURL: %s\n      chart: gibson\n      targetRevision: "%s"\n' "$OCI_REPO" "$2" >"${repo}/gitops/envs/$1/gibson.yaml"; }
  fx_values() { printf 'note: %s\n' "$2" >"${repo}/gitops/envs/$1/values.yaml"; }
  fx_git() { git -C "$repo" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
  fx_run() { (cd "$repo" && REPO_ROOT="${repo}/gitops" main base >/dev/null 2>&1); }
  fx_git init -q -b main
  for env in staging drill prod; do fx_app "$env" 0.100.0; fx_values "$env" a; done
  fx_git add -A; fx_git commit -qm base; fx_git branch base

  fx_app drill 0.200.0; fx_values drill b; fx_git commit -qam race
  if fx_run; then
    bad 'guard PASSED a drill pin move + a drill values.yaml edit in one change set'
  else
    ok 'guard refuses a drill pin move + a drill values.yaml edit in one change set'
  fi
  fx_git reset -q --hard base

  fx_app staging 0.200.0; fx_values staging b; fx_git commit -qam race
  if fx_run; then
    bad 'guard PASSED a staging pin move + values.yaml edit under gitops/envs'
  else
    ok 'guard refuses a staging pin move + values.yaml edit under gitops/envs'
  fi
  fx_git reset -q --hard base

  fx_app drill 0.200.0; fx_app staging 0.200.0; fx_git commit -qam promote
  if fx_run; then
    ok 'guard passes a staging + drill promotion with no values.yaml edit'
  else
    bad 'guard refused a clean staging + drill promotion'
  fi
  fx_git reset -q --hard base

  fx_values drill b; fx_git commit -qam values
  if fx_run; then
    ok 'guard passes a drill values.yaml edit with no pin move'
  else
    bad 'guard refused a drill values-only change'
  fi
  rm -rf "$repo"

  printf '\n%s checks passed\n' "$pass"
  return $rc
}

# ---------------------------------------------------------------------------
# rev_at <git-rev> <path> — the OCI umbrella pin in <path> as of <git-rev>;
# empty if the file or pin does not exist there.
# ---------------------------------------------------------------------------
rev_at() {
  git show "$1:$2" 2>/dev/null | oci_revision_walk read - 2>/dev/null || true
}

main() {
  if [ "${1:-}" = "--selftest" ]; then
    printf '%s=== check-promotion-isolation selftest ===%s\n' "$GREEN" "$NC"
    selftest
    exit $?
  fi

  local base="${1:?usage: check-promotion-isolation.sh <base-ref> | --selftest}"
  local merge_base changed rc=0 env app values_changed base_rev head_rev
  if ! merge_base="$(git merge-base "$base" HEAD 2>/dev/null)" || [ -z "$merge_base" ]; then
    printf '%s✗ cannot compute merge-base(%s, HEAD): the base ref is missing or its history is shallow. Fetch the full base history and re-run.%s\n' "$RED" "$base" "$NC" >&2
    return 2
  fi
  changed="$(git diff --name-only "${merge_base}" HEAD)"

  # git prints paths from the repo root, and the Argo tree sits under
  # gitops/ since ADR-0086. The old loop compared "envs/<env>/..." with
  # "gitops/envs/<env>/...", matched nothing, and passed every change set.
  # It also named only staging and prod, so a drill pin move and a drill
  # values edit in one change set passed too (hosted#470).
  local tree_abs top prefix
  tree_abs="$(cd "${REPO_ROOT:-$CHART_VERSION_TREE_ROOT}" && pwd -P)"
  top="$(git rev-parse --show-toplevel)"
  top="$(cd "$top" && pwd -P)"
  prefix="${tree_abs#"$top"}"
  prefix="${prefix#/}"
  [ -n "$prefix" ] && prefix="${prefix}/"

  local envs=() d
  for d in "${tree_abs}"/envs/*/; do
    [ -d "$d" ] && envs+=("$(basename "$d")")
  done
  if [ "${#envs[@]}" -eq 0 ]; then
    printf '%s✗ no env directory under %s/envs: the guard would pass vacuously%s\n' "$RED" "$tree_abs" "$NC" >&2
    return 2
  fi

  for env in "${envs[@]}"; do
    values_changed=0
    grep -qx "${prefix}envs/${env}/values.yaml" <<<"$changed" && values_changed=1
    # Check both candidate Application paths; resolve_app only sees HEAD's
    # working tree, but the base may have had the file at the other path.
    for app in "${prefix}envs/${env}/gibson.yaml" "${prefix}envs/${env}/apps/gibson.yaml"; do
      grep -qx "$app" <<<"$changed" || continue
      base_rev="$(rev_at "$merge_base" "$app")"
      head_rev="$(rev_at HEAD "$app")"
      env_verdict "$env" "$values_changed" "$base_rev" "$head_rev" || rc=1
    done
  done

  [ "$rc" -eq 0 ] && echo "✓ no env moves its OCI umbrella pin and touches its values.yaml in the same change set"
  return $rc
}

main "$@"
