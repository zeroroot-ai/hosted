# shellcheck shell=bash
# settle-wait.sh — what a change to the gibson Application must come to
# before anyone calls it settled (D91). Two callers: scripts/restore-settle.sh
# (the removal of every recovery parameter after the catch-up PR) and
# test/dr/settle-probe.sh (the drill's proof that the removal is safe).
#
# The caller supplies die() and, if it wants, SETTLE_TIMEOUT (default 900 s)
# and SETTLE_POLL (default 10 s; a suite sets 0).

SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-900}"
SETTLE_POLL="${SETTLE_POLL:-10}"

# gibson_app_parameter_names — the Helm parameter names on sources[0] of the
# live gibson Application, space separated, in order.
gibson_app_parameter_names() {
  kubectl -n argocd get application gibson \
    -o jsonpath='{range .spec.sources[0].helm.parameters[*]}{.name}{" "}{end}' 2>/dev/null | sed 's/ $//'
}

# cluster_archive — the directory the live CNPG Cluster archives into.
cluster_archive() {
  kubectl -n gibson get cluster.postgresql.cnpg.io platform-postgres \
    -o jsonpath='{.spec.backup.barmanObjectStore.serverName}' 2>/dev/null
}

# cluster_primary_uid — the UID of the current primary pod. A new UID after a
# change means Postgres restarted or moved.
cluster_primary_uid() {
  local primary
  primary="$(kubectl -n gibson get cluster.postgresql.cnpg.io platform-postgres \
    -o jsonpath='{.status.currentPrimary}' 2>/dev/null)"
  [ -n "$primary" ] || return 1
  kubectl -n gibson get pod "$primary" -o jsonpath='{.metadata.uid}' 2>/dev/null
}

# settle_wait <archive> <what> — Application gibson Synced and Healthy FOR THE
# NEW PARAMETERS, and the Cluster archives into <archive>, within
# SETTLE_TIMEOUT. <what> names the change in the failure.
#
# Synced alone is not enough. Right after a patch of the parameters the
# status still holds the compare of the OLD ones, Synced and Healthy, and the
# archive is the same. A wait on those three returned in its first pass,
# before Argo had rendered the change, and the caller then read a Cluster
# that still had bootstrap.recovery (audit of the restore path, 2026-10-19).
# So the wait also needs the parameter names that Argo compared to be the
# names on the spec now.
#
# One read of the Application gives all four values, so they come from one
# status that Argo wrote: separate reads could take Synced from the old
# compare and the names from the new one (review of hosted#795). The check
# compares names only. That is enough for its two callers, whose patches
# remove parameters. A caller that changes only a value needs name=value.
settle_wait() {
  local want="$1" what="$2" deadline app state sync health spec compared archive
  deadline=$(( $(date +%s) + SETTLE_TIMEOUT ))
  while :; do
    app="$(kubectl -n argocd get application gibson -o json 2>/dev/null)" || app=""
    state="$(printf '%s' "${app:-{\}}" | python3 -c '
import json, sys
try:
    a = json.load(sys.stdin)
except ValueError:
    a = {}
st = a.get("status") or {}
names = lambda src: " ".join(p.get("name", "") for p in (((src or {}).get("helm") or {}).get("parameters") or []))
spec_src = ((a.get("spec") or {}).get("sources") or [{}])[0]
cmp_src = (((st.get("sync") or {}).get("comparedTo") or {}).get("sources") or [{}])[0]
print((st.get("sync") or {}).get("status", ""))
print((st.get("health") or {}).get("status", ""))
print(names(spec_src))
print(names(cmp_src))
')" || state=""
    sync="" health="" spec="" compared=""
    { IFS= read -r sync; IFS= read -r health; IFS= read -r spec; IFS= read -r compared; } <<<"$state" || true
    archive="$(cluster_archive)" || archive=""
    # Both lists are empty once restore-settle removed all three parameters,
    # and Argo compared that.
    if [ -n "$app" ] && [ "$sync" = Synced ] && [ "$health" = Healthy ] && [ "$archive" = "$want" ] \
       && [ "$compared" = "$spec" ]; then
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] \
      || die "Application gibson is sync=${sync:-<none>} health=${health:-<none>}, Argo compared the parameters '${compared:-<none>}' and the spec has '${spec:-<none>}', and the Cluster archives to '${archive:-<none>}', ${SETTLE_TIMEOUT}s after ${what}"
    sleep "$SETTLE_POLL"
  done
}
