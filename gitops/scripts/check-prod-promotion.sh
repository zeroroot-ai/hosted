#!/usr/bin/env bash
# A pull request moves the prod chart pin only to the version staging pins
# (ADR-0080 § Prod on staging green, gitops#251, hosted#116).
#
# THE INVARIANT
#
# When a change set moves the OCI umbrella targetRevision in
# envs/prod/gibson.yaml, the new value must equal the staging pin in the same
# change set. Staging reaches a version only through a promotion that
# promote-staging proved, so "staging pins X" is the proof that X was tested.
# A prod pin that moves anywhere else is prod running a chart staging never
# ran, which is launch blocker 5 in one sentence.
#
# A change set that leaves the prod pin alone is not a promotion. It passes.
#
# WHY THIS EXISTS BESIDE check-promotion-order.py
#
# check-promotion-order.py reads the tree as it stands and refuses a prod pin
# AHEAD of staging. That is a floor, not the rule. Prod could move from 0.113.0
# to 0.125.0 while staging pins 0.128.0: not ahead, and still a version
# staging is not on. This guard reads the change set and holds the stricter
# rule at the moment a promotion is proposed. Both run in the merge gate.
#
# Usage:
#   scripts/check-prod-promotion.sh <base-ref>   # checks merge-base(base, HEAD)...HEAD
#   scripts/check-prod-promotion.sh --selftest
set -euo pipefail

# shellcheck source=scripts/lib/chart-version.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/chart-version.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'

# ---------------------------------------------------------------------------
# verdict <prod-base> <prod-head> <staging-head>
# Returns 1 when the prod pin moved to a version staging does not pin.
# Pure, so the selftest can drive every combination without git.
# ---------------------------------------------------------------------------
verdict() {
  local prod_base="$1" prod_head="$2" staging_head="$3"
  if [ "$prod_base" = "$prod_head" ]; then
    printf '  %s✓%s prod pin unchanged (%s): not a promotion, nothing to gate\n' "$GREEN" "$NC" "${prod_head:-<none>}"
    return 0
  fi
  if [ -z "$prod_head" ]; then
    printf '  %s✗%s the change set removes the prod pin (%s -> <none>)\n' "$RED" "$NC" "${prod_base:-<none>}" >&2
    return 1
  fi
  if [ "$prod_head" != "$staging_head" ]; then
    echo "::error::the change set moves the prod pin ${prod_base:-<none>} -> ${prod_head}, but staging pins ${staging_head:-<none>}. Prod may only move to the version staging pins (ADR-0080). Promote staging to ${prod_head} and prove it with promote-staging first." >&2
    return 1
  fi
  printf '  %s✓%s prod %s -> %s matches the staging pin\n' "$GREEN" "$NC" "${prod_base:-<none>}" "$prod_head"
  return 0
}

# ---------------------------------------------------------------------------
# rev_at <git-rev> <repo-relative-path> — the OCI umbrella pin at that rev, or
# empty when the file or the pin does not exist there.
# ---------------------------------------------------------------------------
rev_at() {
  git show "$1:$2" 2>/dev/null | oci_revision_walk read - 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# check <base-ref> — the real run. Exit 2 when the base cannot be resolved:
# a guard that exits 1 with no message on a shallow fetch reads as a refusal
# nobody can explain (gitops#561).
# ---------------------------------------------------------------------------
check() {
  local base="$1" merge_base app rel prod_base prod_head staging_head top
  if ! merge_base="$(git merge-base "$base" HEAD 2>/dev/null)" || [ -z "$merge_base" ]; then
    printf '%s✗ cannot compute merge-base(%s, HEAD): the base ref is missing or its history is shallow. Fetch the full base history and re-run.%s\n' "$RED" "$base" "$NC" >&2
    return 2
  fi
  app="$(resolve_app prod)" || {
    echo "::error::no prod platform Application found under envs/prod" >&2
    return 2
  }
  top="$(git rev-parse --show-toplevel)"
  rel="$(realpath --relative-to="$top" "$app")"
  prod_base="$(rev_at "$merge_base" "$rel")"
  prod_head="$(env_chart_version prod 2>/dev/null || true)"
  staging_head="$(env_chart_version staging 2>/dev/null || true)"
  printf 'prod: %s -> %s   staging: %s\n' "${prod_base:-<none>}" "${prod_head:-<none>}" "${staging_head:-<none>}"
  verdict "$prod_base" "$prod_head" "$staging_head"
}

# ---------------------------------------------------------------------------
# selftest — the verdict on every shape, then the git wiring on a scratch
# repository, so a change to how the pin is read cannot disarm the guard.
# ---------------------------------------------------------------------------
selftest() {
  local rc=0 pass=0
  ok()  { printf '  %s[PASS]%s %s\n' "$GREEN" "$NC" "$1"; pass=$((pass + 1)); }
  bad() { printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$1"; rc=1; }

  # THE POINT: prod moves to a version staging does not pin. Must refuse.
  if verdict 0.113.0 0.125.0 0.128.0 >/dev/null 2>&1; then
    bad 'guard PASSED a prod pin moving to a version staging does not pin'
  else
    ok 'guard refuses a prod pin moving to a version staging does not pin'
  fi
  # Ahead of staging is the same shape.
  if verdict 0.128.0 0.129.0 0.128.0 >/dev/null 2>&1; then
    bad 'guard PASSED a prod pin moving ahead of staging'
  else
    ok 'guard refuses a prod pin moving ahead of staging'
  fi
  # A pin that disappears is not a promotion either.
  if verdict 0.113.0 "" 0.128.0 >/dev/null 2>&1; then
    bad 'guard PASSED a change set that removes the prod pin'
  else
    ok 'guard refuses a change set that removes the prod pin'
  fi
  # The one shape a promotion is allowed to have.
  if verdict 0.113.0 0.128.0 0.128.0 >/dev/null 2>&1; then
    ok 'guard passes prod moving to the version staging pins'
  else
    bad 'guard refused a prod promotion to the staging version'
  fi
  # Not a promotion at all: pass, whatever staging pins.
  if verdict 0.113.0 0.113.0 0.128.0 >/dev/null 2>&1; then
    ok 'guard passes a change set that leaves the prod pin alone'
  else
    bad 'guard refused a change set that leaves the prod pin alone'
  fi

  # The git wiring, on a scratch repository shaped like gitops/.
  local dir
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" RETURN
  mkdir -p "$dir/envs/prod" "$dir/envs/staging"
  write_pin() { # env version
    cat >"$dir/envs/$1/gibson.yaml" <<YAML
spec:
  sources:
    - repoURL: ${OCI_REPO}
      chart: gibson
      targetRevision: "$2"
    - repoURL: https://github.com/zeroroot-ai/hosted
      targetRevision: main
      ref: values
YAML
  }
  write_pin prod 0.113.0
  write_pin staging 0.128.0
  git -C "$dir" init -q -b main .
  git -C "$dir" -c user.name=selftest -c user.email=selftest@example.com add -A
  git -C "$dir" -c user.name=selftest -c user.email=selftest@example.com commit -q -m base
  git -C "$dir" branch -q base

  # Head moves prod to a version staging does not pin. Must refuse.
  write_pin prod 0.125.0
  git -C "$dir" -c user.name=selftest -c user.email=selftest@example.com commit -q -am "bad promotion"
  if (cd "$dir" && REPO_ROOT="$dir" check base >/dev/null 2>&1); then
    bad 'git wiring: a bad prod promotion in a change set was accepted'
  else
    ok 'git wiring: a bad prod promotion in a change set is refused'
  fi

  # Head moves prod to the staging version. Must pass.
  write_pin prod 0.128.0
  git -C "$dir" -c user.name=selftest -c user.email=selftest@example.com commit -q -am "good promotion"
  if (cd "$dir" && REPO_ROOT="$dir" check base >/dev/null 2>&1); then
    ok 'git wiring: a prod promotion to the staging version passes'
  else
    bad 'git wiring: a good prod promotion was refused'
  fi

  # An unresolvable base must exit 2 with a message, never a silent 1.
  local code
  code="$(cd "$dir" && REPO_ROOT="$dir" check "refs/no-such-base-$$" >/dev/null 2>&1; echo $?)"
  if [ "$code" = "2" ]; then
    ok 'git wiring: an unresolvable base ref exits 2'
  else
    bad "git wiring: an unresolvable base ref exited ${code}, want 2"
  fi

  # The live tree: both pins the guard compares must be readable.
  local env v
  for env in staging prod; do
    if v="$(env_chart_version "$env" 2>/dev/null)" && [ -n "$v" ]; then
      ok "${env}: pin readable at ${v}"
    else
      bad "${env}: cannot read the OCI umbrella pin the guard compares"
    fi
  done

  printf '\n%s checks passed\n' "$pass"
  return $rc
}

main() {
  if [ "${1:-}" = "--selftest" ]; then
    printf '%s=== check-prod-promotion selftest ===%s\n' "$GREEN" "$NC"
    selftest
    exit $?
  fi
  local base="${1:?usage: check-prod-promotion.sh <base-ref> | --selftest}"
  check "$base"
}

main "$@"
