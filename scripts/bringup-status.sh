#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# bringup-status.sh — single "where is bringup stuck?" surface (deploy#757).
#
# Reads the declared bringup DAG (bringup-dag.yaml) and reports the FIRST stage
# that is not yet ready, in declared order, with its blocked_hint — so an opaque
# Init/CrashLoop points at the real upstream cause instead of requiring manual
# archaeology across init-waits, hooks, and operator conditions.
#
# A stage owned by an Argo Application counts only when the overlay of the
# environment loads that Application: an Application in gitops/envs/<env>/
# outside pending/ and manifests/. A stage whose Application the overlay does
# not load prints as [skip]. Before this, a healthy staging failed on
# arc-controller, which staging parks in pending/ (hosted#506).
#
# Requires: kubectl (pointed at the target cluster), python3 with PyYAML.
# Usage:
#   KUBECONFIG=/tmp/kubeconfig-zeroroot ./scripts/bringup-status.sh <env>
# Env (test seams): BRINGUP_DAG, GITOPS_ENVS (default gitops/envs).
#
# Exit codes:
#   0 — every stage ready (bringup complete).
#   1 — a stage is not ready (the blocking stage is printed).
#   2 — usage / environment error.
# ----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DAG="${BRINGUP_DAG:-${SCRIPT_DIR}/../bringup-dag.yaml}"
readonly GITOPS_ENVS="${GITOPS_ENVS:-${SCRIPT_DIR}/../gitops/envs}"
readonly ENV_NAME="${1:-}"

if [[ -z "${ENV_NAME}" ]]; then
  echo "usage: bringup-status.sh <env>" >&2
  exit 2
fi
if [[ ! -d "${GITOPS_ENVS}/${ENV_NAME}" ]]; then
  echo "ERROR: no overlay for ENV=${ENV_NAME} at ${GITOPS_ENVS}/${ENV_NAME}" >&2
  exit 2
fi

if [[ ! -f "${DAG}" ]]; then
  echo "ERROR: missing bringup DAG: ${DAG}" >&2
  exit 2
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not in PATH." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not in PATH (needed to parse bringup-dag.yaml)." >&2
  exit 2
fi

readonly NS="${GIBSON_NAMESPACE:-gibson}"

# Each probe keeps the error of a failed kubectl read in GATE_ERR, and a
# BLOCKED line prints it. A refusal never reads as "not ready" with no reason
# (scripts/lib/cluster-probe.sh, capture).
# shellcheck source=lib/cluster-probe.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/cluster-probe.sh"
GATE_ERR=""
# kget <var> <kubectl args...>: capture of kubectl, which also keeps the error
# of a failed read in GATE_ERR.
kget() {
  local __kget_var="$1"
  shift
  capture "$__kget_var" kubectl "$@" || { GATE_ERR="$PROBE_ERR"; return 1; }
}

# argo_healthy <app> -> exit 0 when the Application is Healthy. A failed read
# sets GATE_ERR. It runs in this shell, not in $(...), so GATE_ERR survives.
argo_healthy() {
  local st=""
  kget st get application "$1" -n argocd -o 'jsonpath={.status.health.status}' && [[ "$st" == Healthy ]]
}

# substage_ready <name> -> exit 0 if the substage's readiness gate is met.
# pb_condition_true <type> -> exit 0 when that condition of the PlatformBootstrap is True.
# The platform operator owns these conditions, so the gates read its own
# signal and never a name of an object it makes (hosted#645: the Secret
# zitadel-admin-token was renamed iam-admin-pat, and the gate never noticed).
pb_condition_true() {
  local st=""
  kget st get platformbootstrap -o "jsonpath={.items[0].status.conditions[?(@.type==\"$1\")].status}" && [[ "$st" == True ]]
}

substage_ready() {
  case "$1" in
    zitadel-admin-token)
      pb_condition_true AdminTokenReady ;;
    platform-bootstrap)
      # The exit code of the read is the gate. kget needs a variable for the output.
      # shellcheck disable=SC2034
      local mk=""
      pb_condition_true Ready \
        && kget mk get secret -n "${NS}" gibson-master-key ;;
    daemon)
      # By the component label of the chart, not by a release-prefixed name.
      local rr=""
      kget rr get statefulset -n "${NS}" -l app.kubernetes.io/component=daemon \
        -o 'jsonpath={.items[*].status.readyReplicas}' && [[ "$rr" =~ [1-9] ]] ;;
    edge)
      local rr=""
      kget rr get deploy -n "${NS}" -l app.kubernetes.io/component=ext-authz \
        -o 'jsonpath={.items[*].status.readyReplicas}' && [[ "$rr" =~ [1-9] ]] ;;
    *)
      return 1 ;;
  esac
}

# The Applications the overlay of ENV_NAME loads, one name per line.
mapfile -t LOADED < <(python3 - "${GITOPS_ENVS}/${ENV_NAME}" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
for f in sorted(root.rglob("*.yaml")):
    parts = f.relative_to(root).parts
    if "pending" in parts or "manifests" in parts:
        continue
    for d in yaml.safe_load_all(f.read_text()):
        if isinstance(d, dict) and d.get("kind") == "Application":
            print(d["metadata"]["name"])
PY
)

# loaded <app> -> exit 0 when the overlay loads that Application.
loaded() {
  local a
  for a in "${LOADED[@]}"; do [[ "$a" == "$1" ]] && return 0; done
  return 1
}

# Emit the DAG stages as TSV: kind<TAB>name<TAB>owner<TAB>blocked_hint
mapfile -t ROWS < <(python3 - "${DAG}" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for kind in ("stages", "substages"):
    for s in (doc.get(kind) or []):
        print("\t".join([
            kind,
            s.get("name", ""),
            s.get("owner", ""),
            s.get("readiness", ""),
            s.get("blocked_hint", ""),
        ]))
PY
)

blocked=""
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r kind name owner readiness hint <<< "${row}"
  ready=1
  GATE_ERR=""
  if [[ "${owner}" == argo:* ]]; then
    app="${owner#argo:}"
    if ! loaded "${app}"; then
      printf '  [skip]    %-28s the overlay of %s does not load Application %s\n' "${name}" "${ENV_NAME}" "${app}"
      continue
    fi
    if argo_healthy "${app}"; then ready=0; else ready=1; fi
  elif [[ "${kind}" == "substages" ]]; then
    if substage_ready "${name}"; then ready=0; else ready=1; fi
  else
    # pre-argo / terraform stages: not observable from kubectl — report as a
    # soft check (assume satisfied once Argo stages start reconciling).
    ready=0
  fi

  if [[ ${ready} -eq 0 ]]; then
    printf '  [ok]      %-28s %s\n' "${name}" "${readiness}"
  else
    printf '  [BLOCKED] %-28s %s\n' "${name}" "${readiness}"
    echo ""
    echo "bringup blocked at: ${name} (${owner})"
    echo "  gate:  ${readiness}"
    echo "  hint:  ${hint}"
    [[ -z "${GATE_ERR}" ]] || echo "  error: ${GATE_ERR}"
    blocked="${name}"
    break
  fi
done

if [[ -n "${blocked}" ]]; then
  exit 1
fi
echo ""
echo "bringup complete: every declared stage is ready."
exit 0
