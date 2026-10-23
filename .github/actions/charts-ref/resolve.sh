#!/usr/bin/env bash
# resolve.sh <ref>: print the commit of zeroroot-ai/charts that <ref> names,
# or fail. An exit test installs the chart source of this commit.
#
# A ref is accepted when it is:
#   - a branch or a tag of the repository (refs/heads/<ref>, refs/tags/<ref>,
#     or the same with the refs/ prefix written out), or
#   - a 40-character commit that the main branch holds.
# Anything else is refused: refs/pull/<n>/head and refs/pull/<n>/merge, and a
# commit that only a fork holds. GitHub serves a fork commit through the
# parent repository, so a bare commit off main is refused too. Dispatch a
# branch name for a commit that is not on main.
#
# Env: CHARTS_REMOTE  the repository (default
#                     https://github.com/zeroroot-ai/charts.git). The suite
#                     points it at a local repository.
set -euo pipefail

REMOTE="${CHARTS_REMOTE:-https://github.com/zeroroot-ai/charts.git}"
ref="${1:-}"
die() { echo "::error title=charts ref refused::$*" >&2; exit 1; }

[ -n "$ref" ] || die "the charts ref is empty"
[[ "$ref" =~ ^[A-Za-z0-9._/-]{1,200}$ ]] || die "the charts ref '${ref}' holds a character that no branch, tag or commit name of zeroroot-ai/charts uses"
case "$ref" in
  refs/pull/*|pull/*) die "the charts ref '${ref}' is a pull request ref. Dispatch a branch, a tag or a commit on main" ;;
esac

if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  git -C "$work" init -q
  git -C "$work" remote add origin "$REMOTE"
  # Commits and trees only. The fetch output is shown only when it fails.
  if ! git -C "$work" fetch -q --filter=blob:none --no-tags origin "+refs/heads/main:refs/remotes/origin/main" 2>"$work/fetch.err"; then
    cat "$work/fetch.err" >&2
    die "cannot fetch the main branch of ${REMOTE}"
  fi
  if ! git -C "$work" cat-file -e "${ref}^{commit}" 2>/dev/null \
    || ! git -C "$work" merge-base --is-ancestor "$ref" refs/remotes/origin/main; then
    die "the commit ${ref} is not on the main branch of zeroroot-ai/charts. Dispatch the branch that holds it"
  fi
  echo "$ref"
  exit 0
fi

name="${ref#refs/heads/}"
name="${name#refs/tags/}"
refs="$(git ls-remote "$REMOTE" "refs/heads/${name}" "refs/tags/${name}" "refs/tags/${name}^{}")" \
  || die "cannot list the refs of ${REMOTE}"
# An annotated tag lists the tag object and, with ^{}, the commit it names.
sha="$(awk -v h="refs/heads/${name}" -v t="refs/tags/${name}" -v p="refs/tags/${name}^{}" '
  $2 == p { peeled = $1 } $2 == t { tag = $1 } $2 == h { head = $1 }
  END { if (head != "") print head; else if (peeled != "") print peeled; else print tag }' <<<"$refs")"
[ -n "$sha" ] || die "the charts ref '${ref}' is not a branch, a tag or a commit on main of zeroroot-ai/charts"
echo "$sha"
