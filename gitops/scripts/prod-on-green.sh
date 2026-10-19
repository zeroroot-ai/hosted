#!/usr/bin/env bash
# prod-on-green.sh — prod follows a green staging smoke (ADR-0080
# § Prod promotion, gitops#550).
#
# Called by the promote-prod job of staging-smoke.yml, which `needs: smoke`,
# so a RED smoke never reaches this script (that is the fixture: the job is
# skipped, nothing is opened). Given a green smoke:
#
#   staging pins V, prod pins V   → nothing to do
#   staging pins V, prod pins W≠V → dispatch promote-bump (env=prod,
#                                   chart_version=V). The bump PR's own gates
#                                   (check-prod-promotion, the signature gate,
#                                   the "staging already on V" gate) stay the
#                                   guard on the way in, and the PR merges
#                                   only after an independent review names its
#                                   head (hosted#719). Nothing arms auto-merge:
#                                   with auto_merge=true the prod pin moved on
#                                   green checks alone, past the review gate.
#
# Env for --selftest only: STAGING_V and PROD_V. The selftest puts a stub
# `gh` on PATH that records its argv.
set -euo pipefail
source "$(dirname "$0")/lib/chart-version.sh"

# dispatch <v>: open the prod promotion PR for version <v>. No auto-merge.
dispatch() {
  gh workflow run promote-bump.yml -f env=prod -f chart_version="$1"
}

# merge_steps <workflow file>: the lines of a workflow that merge a PR or arm
# auto-merge. promote-bump must have none (hosted#719).
merge_steps() {
  grep -nE 'gh pr merge|--auto\b|auto_merge|enablePullRequestAutoMerge' "$1" | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

decide() { # decide <staging_v> <prod_v> -> prints "noop" or "bump <v>"
  local s="$1" p="$2"
  if [ -z "$s" ]; then echo "error: staging pins no version" >&2; return 2; fi
  if [ "$s" = "$p" ]; then echo "noop"; else echo "bump $s"; fi
}

if [ "${1:-}" = "--selftest" ]; then
  [ "$(decide 0.118.0 0.118.0)" = "noop" ] || { echo "GUARD BROKEN: equal versions should be a no-op" >&2; exit 2; }
  [ "$(decide 0.119.0 0.118.0)" = "bump 0.119.0" ] || { echo "GUARD BROKEN: newer staging should bump prod" >&2; exit 2; }
  decide "" 0.118.0 >/dev/null 2>&1 && { echo "GUARD BROKEN: an empty staging version was accepted" >&2; exit 2; }
  # The dispatch asks for no auto-merge.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/gh.argv"\n' "$tmp" > "$tmp/gh"; chmod +x "$tmp/gh"
  PATH="$tmp:$PATH" dispatch 0.119.0
  [ "$(cat "$tmp/gh.argv")" = "workflow run promote-bump.yml -f env=prod -f chart_version=0.119.0" ] \
    || { echo "GUARD BROKEN: the prod dispatch is not the plain promote-bump call: $(cat "$tmp/gh.argv")" >&2; exit 2; }
  # A workflow that merges or arms auto-merge is found; promote-bump has none.
  printf 'steps:\n  - run: gh pr merge "$PR_URL" --squash\n' > "$tmp/bad.yml"
  [ -n "$(merge_steps "$tmp/bad.yml")" ] || { echo "GUARD BROKEN: a merge step in a fixture passed" >&2; exit 2; }
  bump="$(dirname "$0")/../../.github/workflows/promote-bump.yml"
  [ -z "$(merge_steps "$bump")" ] \
    || { echo "promote-bump.yml merges or arms auto-merge (hosted#719):" >&2; merge_steps "$bump" >&2; exit 2; }
  echo "✅ self-test: equal → no-op, staging ahead → bump, unknown → refuse; the dispatch arms no auto-merge, and promote-bump has no merge step"
  exit 0
fi

staging_v="${STAGING_V:-$(env_chart_version staging)}"
prod_v="${PROD_V:-$(env_chart_version prod 2>/dev/null || true)}"
case "$(decide "$staging_v" "$prod_v")" in
  noop) echo "prod already pins ${staging_v}; nothing to promote" ;;
  bump*)
    echo "staging is green on ${staging_v}; prod pins '${prod_v:-<none>}' — dispatching promote-bump (env=prod). The PR merges after an independent review names its head (hosted#719)"
    dispatch "$staging_v" ;;
esac
