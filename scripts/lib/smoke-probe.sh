# shellcheck shell=bash
# smoke-probe.sh: the output and probe helpers of the signup smoke.
#
# THE RULE
#
# No probe sends its error to /dev/null and falls back to an empty answer.
# Staging run 38465547479 failed step 6 with "secret/infra/* missing". The
# secrets were there. The probe used a token that may not list a tenant
# namespace, OpenBao refused, the refusal went to /dev/null, and the fallback
# "[]" read as "missing". A refusal is reported as a refusal, with the first
# line of its error. scripts/check-smoke-probes-loud.sh enforces the rule.
#
# Sourced by scripts/smoke-signup.sh, and by tests/harness/smoke-probe.bats.
# The caller sets NAMESPACE.

# capture (stdout in a variable, first error line in PROBE_ERR) lives in
# cluster-probe.sh, the one copy for the smoke, the drill and kind.
# shellcheck source=cluster-probe.sh
source "$(dirname "${BASH_SOURCE[0]}")/cluster-probe.sh"

# The output helpers of the smoke. They replace the pass and fail of
# cluster-probe.sh, because the smoke counts its failures in FAILED.
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[0;33m'; CYN='\033[0;36m'; NC='\033[0m'
FAILED="${FAILED:-0}"
heading() { printf "\n${CYN}=== %s ===${NC}\n" "$*"; }
pass()    { printf "${GRN}[PASS]${NC} %s\n" "$*"; }
warn()    { printf "${YEL}[WARN]${NC} %s\n" "$*"; }
fail()    { printf "${RED}[FAIL]${NC} %s\n" "$*" >&2; FAILED=$((FAILED + 1)); }

# not_found: the last failed probe was a NotFound from the API server.
not_found() { [[ "$PROBE_ERR" == *"NotFound"* || "$PROBE_ERR" == *"not found"* ]]; }

# secret_data <var> <secret> <key>: the decoded value of one key of a Secret
# in NAMESPACE. A key with a dot is passed escaped (ca\.crt). The value goes
# only into <var>, never to stdout or a log.
secret_data() {
  local __var="$1" __b64="" __val=""
  capture __b64 kubectl -n "${NAMESPACE}" get secret "$2" -o "jsonpath={.data.$3}" || return $?
  if ! __val="$(printf '%s' "$__b64" | base64 -d)"; then
    PROBE_ERR="the value of $3 in the Secret $2 is not base64"
    return 1
  fi
  printf -v "$__var" '%s' "$__val"
}

# bao_kv_list <pod> <token> <bao namespace> <path>: `bao kv list` in the
# OpenBao pod. The token reaches bao on the stdin of the exec, never on the
# argv of kubectl or of a process in the pod (drill sweep row 28).
bao_kv_list() {
  printf '%s\n' "$2" \
    | kubectl -n "${NAMESPACE}" exec -i "$1" -c openbao -- \
        sh -c 'IFS= read -r BAO_TOKEN; [ -n "$BAO_TOKEN" ] || { echo "the token did not arrive on stdin" >&2; exit 97; }; export BAO_TOKEN; BAO_NAMESPACE="$1"; export BAO_NAMESPACE; exec bao kv list -format=json "$2"' \
        sh "$3" "$4"
}

# The data-plane secrets the provisioning saga writes in the namespace of each
# tenant (gibson pkg/platform/dataplane/credentials.go). The trace-backend
# secret was retired (gibson#755, tenant-operator#387).
TENANT_INFRA_KEYS=(neo4j postgres redis vector)

# assert_tenant_infra <tenant slug>: step 6. The OpenBao namespace
# tenant-<slug> holds secret/infra/{neo4j,postgres,redis,vector}.
#
# The probe lists with the token of the tenant operator, the writer of these
# paths: Secret gibson-tenant-operator-vault, policy tenant-operator, which has
# list on tenant-*. The token in gibson-openbao-keys is the platform-operator
# token since the root token was retired, and its policy has no tenant path.
assert_tenant_infra() {
  local tenant_ns="tenant-$1" bao_pod="" token="" keys="" key missing=()
  if ! capture bao_pod kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/component=openbao \
      -o 'jsonpath={.items[0].metadata.name}' || [[ -z "$bao_pod" ]]; then
    fail "no OpenBao pod (app.kubernetes.io/component=openbao) in ${NAMESPACE}: ${PROBE_ERR:-the list is empty}"
    return 0
  fi
  if ! secret_data token gibson-tenant-operator-vault VAULT_ADMIN_TOKEN || [[ -z "$token" ]]; then
    fail "cannot read the tenant-operator token (Secret gibson-tenant-operator-vault, key VAULT_ADMIN_TOKEN): ${PROBE_ERR:-the value is empty}"
    return 0
  fi
  if ! capture keys bao_kv_list "$bao_pod" "$token" "$tenant_ns" secret/infra; then
    if [[ "$PROBE_ERR" == *"No value found"* ]]; then
      keys="[]"
    else
      token=""
      fail "OpenBao refused the list of secret/infra in ${tenant_ns}: ${PROBE_ERR}"
      return 0
    fi
  fi
  token=""
  for key in "${TENANT_INFRA_KEYS[@]}"; do
    if printf '%s' "$keys" | grep -q "\"${key}\""; then
      pass "secret/infra/${key} present in ${tenant_ns}"
    else
      missing+=("$key")
    fi
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    fail "secret/infra/{${missing[*]}} missing in ${tenant_ns}: OpenBao listed ${keys}. The daemon's secrets broker will 412 on the first authenticated dashboard RPC (tenant-operator#189)"
  fi
  return 0
}
