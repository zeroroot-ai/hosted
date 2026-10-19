#!/usr/bin/env bash
# Bump the chart version for one env overlay (ADR-0072 / gitops#251).
#
# Promotion is a single-number bump of the OCI source `targetRevision` in the
# env's platform Application — and ONLY that. The Application pin is the one
# canonical promotion marker. Rollback = run this again with the previous
# version.
#
# WHY THIS MUST NEVER TOUCH envs/<env>/values.yaml (gitops#448)
#
# The gibson Application and the app-of-apps that applies its spec both watch
# this repo's main branch, with no ordering between them. This script used to
# also write a `chartVersion:` marker into envs/<env>/values.yaml — the $values
# file the gibson app renders — so one promotion commit made both apps stale at
# once. Whenever the gibson app reconciled first it rendered the OLD chart
# against the NEW $values revision, and a failed sync pinned to the stale
# revision retried itself to exhaustion (selfHeal cannot re-target an in-flight
# operation). Three promotions stalled that way (#449, #453, #458) before the
# marker was removed. A promotion now touches no $values file, so the stale
# render is unreachable. check-promotion-isolation.sh enforces the invariant
# on every pull request (make check-promotion-pr).
#
# WHY THE APPLICATION EDIT IS A SCOPED WALK AND NOT A FILE-WIDE sed
#
# This used to be `sed -i -E 's|^([[:space:]]*targetRevision:[[:space:]]*)"[0-9].*"|…|'`
# over the whole file: it rewrites EVERY quoted numeric targetRevision, not just
# the umbrella chart's, and the verification only ever read the first match, so a
# corrupted second pin passed silently. Today's envs/<env>/gibson.yaml happens to
# carry exactly one numeric pin (the other source is `targetRevision: main`), so
# nothing is broken right now — but Applications with two numeric pins already
# exist in this tree (envs/staging/arc-runners.yaml pins a chart to "0.14.2"),
# and the next source added to a platform Application would be silently
# overwritten by a routine promotion. Scope the edit to the OCI umbrella source
# instead, and fail loudly on anything other than exactly one match (gitops#380).
#
# Usage:
#   scripts/bump-chart-version.sh <env> <new-version>
#   scripts/bump-chart-version.sh --selftest   # prove the scoped edit still
#                                              # rewrites the right line and
#                                              # only that line
set -euo pipefail

# shellcheck source=scripts/lib/chart-version.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/chart-version.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'

# ---------------------------------------------------------------------------
# rewrite_app <file> <version> — in-place, scoped to the OCI umbrella source.
# ---------------------------------------------------------------------------
rewrite_app() {
  local file="$1" version="$2" tmp
  tmp="$(mktemp)"
  if ! oci_revision_walk write "$file" "$version" >"$tmp"; then
    rm -f "$tmp"
    echo "::error::${file} does not contain exactly one source with repoURL ${OCI_REPO} and a targetRevision — refusing to guess which line to bump" >&2
    return 1
  fi
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# bump_env <env> <version> — the platform pin and each sibling pin of one env.
# ---------------------------------------------------------------------------
bump_env() {
  local env="$1" version="$2" app sib got
  app="$(resolve_app "$env")" || {
    echo "::error::no platform Application found at envs/${env}/gibson.yaml or envs/${env}/apps/gibson.yaml" >&2
    return 1
  }
  rewrite_app "$app" "$version" || return 1
  while IFS= read -r sib; do
    [ -n "$sib" ] || continue
    rewrite_app "$sib" "$version" || return 1
    echo "bumped sibling $(basename "$sib" .yaml) -> ${version} (${sib})"
  done < <(sibling_apps "$env")
  got="$(oci_revision_walk read "$app")"
  [ "$got" = "$version" ] || { echo "::error::${app} OCI targetRevision=$got != $version" >&2; return 1; }
  echo "bumped ${env} -> ${version} (${app})"
}

# ---------------------------------------------------------------------------
# selftest — the edit must change the umbrella pin and NOTHING else, and must
# refuse rather than guess when the file shape is not what it expects.
# ---------------------------------------------------------------------------
selftest() {
  local dir rc=0 pass=0
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  ok()  { printf '  %s[PASS]%s %s\n' "$GREEN" "$NC" "$1"; pass=$((pass + 1)); }
  bad() { printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$1"; rc=1; }

  # -- fixture A: two numeric pins in one Application ------------------------
  # Modelled on envs/staging/arc-runners.yaml, which pins an unrelated chart to
  # "0.14.2". This is the case the old file-wide sed corrupts.
  cat >"${dir}/two-pins.yaml" <<YAML
spec:
  sources:
    - repoURL: ${OCI_REPO}
      chart: gibson
      # a comment between repoURL and targetRevision must not break the walk
      targetRevision: "0.100.0"
    - repoURL: ghcr.io/actions/actions-runner-controller-charts
      chart: gha-runner-scale-set
      targetRevision: "0.14.2"
    - repoURL: https://github.com/zeroroot-ai/hosted
      targetRevision: main
      ref: values
YAML

  # First: prove the fixture is a real regression case — the OLD expression
  # clobbers the unrelated pin. If this ever stops being true the fixture has
  # drifted and the rest of this test proves nothing.
  local old="${dir}/old-sed.yaml"
  cp "${dir}/two-pins.yaml" "$old"
  sed -i -E 's|^([[:space:]]*targetRevision:[[:space:]]*)"[0-9].*"|\1"9.9.9"|' "$old"
  if grep -q 'targetRevision: "9.9.9"' "$old" && ! grep -q '"0.14.2"' "$old"; then
    ok 'fixture is a genuine regression case: the old file-wide sed rewrites the unrelated "0.14.2" pin'
  else
    bad 'fixture no longer reproduces the old sed corruption — the test proves nothing'
  fi

  # Now the scoped rewrite: umbrella moves, everything else is byte-identical.
  cp "${dir}/two-pins.yaml" "${dir}/new.yaml"
  if rewrite_app "${dir}/new.yaml" 0.200.0; then
    if grep -q 'targetRevision: "0.200.0"' "${dir}/new.yaml"; then
      ok 'scoped rewrite bumps the OCI umbrella pin'
    else
      bad 'scoped rewrite did NOT bump the OCI umbrella pin'
    fi
    if grep -q 'targetRevision: "0.14.2"' "${dir}/new.yaml"; then
      ok 'scoped rewrite leaves the unrelated "0.14.2" chart pin alone'
    else
      bad 'scoped rewrite clobbered the unrelated "0.14.2" chart pin'
    fi
    # shellcheck disable=SC2016  # $values is Argo's ref name, not a variable
    if grep -q 'targetRevision: main' "${dir}/new.yaml"; then
      ok 'scoped rewrite leaves the gitops $values ref on main'
    else
      bad 'scoped rewrite touched the gitops $values ref'
    fi
    # Exactly one line differs from the fixture.
    local changed
    changed="$(diff "${dir}/two-pins.yaml" "${dir}/new.yaml" | grep -c '^[<>]' || true)"
    if [ "$changed" -eq 2 ]; then
      ok 'exactly one line changed'
    else
      bad "expected exactly one changed line, got $((changed / 2))"
    fi
  else
    bad 'scoped rewrite refused a well-formed two-pin Application'
  fi

  # -- fixture B: no OCI source — must refuse, not silently no-op ------------
  cat >"${dir}/none.yaml" <<'YAML'
spec:
  sources:
    - repoURL: https://github.com/zeroroot-ai/hosted
      targetRevision: main
YAML
  if rewrite_app "${dir}/none.yaml" 0.200.0 2>/dev/null; then
    bad 'rewrite accepted an Application with no OCI umbrella source'
  else
    ok 'rewrite refuses an Application with no OCI umbrella source'
  fi

  # -- fixture C: two OCI sources — ambiguous, must refuse -------------------
  cat >"${dir}/dupe.yaml" <<YAML
spec:
  sources:
    - repoURL: ${OCI_REPO}
      chart: gibson
      targetRevision: "0.100.0"
    - repoURL: ${OCI_REPO}
      chart: gibson-crds
      targetRevision: "0.100.0"
YAML
  if rewrite_app "${dir}/dupe.yaml" 0.200.0 2>/dev/null; then
    bad 'rewrite guessed between two OCI umbrella sources instead of refusing'
  else
    ok 'rewrite refuses when two sources could match'
  fi

  # -- the live tree: every env's Application must be readable ---------------
  # (The old lockstep check against the values.yaml chartVersion marker is gone
  # with the marker itself — gitops#448. What remains worth pinning: every env
  # resolves to exactly one OCI umbrella pin the bump can address.)
  local env app got_a
  for env in staging drill prod; do
    app="$(resolve_app "$env")" || { bad "${env}: no platform Application found"; continue; }
    if got_a="$(oci_revision_walk read "$app" 2>/dev/null)"; then
      ok "${env}: ${app} pins the OCI umbrella at ${got_a}"
    else
      bad "${env}: ${app} has no single OCI umbrella source the bump can address"
    fi
  done

  # -- fixture D: a sibling left behind must be caught ----------------------
  # This is gitops#564 in miniature: the platform pin moves and a sibling does
  # not, so the sibling addresses a chart tag nobody published.
  mkdir -p "${dir}/envs/fx"
  for n in gibson gibson-crds gibson-velero; do
    cat >"${dir}/envs/fx/${n}.yaml" <<YAML
spec:
  sources:
    - repoURL: ${OCI_REPO}
      chart: ${n}
      targetRevision: "0.100.0"
YAML
  done
  if REPO_ROOT="$dir" sibling_apps fx | grep -q gibson-velero; then
    ok 'sibling_apps finds the two sibling Applications beside the platform one'
  else
    bad 'sibling_apps did not find the sibling Applications'
  fi
  rewrite_app "${dir}/envs/fx/gibson.yaml" 0.200.0
  if grep -q '"0.100.0"' "${dir}/envs/fx/gibson-crds.yaml"; then
    ok 'fixture is a genuine regression case: bumping the platform alone leaves the sibling behind'
  else
    bad 'fixture drifted: the sibling moved without being asked to'
  fi
  local s2
  while IFS= read -r s2; do rewrite_app "$s2" 0.200.0; done < <(REPO_ROOT="$dir" sibling_apps fx)
  if grep -q '"0.200.0"' "${dir}/envs/fx/gibson-crds.yaml" \
     && grep -q '"0.200.0"' "${dir}/envs/fx/gibson-velero.yaml"; then
    ok 'the sibling pins move with the platform pin'
  else
    bad 'a sibling pin did not move with the platform pin'
  fi

  # -- fixture E: a staging promotion moves drill too -----------------------
  # Drill run 37460863468: promotions moved only staging, so drill stayed on
  # 0.135.0 while its values followed staging to 0.136.8, and the drill
  # platform Application could not render. bump_env on staging alone leaves
  # drill behind. The follower loop of main must move it.
  mkdir -p "${dir}/envs/staging" "${dir}/envs/drill"
  for e in staging drill; do
    for n in gibson gibson-crds; do
      cat >"${dir}/envs/${e}/${n}.yaml" <<YAML
spec:
  sources:
    - repoURL: ${OCI_REPO}
      chart: ${n}
      targetRevision: "0.100.0"
YAML
    done
  done
  REPO_ROOT="$dir" bump_env staging 0.200.0 >/dev/null
  if grep -q '"0.100.0"' "${dir}/envs/drill/gibson.yaml"; then
    ok 'fixture is a genuine regression case: a staging bump alone leaves drill behind'
  else
    bad 'fixture drifted: drill moved without its follower loop'
  fi
  if REPO_ROOT="$dir" bash "${BASH_SOURCE[0]}" staging 0.300.0 >/dev/null 2>&1 \
     && grep -q '"0.300.0"' "${dir}/envs/drill/gibson.yaml" \
     && grep -q '"0.300.0"' "${dir}/envs/drill/gibson-crds.yaml"; then
    ok 'a staging promotion moves the drill platform pin and its sibling pins'
  else
    bad 'a staging promotion left a drill pin behind'
  fi
  if [ "$(follower_envs prod)" = "" ]; then
    ok 'a prod promotion moves no other env'
  else
    bad "a prod promotion moves $(follower_envs prod)"
  fi

  # -- the live tree: every env's three pins must already agree --------------
  for env in staging drill prod; do
    local plat sv sib_bad=0
    plat="$(env_chart_version "$env" 2>/dev/null)" || continue
    while IFS= read -r s2; do
      [ -n "$s2" ] || continue
      sv="$(oci_revision_walk read "$s2" 2>/dev/null || echo '<unreadable>')"
      [ "$sv" = "$plat" ] || { bad "${env}: $(basename "$s2" .yaml) pins ${sv}, the platform pins ${plat}"; sib_bad=1; }
    done < <(sibling_apps "$env")
    [ "$sib_bad" = 0 ] && ok "${env}: the platform and its sibling releases all pin ${plat}"
  done

  # -- the live tree: the deleted marker must STAY deleted -------------------
  # A resurrected `chartVersion:` marker in an env values.yaml silently
  # reintroduces the gitops#448 race the moment something writes it again.
  local tree="${REPO_ROOT:-$CHART_VERSION_TREE_ROOT}"
  for env in staging drill prod; do
    [ -f "${tree}/envs/${env}/values.yaml" ] || continue
    if grep -qE '^chartVersion:' "${tree}/envs/${env}/values.yaml"; then
      bad "envs/${env}/values.yaml carries a chartVersion marker — deleted in gitops#448, must not come back"
    else
      ok "envs/${env}/values.yaml carries no chartVersion marker"
    fi
  done

  printf '\n%s checks passed\n' "$pass"
  return $rc
}

main() {
  if [ "${1:-}" = "--selftest" ]; then
    printf '%s=== bump-chart-version selftest ===%s\n' "$GREEN" "$NC"
    selftest
    exit $?
  fi

  local env version
  env="${1:?usage: bump-chart-version.sh <env> <new-version>}"
  version="${2:?usage: bump-chart-version.sh <env> <new-version>}"

  case "$env" in
    staging|prod) ;;
    *) echo "::error::unknown env '$env' (want staging|prod)"; exit 1 ;;
  esac
  # Reject a 'v' prefix / arbitrary junk — chart versions are bare semver.
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+].+)?$ ]]; then
    echo "::error::'$version' is not a bare semver chart version (e.g. 0.105.0)"; exit 1
  fi

  # The OCI umbrella source's targetRevision, and only that line. The sibling
  # releases move WITH it, to the same version. gibson-crds and gibson-velero
  # are published beside the umbrella at one version (deploy#1785), so three
  # pins that are allowed to drift are three chances to address a tag that
  # does not exist. Each is rewritten through the same scoped walk, so a
  # sibling whose shape is not what we expect fails loudly rather than being
  # skipped. bump_env re-reads the pin through the same walk to verify it.
  bump_env "$env" "$version" || exit 1

  # Drill follows staging in the same commit (ADR-0095, follower_envs). The
  # env must exist: a follower that follower_envs names and the tree lacks
  # is a defect in one of the two, so it fails loudly.
  local fol
  while IFS= read -r fol; do
    [ -n "$fol" ] || continue
    bump_env "$fol" "$version" || exit 1
  done < <(follower_envs "$env")
}

main "$@"
