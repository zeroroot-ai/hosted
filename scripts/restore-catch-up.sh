#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restore-catch-up.sh — open the PR that brings Git back to the truth after a
# restore, from the bundle the restore wrote (D91, hosted#687).
#
#   restore-catch-up.sh <bundle-dir>
#
# The restore verb derives the new Postgres archive name and writes a bundle
# (scripts/lib/restore-recovery.sh, restore_catch_up):
#
#   meta.env     ENV_NAME RESTORE_FROM GITOPS_PATH RESTORE_ARCHIVE_NAME
#                BRANCH TITLE, one KEY=value per line
#   values.yaml  the env overlay with the new serverName
#   body.md      the PR body
#
# This verb does the Git half: a branch from origin/main, one changed line,
# a push, and `gh pr create`. It is a separate script so that the workflow
# can run it in a small job with the write token, and keep the recreate job,
# which holds the bringup role, at contents: read. A workstation run of the
# restore calls it at once with the operator's own credential.
#
# It prints the PR URL on its last line, as `CATCH_UP_PR=<url>`.
# ---------------------------------------------------------------------------
set -euo pipefail

BUNDLE="${1:-}"
[ -n "$BUNDLE" ] || { echo "usage: restore-catch-up.sh <bundle-dir>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

die() { printf '\033[1;31m✗ [restore-catch-up] %s\033[0m\n' "$*" >&2; exit 1; }
log() { printf '\n\033[1;32m▶\033[0m [restore-catch-up] %s\n' "$*"; }

for f in meta.env values.yaml body.md; do
  [ -s "$BUNDLE/$f" ] || die "the bundle ${BUNDLE} has no ${f}. The restore verb writes it (scripts/lib/restore-recovery.sh)"
done
ENV_NAME=""; RESTORE_FROM=""; GITOPS_PATH=""; RESTORE_ARCHIVE_NAME=""; BRANCH=""; TITLE=""
while IFS='=' read -r k v; do
  case "$k" in
    ENV_NAME|RESTORE_FROM|GITOPS_PATH|RESTORE_ARCHIVE_NAME|BRANCH|TITLE) printf -v "$k" '%s' "$v" ;;
    ''|'#'*) ;;
    *) die "meta.env holds an unknown key ${k}" ;;
  esac
done < "$BUNDLE/meta.env"
for k in ENV_NAME RESTORE_FROM GITOPS_PATH RESTORE_ARCHIVE_NAME BRANCH TITLE; do
  [ -n "${!k}" ] || die "meta.env sets no ${k}"
done
[ "$BRANCH" = "restore/${ENV_NAME}-${RESTORE_FROM}" ] \
  || die "the branch ${BRANCH} is not restore/${ENV_NAME}-${RESTORE_FROM}. Refusing to push it"
case "$GITOPS_PATH" in
  gitops/envs/*) ;;
  *) die "GITOPS_PATH ${GITOPS_PATH} is not an env overlay" ;;
esac
# The bundle names the archive that the overlay must name. One check, so a
# bundle that another step edited cannot write a different name.
got="$(python3 -c '
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
print(((v.get("platformPostgres") or {}).get("backup") or {}).get("serverName") or "")' "$BUNDLE/values.yaml")"
[ "$got" = "$RESTORE_ARCHIVE_NAME" ] \
  || die "the bundle overlay names serverName '${got}', not ${RESTORE_ARCHIVE_NAME}"
command -v gh >/dev/null 2>&1 \
  || die "gh is not on PATH, so Git cannot catch up. Open a PR that sets platformPostgres.backup.serverName to ${RESTORE_ARCHIVE_NAME} in ${GITOPS_PATH}/values.yaml (D91)"

WORK="$(mktemp -d)"
trap 'git -C "$REPO" worktree remove --force "$WORK/catch-up" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
log "a branch ${BRANCH} from origin/main, with one changed line of ${GITOPS_PATH}/values.yaml"
git -C "$REPO" fetch -q origin main \
  || die "could not fetch origin main for the catch-up PR"
git -C "$REPO" worktree add -q -b "$BRANCH" "$WORK/catch-up" origin/main \
  || die "could not make a worktree for the catch-up branch ${BRANCH}. A branch of that name exists when this restore already opened its PR"
# The bundle overlay was written from the checkout of the restore. main may
# have moved since, so the one line is written again into the overlay of
# origin/main, and the bundle overlay is the proof of the name only.
python3 "$HERE/lib/overlay-server-name.py" "$WORK/catch-up/${GITOPS_PATH}/values.yaml" "$RESTORE_ARCHIVE_NAME" \
    > "$WORK/catch-up/${GITOPS_PATH}/values.yaml.new" \
  && mv "$WORK/catch-up/${GITOPS_PATH}/values.yaml.new" "$WORK/catch-up/${GITOPS_PATH}/values.yaml" \
  || die "could not write ${RESTORE_ARCHIVE_NAME} into ${GITOPS_PATH}/values.yaml of origin/main"
git -C "$WORK/catch-up" add "${GITOPS_PATH}/values.yaml"
# A runner has no git identity. A workstation keeps its own.
git -C "$WORK/catch-up" \
  -c user.name="$(git -C "$REPO" config user.name || echo 'github-actions[bot]')" \
  -c user.email="$(git -C "$REPO" config user.email || echo '41898282+github-actions[bot]@users.noreply.github.com')" \
  commit -q -m "$TITLE" \
  || die "could not commit the catch-up overlay. Does origin/main already name ${RESTORE_ARCHIVE_NAME}?"
git -C "$WORK/catch-up" push -q origin "$BRANCH" \
  || die "could not push the catch-up branch ${BRANCH}"
url="$(gh pr create --head "$BRANCH" --base main --title "$TITLE" --body-file "$BUNDLE/body.md")" \
  || die "the catch-up PR did not open. The branch ${BRANCH} is pushed: open a PR from it"
printf '  ✓ %s\n' "$url"
printf 'CATCH_UP_PR=%s\n' "$url"
