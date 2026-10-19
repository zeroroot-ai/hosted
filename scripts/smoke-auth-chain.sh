#!/usr/bin/env bash
# smoke-auth-chain.sh — post-bringup assertions for the auth chain.
#
# Runs against an already-up gibson cluster (kind or EKS) and asserts the
# specific failure modes that produced the 2026-05-15 dashboard outage:
#
#   1. ext-authz env var EXT_AUTHZ_FGA_ADDR points at OpenFGA's HTTP port
#      (regression check for deploy#140 — wrong port = silent gRPC UNAVAILABLE).
#
#   2. ext-authz mounted /etc/gibson/registry.yaml contains entries for
#      every gibson.<svc>.v1.<Svc>.* whose proto-annotated registry the
#      daemon expects — minimum: gibson.graph.v1.GraphService (the service
#      whose missing entries produced the 403 sweep on /findings + /graph
#      after the OCI publish workflow went silent — see gibson#96).
#
#   3. ext-authz pod is Ready with RESTARTS=0 — regression check for the
#      liveness probe failure mode (deploy#142) during cold cluster
#      bringup or post-host-reboot SPIRE-CSI race.
#
#   4. ext-authz container log contains no "FGA unavailable" or "FATAL"
#      lines in the most recent 5 minutes. Either is a strong signal
#      that the startup self-check (ext-authz#24) caught something OR
#      that FGA transport is actively failing.
#
#   5. Unauthenticated probe of dashboard `/api/missions` returns 401 or
#      302 (NOT 500). Confirms: dashboard → Envoy → ext-authz → daemon
#      reaches at least the auth decision; only the lack of a session
#      cookie blocks the response. A 500 indicates the chain itself is
#      broken (deploy#140-class regression).
#
# This is the INFRASTRUCTURE half of the auth-chain smoke (deploy#143).
# The FULL signup → list-resources smoke (Playwright signup form +
# Bearer-authenticated calls to all 6 endpoints) is gated on the
# Playwright orchestrator at scripts/test-signup-e2e.sh and on the
# kind cluster reliably reaching gibson-operators Ready (deploy#82 /
# cluster-self-healing epic). That part is a follow-up.
#
# Usage:
#   bash scripts/smoke-auth-chain.sh                  # against current kubectl context
#   NAMESPACE=other-ns bash scripts/smoke-auth-chain.sh
#   bash scripts/smoke-auth-chain.sh --skip-http      # skip step 5 (no dashboard available)
#
# Exit codes:
#   0 — all assertions passed (or gracefully skipped because ext-authz not yet installed)
#   1 — at least one assertion failed
#   2 — kubectl not available / cluster unreachable

set -euo pipefail

NAMESPACE="${NAMESPACE:-gibson}"
EXPECTED_HTTP_PORT="${EXPECTED_HTTP_PORT:-8080}"
EXPECTED_GRPC_PORT="${EXPECTED_GRPC_PORT:-8081}"
REQUIRED_SERVICES="${REQUIRED_SERVICES:-gibson.graph.v1.GraphService gibson.daemon.v1.DaemonService gibson.tenant.v1.TenantAdminService}"
# Canary full-method paths. The service-prefix check above passes as long as
# ANY method of a service is present, so it cannot catch an individual RPC that
# a stale sdk.version pin is missing (the service prefix still matches). These
# fully-qualified methods assert specific RPCs are present; add a canary here
# whenever a new DaemonService RPC ships so a too-old registry pin fails the
# smoke test before it reaches a cluster. See deploy#619 / gibson#96.
REQUIRED_METHODS="${REQUIRED_METHODS:-/gibson.daemon.v1.DaemonService/CreateMissionDefinition /gibson.daemon.v1.DaemonService/UpdateMissionDefinition}"
DASHBOARD_PROBE_URL="${DASHBOARD_PROBE_URL:-https://app.zeroroot.ai:30443/api/missions}"
SKIP_HTTP="${SKIP_HTTP:-0}"
LOG_SINCE="${LOG_SINCE:-5m}"

# --- argv ---
for arg in "$@"; do
  case "$arg" in
    --skip-http) SKIP_HTTP=1 ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; NC='\033[0m'
heading() { echo -e "\n${CYN}=== $* ===${NC}"; }
pass()    { echo -e "${GRN}[PASS]${NC} $*"; }
warn()    { echo -e "${YEL}[WARN]${NC} $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; FAILED=$((FAILED + 1)); }

FAILED=0
SKIPPED=0

if ! command -v kubectl >/dev/null 2>&1; then
  echo "smoke-auth-chain: kubectl not on PATH" >&2
  exit 2
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "smoke-auth-chain: kubectl context unreachable" >&2
  exit 2
fi

# --- step 0: is ext-authz even installed? ---
heading "Assertion 0: ext-authz deployment exists"
if ! kubectl -n "${NAMESPACE}" get deploy gibson-ext-authz >/dev/null 2>&1; then
  # A smoke test that exits 0 because the thing it tests is absent reports
  # "auth chain fine" for a cluster that has no auth chain. The deploy#82
  # pre-Phase-7 window this skip was written for is long closed, and the
  # repo it cites no longer exists.
  fail "ext-authz deployment not present in ns/${NAMESPACE}. There is no auth chain to assert, so this is a failure, not a skip."
fi
pass "ext-authz deployment found"

# --- step 1: FGA_ADDR uses HTTP port ---
heading "Assertion 1: EXT_AUTHZ_FGA_ADDR points at HTTP port (deploy#140)"
FGA_ADDR=$(kubectl -n "${NAMESPACE}" get deploy gibson-ext-authz \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EXT_AUTHZ_FGA_ADDR")].value}')
echo "  EXT_AUTHZ_FGA_ADDR=${FGA_ADDR}"
if [[ -z "${FGA_ADDR}" ]]; then
  fail "EXT_AUTHZ_FGA_ADDR is empty"
elif [[ "${FGA_ADDR}" == *:${EXPECTED_GRPC_PORT} ]]; then
  fail "EXT_AUTHZ_FGA_ADDR ends in :${EXPECTED_GRPC_PORT} (gRPC port). ext-authz uses HTTP/JSON and MUST dial port ${EXPECTED_HTTP_PORT}. See deploy#140."
elif [[ "${FGA_ADDR}" == *:${EXPECTED_HTTP_PORT} ]]; then
  pass "FGA addr uses HTTP port ${EXPECTED_HTTP_PORT}"
else
  warn "EXT_AUTHZ_FGA_ADDR=${FGA_ADDR} does not end in :${EXPECTED_HTTP_PORT} or :${EXPECTED_GRPC_PORT}. Custom port — verify manually."
fi

# --- step 2: registry has the proto-annotated services ---
heading "Assertion 2: ext-authz mounted registry has all required services (deploy#146 / gibson#96)"
EAP=$(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/component=ext-authz \
  -o jsonpath='{.items[0].metadata.name}')
if [[ -z "${EAP}" ]]; then
  fail "no ext-authz pod found"
else
  # The ext-authz image is distroless (ext-authz#25) — no `tar`, no
  # shell, so `kubectl cp` (which streams via tar) and `kubectl exec
  # sh` both fail. Use `kubectl debug --target=ext-authz` to attach an
  # ephemeral container with busybox tools that SHARES the ext-authz
  # process namespace. From there, read the registry file through the
  # target's proc-fs root: `/proc/1/root/etc/gibson/registry.yaml` —
  # the init container's emptyDir mount at /etc/gibson is visible
  # through PID 1's filesystem root. Canonical distroless-pod-file-
  # read pattern.
  #
  # Requires kubectl 1.25+ client (ephemeral containers GA) + k8s
  # 1.23+ server. CI's kubectl (installed by helm/kind-action) is
  # current; older local-dev clients get a clear error pointing at
  # the version. See zeroroot-ai/deploy#157.
  REG_TMP=$(mktemp)
  REG_ERR=$(mktemp)
  if ! kubectl -n "${NAMESPACE}" debug -i -q "${EAP}" \
       --image=busybox:1.36 --target=ext-authz \
       -- sh -c 'cat /proc/1/root/etc/gibson/registry.yaml' \
       > "${REG_TMP}" 2> "${REG_ERR}"; then
    if grep -q "EphemeralContainers" "${REG_ERR}" 2>/dev/null; then
      fail "kubectl client too old for ephemeral containers (need 1.25+). Run \`kubectl version --client\` to check."
    else
      fail "could not read /etc/gibson/registry.yaml from ${EAP} via kubectl debug. Stderr: $(head -3 "${REG_ERR}" | tr '\n' ' ')"
    fi
  elif [[ ! -s "${REG_TMP}" ]]; then
    fail "kubectl debug succeeded but registry.yaml was empty — init container's OCI pull may have written nothing"
  else
    for svc in ${REQUIRED_SERVICES}; do
      if grep -q "/${svc}/" "${REG_TMP}"; then
        pass "registry contains /${svc}/*"
      else
        fail "registry MISSING /${svc}/* — likely a stale OCI artifact pin (sdk.version too old vs the gibson release). See gibson#96."
      fi
    done
    # Canary individual RPCs: the service-prefix check can't catch a single
    # missing method when the service is otherwise present. A stale pin that
    # predates a newer RPC fails here. See deploy#619.
    for method in ${REQUIRED_METHODS}; do
      if grep -q "\"${method}\"" "${REG_TMP}"; then
        pass "registry contains ${method}"
      else
        fail "registry MISSING ${method} — stale sdk.version pin predates this RPC; bump sdk.version to a registry tag that includes it. See deploy#619."
      fi
    done
  fi
  rm -f "${REG_TMP}" "${REG_ERR}"
fi

# --- step 3: pod is Ready with no restarts ---
heading "Assertion 3: ext-authz pod is Ready with RESTARTS=0 (deploy#142)"
READY=$(kubectl -n "${NAMESPACE}" get pod "${EAP}" -o jsonpath='{.status.containerStatuses[?(@.name=="ext-authz")].ready}')
RESTARTS=$(kubectl -n "${NAMESPACE}" get pod "${EAP}" -o jsonpath='{.status.containerStatuses[?(@.name=="ext-authz")].restartCount}')
echo "  ready=${READY} restarts=${RESTARTS}"
if [[ "${READY}" != "true" ]]; then
  fail "ext-authz container not Ready"
elif [[ "${RESTARTS:-0}" -gt 1 ]]; then
  # 1 is tolerable (post-host-reboot recovery); >1 is a regression signal.
  fail "ext-authz has ${RESTARTS} restarts — suggests the startupProbe regressed (deploy#142)"
else
  pass "ext-authz Ready=${READY} restarts=${RESTARTS}"
fi

# --- step 4: container log clean of FGA unavailable / FATAL ---
heading "Assertion 4: ext-authz log has no FGA-unavailable / FATAL lines in the last ${LOG_SINCE}"
LOG_TMP=$(mktemp)
# The log fetch FUNDS the assertion below, so its failure must be visible.
# With `|| true` a failed fetch left an empty (or error-text) file, both
# greps counted 0, and the step printed PASS "no FGA-unavailable / FATAL
# lines" having read no logs at all — the deploy#1398 vacuous-green shape.
set +e
kubectl -n "${NAMESPACE}" logs deploy/gibson-ext-authz --since="${LOG_SINCE}" >"${LOG_TMP}" 2>&1
LOGS_RC=$?
set -e
if [[ "${LOGS_RC}" -ne 0 ]]; then
  fail "could not read ext-authz logs (kubectl rc=${LOGS_RC}) — assertion 4 is UNEVALUATED, which is not the same as clean. Output: $(head -c 200 "${LOG_TMP}")"
else
  FGA_ERR_COUNT=$(grep -c 'FGA unavailable' "${LOG_TMP}" 2>/dev/null || true)
  FGA_ERR_COUNT="${FGA_ERR_COUNT:-0}"
  FATAL_COUNT=$(grep -c 'FATAL' "${LOG_TMP}" 2>/dev/null || true)
  FATAL_COUNT="${FATAL_COUNT:-0}"
  if [[ "${FGA_ERR_COUNT}" -gt 0 ]]; then
    fail "${FGA_ERR_COUNT} 'FGA unavailable' lines in last ${LOG_SINCE}. Sample:"
    grep 'FGA unavailable' "${LOG_TMP}" | head -3
  elif [[ "${FATAL_COUNT}" -gt 0 ]]; then
    fail "${FATAL_COUNT} 'FATAL' lines in last ${LOG_SINCE}. Sample:"
    grep 'FATAL' "${LOG_TMP}" | head -3
  else
    pass "no FGA-unavailable / FATAL lines in the last ${LOG_SINCE}"
  fi
fi
rm -f "${LOG_TMP}"

# --- step 5: unauthenticated dashboard probe returns 401/302, not 500 ---
heading "Assertion 5: unauthenticated dashboard probe (${DASHBOARD_PROBE_URL})"
if [[ "${SKIP_HTTP}" == "1" ]]; then
  warn "SKIP_HTTP=1 — skipping the dashboard HTTP probe"
  SKIPPED=$((SKIPPED + 1))
else
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not on PATH — skipping dashboard HTTP probe"
    SKIPPED=$((SKIPPED + 1))
  else
    CODE=$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 "${DASHBOARD_PROBE_URL}" || echo "000")
    echo "  HTTP ${CODE} ${DASHBOARD_PROBE_URL}"
    if [[ "${CODE}" == "401" || "${CODE}" == "302" || "${CODE}" == "307" ]]; then
      pass "unauth probe returned ${CODE} (auth chain reachable, missing session cookie as expected)"
    elif [[ "${CODE}" == "500" || "${CODE}" == "503" ]]; then
      fail "unauth probe returned ${CODE} — auth chain itself is broken (deploy#140-class regression)"
    elif [[ "${CODE}" == "000" ]]; then
      warn "dashboard not reachable at ${DASHBOARD_PROBE_URL} (DNS / cluster-routing); skipping"
      SKIPPED=$((SKIPPED + 1))
    else
      warn "unexpected HTTP ${CODE} — investigate manually"
    fi
  fi
fi

# --- summary ---
heading "Summary"
echo "  Failed: ${FAILED}"
echo "  Skipped (non-fatal): ${SKIPPED}"
if [[ "${FAILED}" -gt 0 ]]; then
  exit 1
fi
pass "all auth-chain smoke assertions passed"
exit 0
