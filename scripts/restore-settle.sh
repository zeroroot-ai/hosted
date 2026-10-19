#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restore-settle.sh — make Git the truth again after a restore (D91).
#
#   restore-settle.sh <env>          (make restore-settle ENV=<env>)
#
# A restore of an EC2 or EKS env puts three Postgres recovery values on the
# live gibson Application as Helm parameters (scripts/lib/restore-recovery.sh),
# and opens a PR that writes the new archive name into the env overlay. Once
# that PR has merged AND Argo renders the gibson chart from a commit that
# holds it, the parameters say nothing that Git does not say, except the two
# recovery values that CNPG reads once, at bootstrap. This removes all three.
#
# It refuses in each case where the removal would change what the cluster
# does:
#   * a live parameter set that is not exactly the three of D91;
#   * an overlay, at the revision Argo renders, that names another archive
#     than the live backup.serverName. Then the removal would point the
#     cluster at another archive directory.
#
# The caller has a kubeconfig for the cluster: `make restore-settle` runs this
# through scripts/with-cluster.sh on EC2.
# ---------------------------------------------------------------------------
set -euo pipefail

ENV_NAME="${1:-}"
[ -n "$ENV_NAME" ] || { echo "usage: restore-settle.sh <env>" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GITOPS_PATH="${GITOPS_PATH:-gitops/envs/${ENV_NAME}}"
# SETTLE_TIMEOUT and SETTLE_POLL are lib/settle-wait.sh's.

log() { printf '\n\033[1;32m▶\033[0m [restore-settle %s] %s\n' "$ENV_NAME" "$*"; }
die() { printf '\033[1;31m✗ [restore-settle %s] %s\033[0m\n' "$ENV_NAME" "$*" >&2; exit 1; }

# shellcheck disable=SC2034  # restore-recovery.sh reads HERE for its own sources
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# RECOVERY_PARAMETERS, the one list of the three names.
# shellcheck source=lib/restore-recovery.sh
. "$HERE/lib/restore-recovery.sh"
# settle_wait, shared with test/dr/settle-probe.sh.
# shellcheck source=lib/settle-wait.sh
. "$HERE/lib/settle-wait.sh"

kubectl -n argocd get application gibson -o json > "$WORK/app.json" \
  || die "could not read Application argocd/gibson"

# The live parameters, and the hosted revision Argo renders the values from.
# shellcheck disable=SC2086
eval "$(python3 - "$WORK/app.json" $RECOVERY_PARAMETERS <<'PY'
import json, shlex, sys
app = json.load(open(sys.argv[1]))
want = sys.argv[2:]
srcs = app["spec"].get("sources") or []
params = ((srcs[0].get("helm") or {}).get("parameters") or []) if srcs else []
names = [p.get("name") for p in params]
rev = ""
revs = (app.get("status") or {}).get("sync", {}).get("revisions") or []
for i, s in enumerate(srcs):
    if s.get("ref") == "values" and i < len(revs):
        rev = revs[i]
print("LIVE_NAMES=%s" % shlex.quote(" ".join(n or "" for n in names)))
print("LIVE_ARCHIVE=%s" % shlex.quote(next((p.get("value", "") for p in params
                                             if p.get("name") == "platformPostgres.backup.serverName"), "")))
print("VALUES_REVISION=%s" % shlex.quote(rev))
PY
)" || die "could not read the parameters of Application gibson"

if [ -z "$LIVE_NAMES" ]; then
  log "Application gibson has no Helm parameters: Git is already the truth"
  exit 0
fi
[ "$LIVE_NAMES" = "$RECOVERY_PARAMETERS" ] \
  || die "Application gibson carries the parameters '${LIVE_NAMES}', not the three of D91 (${RECOVERY_PARAMETERS}). Something other than a restore set them. Refusing to remove them blind"
[ -n "$VALUES_REVISION" ] \
  || die "Application gibson reports no synced revision for its values source, so this cannot prove which overlay Argo renders"

git -C "$REPO" fetch -q origin main || die "could not fetch origin main"
git -C "$REPO" cat-file -e "${VALUES_REVISION}^{commit}" 2>/dev/null \
  || die "the revision ${VALUES_REVISION} that Argo renders is not in this checkout after a fetch of origin main"
GIT_ARCHIVE="$(git -C "$REPO" show "${VALUES_REVISION}:${GITOPS_PATH}/values.yaml" | python3 -c '
import sys, yaml
v = yaml.safe_load(sys.stdin) or {}
print(((v.get("platformPostgres") or {}).get("backup") or {}).get("serverName") or "")')" \
  || die "could not read ${GITOPS_PATH}/values.yaml at ${VALUES_REVISION}"

[ "$GIT_ARCHIVE" = "$LIVE_ARCHIVE" ] \
  || die "Argo renders ${GITOPS_PATH}/values.yaml at ${VALUES_REVISION}, which names the archive '${GIT_ARCHIVE}'. The live cluster archives to '${LIVE_ARCHIVE}'. Merge the catch-up PR of the restore, wait for Argo to render that commit, and run this again. Removing the parameters now would point Postgres at another archive"
log "Git at ${VALUES_REVISION} names the live archive ${LIVE_ARCHIVE}"

kubectl -n argocd patch application gibson --type json \
  -p '[{"op":"remove","path":"/spec/sources/0/helm/parameters"}]' >/dev/null \
  || die "could not remove the parameters from Application gibson"
log "removed the three recovery parameters from Application gibson"

settle_wait "$LIVE_ARCHIVE" "the parameters went"
printf '\n\033[0;32mrestore-settle ENV=%s complete.\033[0m Git is the truth again: the overlay names the archive %s, and the gibson Application has no parameters.\n' \
  "$ENV_NAME" "$LIVE_ARCHIVE"
