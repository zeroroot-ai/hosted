#!/usr/bin/env bash
# check-values-files-are-named.sh — no values file renders nowhere (hosted#362).
#
# THE FAILURE MODE IS SILENCE
#
# `gitops/values/` held five files that looked exactly like live environment
# overlays: values-staging.yaml, values-aws-prod.yaml, values-kind.yaml,
# values-kind-saas-dev.yaml, values-saas.yaml, each carrying plausible keys.
# Every Argo Application names its value files explicitly, and all fifteen of
# those paths are under `gitops/envs/`. Nothing read the directory.
#
# It was found by editing one. A dashboard memory limit was raised in
# `gitops/values/values-staging.yaml`; the staging Application reads
# `$values/gitops/envs/staging/values.yaml`, where the real value lived at a
# different number. Nothing failed. The change simply did not happen.
#
# A deleted file fails loudly the next time something reads it. A file that is
# read by nothing, holds the right keys, and sits at a path that reads like an
# environment overlay absorbs edits forever. One guard even scanned them —
# check-marketing-host.py walks `gitops/**` at any depth — so they looked
# maintained while reaching no cluster.
#
# THE RULE
#
# Every values file under `gitops/envs/` must be named by some Application's
# `helm.valueFiles`. A values file anywhere else under `gitops/` must be a
# chart's own `values.yaml`, beside a Chart.yaml, or live under that chart's
# `ci/` directory — those are Helm's own conventions and are not overlays.
#
#   check-values-files-are-named.sh             exit 1 on a values file nothing names
#   check-values-files-are-named.sh --selftest  prove each half fails on a fixture
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'

# judge <gitops dir> — the failures, as lines.
judge() {
  local g="$1" named f rel out=()
  [ -d "$g" ] || { echo "no gitops directory at ${g}"; return 0; }

  # Every path any Application names, in the one form Argo uses here.
  named="$(grep -rhoE '\$values/[A-Za-z0-9_./-]+' "$g" 2>/dev/null | sed 's|^\$values/||' | sort -u)"

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$ROOT"/}"
    case "$rel" in
      */envs/*)
        printf '%s\n' "$named" | grep -qxF "$rel" || out+=("${rel} is a values file no Application names in helm.valueFiles, so nothing renders it. Name it, or delete it — a file that reads like an overlay and reaches no cluster absorbs edits silently")
        ;;
      *)
        # Outside envs/: legal only as a chart's own values.yaml or under its ci/.
        if [ "$(basename "$f")" = "values.yaml" ] && [ -f "$(dirname "$f")/Chart.yaml" ]; then
          continue
        fi
        case "$rel" in */ci/*) [ -f "$(dirname "$(dirname "$f")")/Chart.yaml" ] && continue ;; esac
        out+=("${rel} is a values file outside gitops/envs/ that is neither a chart's own values.yaml nor one of its ci/ inputs. gitops/values/ was exactly this and held five overlays nothing rendered")
        ;;
    esac
  done < <(find "$g" -name "*values*.yaml" -o -name "values.yaml" | sort -u)

  printf '%s\n' "${out[@]+"${out[@]}"}"
}

selftest() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/g/envs/staging" "$tmp/g/chart/ci"

  # a named overlay, a chart's own values.yaml, and a chart ci/ input
  printf 'spec:\n  sources:\n    - helm:\n        valueFiles:\n          - $values/g/envs/staging/values.yaml\n' > "$tmp/g/envs/staging/gibson.yaml"
  : > "$tmp/g/envs/staging/values.yaml"
  : > "$tmp/g/chart/Chart.yaml"
  : > "$tmp/g/chart/values.yaml"
  : > "$tmp/g/chart/ci/render-test-values.yaml"
  ROOT="$tmp" judge "$tmp/g" | grep -q . \
    && { echo "SELFTEST FAIL: a named overlay, a chart values.yaml and a ci/ input must all pass"; return 1; }

  # 1. an overlay under envs/ that no Application names
  : > "$tmp/g/envs/staging/values-forgotten.yaml"
  ROOT="$tmp" judge "$tmp/g" | grep -q "values-forgotten.yaml is a values file no Application names" \
    || { echo "SELFTEST FAIL: an unnamed overlay under envs/ must fail"; return 1; }
  rm "$tmp/g/envs/staging/values-forgotten.yaml"

  # 2. the hosted#362 shape itself: a values dir outside envs/, no chart beside it
  mkdir -p "$tmp/g/values"
  : > "$tmp/g/values/values-staging.yaml"
  ROOT="$tmp" judge "$tmp/g" | grep -q "values/values-staging.yaml is a values file outside" \
    || { echo "SELFTEST FAIL: a values file outside envs/ with no chart must fail"; return 1; }
  rm -r "$tmp/g/values"

  # 3. a ci/ input with no chart above it is not a chart input
  mkdir -p "$tmp/g/stray/ci"
  : > "$tmp/g/stray/ci/values-x.yaml"
  ROOT="$tmp" judge "$tmp/g" | grep -q "stray/ci/values-x.yaml is a values file outside" \
    || { echo "SELFTEST FAIL: a ci/ values file with no Chart.yaml above it must fail"; return 1; }
  rm -r "$tmp/g/stray"

  local live; live="$(judge "$ROOT/gitops")"
  [ -z "$live" ] || { printf "SELFTEST FAIL: the tree is not clean:\n  %s\n" "$live"; return 1; }
  echo "OK: an unnamed overlay, a values file outside envs/ and a ci/ input with no chart all fail; a named overlay, a chart's own values.yaml and a real ci/ input pass"
}

case "${1:-}" in
  --selftest) selftest ;;
  *)
    bad="$(judge "$ROOT/gitops")"
    if [ -n "$bad" ]; then
      printf "${RED}✗${NC} values files that render nowhere:\n" >&2
      printf '  %s\n' "$bad" >&2
      exit 1
    fi
    n=$(find "$ROOT/gitops" -name "*values*.yaml" -o -name "values.yaml" | sort -u | wc -l)
    printf "${GREEN}✓${NC} check-values-files-are-named: all %s values file(s) under gitops/ are rendered by something\n" "$n"
    ;;
esac
