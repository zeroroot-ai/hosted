# shellcheck shell=bash
# ---------------------------------------------------------------------------
# argo-diag.sh (library) — keep the state of Argo CD for a run artifact.
#
#   argo_diag_save <dir>
#
# Writes three files to <dir>:
#   application-controller.log           the controller log of the last
#                                        WAIT_APPS_LOG_SINCE (3h)
#   application-controller.previous.log  the log of a container that restarted
#   applications.json                    the name, the managedFields and the
#                                        status of each Application, with no
#                                        source and no values
#                                        (argo-status-only.py)
#
# hosted is public, and so is each run artifact: no Application may carry a
# secret inline. A diagnostic never changes an exit path: each command ends in
# `|| true`.
# ---------------------------------------------------------------------------

ARGO_DIAG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

argo_diag_save() {
  local dir="$1"
  mkdir -p "$dir" || true
  kubectl -n argocd logs statefulset/argocd-application-controller --since="${WAIT_APPS_LOG_SINCE:-3h}" \
    > "$dir/application-controller.log" 2>&1 || true
  kubectl -n argocd logs statefulset/argocd-application-controller --previous \
    > "$dir/application-controller.previous.log" 2>&1 || true
  kubectl -n argocd get applications -o json 2>/dev/null \
    | python3 "$ARGO_DIAG_LIB_DIR/argo-status-only.py" > "$dir/applications.json" 2>&1 || true
  printf '  the whole controller log and each Application are in %s\n' "$dir" >&2
}
