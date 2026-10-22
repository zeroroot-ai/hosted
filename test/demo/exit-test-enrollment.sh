#!/usr/bin/env bash
# exit-test-enrollment.sh — the opencode enrollment demo, run on the kind
# cluster that `make recreate ENV=kind` stood up (zerocool-plugins#10).
#
# In plain words: a person logs in once and enrolls a coding agent once. The
# agent then runs with no person, and what it does shows up in the platform.
#
# The workflow (.github/workflows/exit-test-demo-enrollment.yml) explains the
# whole shape. This script is the half that runs against the live cluster.
# Every step below is a hard assertion. A failed step turns the run red. A
# step that depends on a failed step does not run, and the summary says so.
#
#   0. The first tenant's Owner (ADR-0093, hosted#202) has no password: the
#      first-admin Job sent a one-time offline setup link. This step reads
#      it from the gibson-first-tenant-owner-setup Secret and completes it
#      through test/platform-owner/driver.mjs (sets a password, enrolls
#      TOTP) — the same driver the Platform owner exit test uses.
#   1. `gibson login` completes as the seeded first admin. The device flow
#      is approved with no browser: the cluster's own login-client credential
#      opens a Zitadel session with the password step 0 just set and approves
#      the device request. That is the same API the login page calls.
#   2. `gibson agent enroll` mints a one-time bootstrap token.
#   3. The zerocool-agent image starts with GIBSON_BOOTSTRAP_TOKEN, completes
#      the capability-grant handshake, and writes a host key under /tmp.
#   4. A second start with no token and no person registers on the host key.
#   5. The daemon lists the agent as healthy with a fresh heartbeat. That is
#      the RPC the dashboard's component list reads.
#   6. A completion goes through the SDK shim, the daemon and the tenant's
#      default provider, and the daemon records it. The baseline profile ships
#      no model slot, so this step registers a provider from
#      EXIT_TEST_ANTHROPIC_API_KEY first. No key is a hard failure.
#   7. The agent submits a finding and reads it back from the tenant graph.
#      The finding names the agent. The agent identity names the person who
#      enrolled it. The person's own view of the graph lists the finding.
#   8. The first admin enables the GitLab connector and starts its OAuth
#      authorization (gibson#21). GitLab refuses a personal access token on
#      its MCP endpoint, so the grant must be OAuth. The script prints the
#      authorize URL. A person opens it and grants access at GitLab. The auth
#      status then reports a grant authorized by the admin's subject with the
#      mcp scope, and the connector reaches Ready.
#   9. The admin submits a mission (gibson mission submit) with one agent node
#      that names the enrolled agent. The agent claims the dispatch, lists the
#      connector's tools and calls one read-only tool against
#      DEMO_GITLAB_PROJECT with the work id of the dispatch, so the call runs
#      inside the mission. The result names the project.
#  10. The audit trail shows the call with the agent as actor and the mission
#      id of step 9, and the agent identity resolves to the enrolling person.
#  11. The admin revokes the grant. The status reports no grant, and the
#      agent's next call, again in a mission, is refused.
#  12. The test deletes the OpenBao pod. The pod returns unsealed with no hand
#      step (the static seal opens it from the keyring).
#  13. The next connector call, in a new mission, works again.
#
# Modes:
#   --selftest          offline. Proves every assertion in this file can fail.
#                       No cluster, no network, no docker.
#   --phase <p>         enroll (1 to 5 and 7), completion (1 to 3 and 6),
#                       gitlab (1 to 3, then 8 to 10, 12, 13 and 11), or all (default,
#                       1 to 5, then 7, then 6; the GitLab steps need a
#                       person at the GitLab consent page, so `all` leaves
#                       them out and no workflow runs them).
#
# Env (live mode):
#   NS            namespace                        (default: gibson)
#   RELEASE       the umbrella release name        (default: gibson)
#   DOMAIN        the platform domain              (default: gibson-domains ConfigMap)
#   EDGE_IP       the Envoy edge address           (default: the LoadBalancer ingress)
#   AGENT_IMAGE   the zerocool-agent image, pinned by digest (required)
#   GIBSON_BIN    the adk CLI binary               (default: gibson)
#   GIBSON_SRC    a zeroroot-ai/gibson checkout, for the tenant proto (step 6)
#   EXIT_TEST_ANTHROPIC_API_KEY  the provider key step 6 registers
#   DEMO_GITLAB_PROJECT the GitLab project, group/project (step 9)
#   GITLAB_INSTANCE_URL the GitLab instance  (default: https://gitlab.com)
#   AUTH_WAIT_SECONDS   how long step 8 waits for the consent (default: 900)
#   DIAG_DIR      where failure diagnostics land   (default: unset)
#   FIRST_TENANT_OWNER_EMAIL         the seeded Owner's email (default:
#                                    admin@localhost.zeroroot.ai, the
#                                    baseline profile's own value)
#   FIRST_TENANT_OWNER_SETUP_SECRET  the offline setup-link Secret name
#                                    (default: gibson-first-tenant-owner-setup)
#
# Needs Node.js + the test/platform-owner npm deps (playwright, otpauth) on
# PATH for step 0 — see .github/actions/demo-enrollment-install/action.yml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS="${NS:-gibson}"
RELEASE="${RELEASE:-gibson}"
ENVOY_SVC="${ENVOY_SVC:-${RELEASE}-envoy}"
ZITADEL_SVC="${ZITADEL_SVC:-${RELEASE}-zitadel}"
ZITADEL_LOCAL_PORT="${ZITADEL_LOCAL_PORT:-18080}"
GIBSON_BIN="${GIBSON_BIN:-gibson}"
# The sdk schema is the one the installed gibson was built against: the
# BSR label of the sdk version in gibson's go.mod. The unpinned module is
# BSR's latest push, which lagged the release gibson used and broke every
# proto option (run 36633990113: sdk v0.183.1 never reached BSR).
if [ -z "${SDK_SCHEMA:-}" ] && [ -f "${GIBSON_SRC:-}/go.mod" ]; then
  SDK_VERSION="$(awk '$1 == "github.com/zeroroot-ai/sdk" {print $2; exit}' "${GIBSON_SRC}/go.mod")"
  [ -n "$SDK_VERSION" ] && SDK_SCHEMA="buf.build/zeroroot-ai/sdk:${SDK_VERSION}"
fi
SDK_SCHEMA="${SDK_SCHEMA:-buf.build/zeroroot-ai/sdk}"
SLOT="${SLOT:-primary}"

# PHASE selects the steps a job runs. The workflow runs two jobs on two
# clusters: `enroll` always (steps 1 to 5 and 7, the finding needs no model),
# and `completion` only when a person has set the gate variable and the key
# (steps 1 to 3 to get a session and an enrolled agent, then 6). `all` is
# the whole demo on one cluster, the order a person runs it.
PHASE="${PHASE:-all}"
if [ "${1:-}" = "--phase" ]; then PHASE="${2:?--phase needs enroll | completion | all}"; shift 2; fi
# phase_steps <phase> prints the step numbers the phase runs, or nothing for
# an unknown phase.
phase_steps() {
  case "$1" in
    enroll) echo "1 2 3 4 5 7" ;;
    completion) echo "1 2 3 6" ;;
    gitlab) echo "1 2 3 8 9 10 12 13 11" ;;
    all) echo "1 2 3 4 5 7 6" ;;
    *) ;;
  esac
}
runs_step() { case " $(phase_steps "$PHASE") " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

log() { printf '\n\033[1;32m▶\033[0m %s\n' "$*"; }
die() { printf '\033[0;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

FAILED=0
declare -A STEP_RESULT
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$1"; }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }
step_result() { STEP_RESULT["$1"]="$2"; }

# ---------------------------------------------------------------------------
# Pure helpers. The selftest drives these with fixtures.
# ---------------------------------------------------------------------------

# parse_user_code reads `gibson login --no-browser` output on stdin and prints
# the device user code, or nothing.
parse_user_code() {
  sed -n -E 's/^and confirm this code:[[:space:]]+([A-Za-z0-9-]+).*$/\1/p' | head -1
}

# parse_bootstrap_token reads `gibson agent enroll` output on stdin and prints
# the one-time token, or nothing.
parse_bootstrap_token() {
  sed -n -E 's/^bootstrap_token:[[:space:]]+([^[:space:]]+).*$/\1/p' | head -1
}

# jwt_sub prints the `sub` claim of a JWT, or nothing when the token is not a
# JWT. The edge only accepts JWTs, so an opaque token here is a real defect.
jwt_sub() {
  local payload
  payload="$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')"
  case $(( ${#payload} % 4 )) in
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
  esac
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.sub // empty' 2>/dev/null || true
}

# assert_agent_listed <ListAgents json> <name> <now unix> <max age s>
# The agent is present, healthy, and heartbeated within max age.
assert_agent_listed() {
  jq -e --arg n "$2" --argjson now "$3" --argjson max "$4" '
    [.agents[]? | select(.name == $n)] as $a
    | ($a | length) > 0
    and ($a[0].health == "healthy")
    and (($a[0].lastSeen // "0") | tonumber) >= ($now - $max)' <<<"$1" >/dev/null
}

# assert_finding_listed <GraphService.GetFindings json> <id or name>
assert_finding_listed() {
  jq -e --arg k "$2" '[.findings[]? | select(.id == $k or .name == $k)] | length > 0' <<<"$1" >/dev/null
}

# assert_identity_created_by <ListAgentIdentities json> <name> <subject>
# The identity exists, is not revoked, and names the enrolling person.
assert_identity_created_by() {
  jq -e --arg n "$2" --arg s "$3" '
    [.identities[]? | select(.name == $n and .createdBySubject == $s and ((.revoked // false) | not))]
    | length > 0' <<<"$1" >/dev/null
}

# assert_completion_logged <daemon log text> <slot>
# The daemon wrote its success record for a completion on this slot.
assert_completion_logged() {
  grep -F 'complete: LLM completion succeeded' <<<"$1" | grep -E -q "(slot=|\"slot\":[[:space:]]*\")${2}([[:space:]\"]|$)"
}

# assert_finding_names_agent <probe json> <agent name>
# The stored finding names the agent that submitted it. The daemon assigns
# the id, so the name is the only attribution a reader can act on.
assert_finding_names_agent() {
  jq -e --arg n "$2" '.readBack.agent_name == $n' <<<"$1" >/dev/null
}

# assert_oauth_grant <GetConnectorAuthStatus json> <subject>
# An OAuth grant is stored, the admin's own subject authorized it, and the
# person consented to the mcp scope at the vendor.
assert_oauth_grant() {
  jq -e --arg s "$2" '.state == "CONNECTOR_AUTH_STATE_AUTHORIZED" and .authorizedBy == ("user:" + $s) and ((.scope // "") | split(" ") | index("mcp") != null)' <<<"$1" >/dev/null
}

# assert_no_grant <GetConnectorAuthStatus json>
assert_no_grant() {
  jq -e '.state == "CONNECTOR_AUTH_STATE_UNAUTHORIZED"' <<<"$1" >/dev/null
}

# assert_connector_ready <ListConnectors json> <connector id>
# The connector is listed, in phase Ready, with at least one discovered tool.
assert_connector_ready() {
  jq -e --arg id "$2" '[.connectors[]? | select(.id == $id and .phase == "Ready" and ((.discoveredTools // 0) | tonumber) > 0)] | length > 0' <<<"$1" >/dev/null
}

# assert_call_answered <probe json> <project>
# The agent's tool call succeeded and its output names the project.
assert_call_answered() {
  jq -e --arg p "$2" '.ok == true and ((.output // "") | contains($p))' <<<"$1" >/dev/null
}

# assert_call_refused <probe json>
# The agent's tool call was refused by the platform, not merely empty.
assert_call_refused() {
  jq -e '.ok == false and .refused == true' <<<"$1" >/dev/null
}

# assert_audit_names_agent <ListAuditEvents json> <agent principal id> <connector id>
# One record of a connector tool call (gibson#1288): the action
# connector.tool.call, the target connector:<id>, the actor source agent, and
# the agent principal as the actor.
assert_audit_names_agent() {
  jq -e --arg a "$2" --arg c "$3" '[.events[]? | select(.eventType == "connector.tool.call" and .actorSource == "agent" and .actorId == $a and .targetObject == ("connector:" + $c))] | length > 0' <<<"$1" >/dev/null
}

# assert_audit_names_mission <ListAuditEvents json> <agent principal id> <connector id> <mission id>
# The same record also carries details.tool, details.work_id (the work item that
# the agent claimed) and details.mission_id. A call that carries no claimed work
# id has no mission id, and the check refuses it.
assert_audit_names_mission() {
  [ -n "$4" ] || return 1
  jq -e --arg a "$2" --arg c "$3" --arg m "$4" '[.events[]? | select(.eventType == "connector.tool.call" and .actorSource == "agent" and .actorId == $a and .targetObject == ("connector:" + $c) and ((.details.tool // "") != "") and ((.details.work_id // "") != "") and ((.details.mission_id // "") == $m))] | length > 0' <<<"$1" >/dev/null
}

# assert_bao_returned <old pod uid> <new pod uid> <seal state>
# OpenBao is a new pod (a new uid), and it reports initialized and unsealed.
assert_bao_returned() {
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] && [ "$3" = unsealed ]
}

# assert_mission_id <id>: gibson mission submit --detach printed a mission id.
assert_mission_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,}$ ]]
}

# assert_host_key_kept <sha before> <sha after>
assert_host_key_kept() {
  [ -n "$1" ] && [ "$1" = "$2" ]
}

# ---------------------------------------------------------------------------
# --selftest: the guards lane. Offline, no cluster.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  failures=0
  expect_fail() { # <name> <command...>: the assertion must refuse
    local name="$1"; shift
    if "$@" 2>/dev/null; then
      failures=$((failures + 1)); echo "SELFTEST FAIL: ${name} was accepted; the assertion cannot fail" >&2
    else
      echo "selftest ok: ${name} is refused"
    fi
  }
  expect_pass() { # <name> <command...>: the assertion must accept
    local name="$1"; shift
    if "$@" 2>/dev/null; then
      echo "selftest ok: ${name} is accepted"
    else
      failures=$((failures + 1)); echo "SELFTEST FAIL: ${name} was refused; the assertion is broken" >&2
    fi
  }

  log "login output parsing"
  code="$(printf 'To finish signing in, open:\n  https://app.example/device\nand confirm this code:  BDWD-HQPK\n\nWaiting for approval...\n' | parse_user_code)"
  [ "$code" = "BDWD-HQPK" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: parsed code '${code}', want BDWD-HQPK" >&2; }
  code="$(printf 'login: fetch bootstrap: 502\n' | parse_user_code)"
  [ -z "$code" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: a login error yielded a code '${code}'" >&2; }
  echo "selftest ok: the user code is parsed and an error yields none"

  log "enroll output parsing"
  tok="$(printf 'principal_id:  p-1\nbootstrap_token: tok.abc.def\ngibson_url:    https://api.example\n' | parse_bootstrap_token)"
  [ "$tok" = "tok.abc.def" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: parsed token '${tok}'" >&2; }
  tok="$(printf 'principal_id:  p-1\n' | parse_bootstrap_token)"
  [ -z "$tok" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: an enroll with no token yielded '${tok}'" >&2; }
  echo "selftest ok: the bootstrap token is parsed and its absence yields none"

  log "JWT subject"
  hdr="$(printf '{"alg":"RS256"}' | base64 -w0 | tr -d '=')"
  body="$(printf '{"sub":"123456","iat":1}' | base64 -w0 | tr -d '=')"
  sub="$(jwt_sub "${hdr}.${body}.sig")"
  [ "$sub" = "123456" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: jwt_sub gave '${sub}'" >&2; }
  sub="$(jwt_sub "opaque-token-with-no-dots")"
  [ -z "$sub" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: an opaque token yielded a subject" >&2; }
  echo "selftest ok: the subject comes from a JWT and an opaque token gives none"

  log "agent listing"
  now=1700000000
  fresh='{"agents":[{"name":"demo","health":"healthy","lastSeen":"1699999990"}]}'
  expect_pass "a healthy, fresh agent" assert_agent_listed "$fresh" demo "$now" 120
  expect_fail "an absent agent" assert_agent_listed "$fresh" other "$now" 120
  expect_fail "an unhealthy agent" assert_agent_listed '{"agents":[{"name":"demo","health":"unhealthy","lastSeen":"1699999990"}]}' demo "$now" 120
  expect_fail "a stale heartbeat" assert_agent_listed '{"agents":[{"name":"demo","health":"healthy","lastSeen":"1699990000"}]}' demo "$now" 120
  expect_fail "an empty list" assert_agent_listed '{}' demo "$now" 120

  log "finding listing"
  expect_pass "the finding by id" assert_finding_listed '{"findings":[{"id":"f-1","name":"Demo"}]}' f-1
  expect_fail "a missing finding" assert_finding_listed '{"findings":[{"id":"f-2","name":"Other"}]}' f-1
  expect_fail "an empty graph answer" assert_finding_listed '{"findings":[]}' f-1

  log "identity attribution"
  ids='{"identities":[{"name":"demo","createdBySubject":"123456","revoked":false}]}'
  expect_pass "the identity names the person" assert_identity_created_by "$ids" demo 123456
  expect_fail "another person" assert_identity_created_by "$ids" demo 999
  expect_fail "a revoked identity" assert_identity_created_by '{"identities":[{"name":"demo","createdBySubject":"123456","revoked":true}]}' demo 123456

  log "completion record"
  expect_pass "a text log record" assert_completion_logged 'time=1 level=INFO msg="complete: LLM completion succeeded" tenant=t slot=primary model_used=m' primary
  expect_pass "a JSON log record" assert_completion_logged '{"msg":"complete: LLM completion succeeded","slot":"primary"}' primary
  expect_fail "another slot" assert_completion_logged 'msg="complete: LLM completion succeeded" slot=other' primary
  expect_fail "a failed completion" assert_completion_logged 'msg="complete: LLM completion failed" slot=primary' primary
  expect_fail "no record at all" assert_completion_logged '' primary

  log "finding names the agent"
  expect_pass "a finding stamped with the agent" assert_finding_names_agent '{"readBack":{"agent_name":"demo"}}' demo
  expect_fail "a finding stamped with another agent" assert_finding_names_agent '{"readBack":{"agent_name":"other"}}' demo
  expect_fail "a finding with no submitter" assert_finding_names_agent '{"readBack":{"agent_name":null}}' demo

  log "phase selection"
  [ "$(phase_steps enroll)" = "1 2 3 4 5 7" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: the enroll phase does not run steps 1 to 5 and 7" >&2; }
  [ "$(phase_steps completion)" = "1 2 3 6" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: the completion phase does not run steps 1 to 3 and 6" >&2; }
  [ "$(phase_steps gitlab)" = "1 2 3 8 9 10 12 13 11" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: the gitlab phase does not run steps 1 to 3, 8 to 10, 12, 13 and 11" >&2; }
  [ -z "$(phase_steps nonsense)" ] || { failures=$((failures + 1)); echo "SELFTEST FAIL: an unknown phase runs steps" >&2; }
  echo "selftest ok: each phase names its steps and an unknown phase names none"

  log "GitLab connector assertions"
  expect_pass "an OAuth grant by the admin" assert_oauth_grant '{"state":"CONNECTOR_AUTH_STATE_AUTHORIZED","authorizedBy":"user:123","scope":"mcp"}' 123
  expect_fail "a grant by another person" assert_oauth_grant '{"state":"CONNECTOR_AUTH_STATE_AUTHORIZED","authorizedBy":"user:999","scope":"mcp"}' 123
  expect_fail "a grant without the mcp scope" assert_oauth_grant '{"state":"CONNECTOR_AUTH_STATE_AUTHORIZED","authorizedBy":"user:123","scope":"read_api"}' 123
  expect_fail "no grant where one is expected" assert_oauth_grant '{"state":"CONNECTOR_AUTH_STATE_UNAUTHORIZED"}' 123
  expect_pass "no grant after revoke" assert_no_grant '{"state":"CONNECTOR_AUTH_STATE_UNAUTHORIZED"}'
  expect_fail "a grant that survived revoke" assert_no_grant '{"state":"CONNECTOR_AUTH_STATE_AUTHORIZED","authorizedBy":"user:123"}'
  expect_pass "a Ready connector with tools" assert_connector_ready '{"connectors":[{"id":"gitlab","phase":"Ready","discoveredTools":12}]}' gitlab
  expect_fail "a connector waiting for authorization" assert_connector_ready '{"connectors":[{"id":"gitlab","phase":"AuthorizationRequired","discoveredTools":0}]}' gitlab
  expect_fail "a Ready connector with no tools" assert_connector_ready '{"connectors":[{"id":"gitlab","phase":"Ready","discoveredTools":0}]}' gitlab
  expect_fail "an absent connector" assert_connector_ready '{"connectors":[]}' gitlab
  expect_pass "a call whose output names the project" assert_call_answered '{"ok":true,"output":"{\"path_with_namespace\":\"grp/proj\"}"}' grp/proj
  expect_fail "a call naming another project" assert_call_answered '{"ok":true,"output":"other/thing"}' grp/proj
  expect_fail "a refused call where an answer is expected" assert_call_answered '{"ok":false,"refused":true}' grp/proj
  expect_pass "a refused call after revoke" assert_call_refused '{"ok":false,"refused":true,"error":"permission_denied"}'
  expect_fail "a call that still answers after revoke" assert_call_refused '{"ok":true,"output":"grp/proj"}'
  expect_fail "a probe that died for another reason" assert_call_refused '{"ok":false,"error":"connect failed"}'
  ev='{"events":[{"eventType":"connector.tool.call","actorId":"agent_principal:1","actorSource":"agent","targetObject":"connector:gitlab","details":{"tool":"mcp:gitlab:get_project","work_id":"w-1","mission_id":"m-0001abcd"}}]}'
  expect_pass "a connector tool call record of the agent" assert_audit_names_agent "$ev" agent_principal:1 gitlab
  expect_fail "a record of another actor" assert_audit_names_agent '{"events":[{"eventType":"connector.tool.call","actorId":"user:9","actorSource":"user","targetObject":"connector:gitlab"}]}' agent_principal:1 gitlab
  expect_fail "another action" assert_audit_names_agent '{"events":[{"eventType":"connector.enabled","actorId":"agent_principal:1","actorSource":"agent","targetObject":"connector:gitlab"}]}' agent_principal:1 gitlab
  expect_fail "another connector" assert_audit_names_agent "$ev" agent_principal:1 github
  expect_fail "the old target field name" assert_audit_names_agent '{"events":[{"eventType":"connector.tool.call","actorId":"agent_principal:1","actorSource":"agent","targetResource":"component:connector/gitlab"}]}' agent_principal:1 gitlab
  expect_fail "an empty audit trail" assert_audit_names_agent '{"events":[]}' agent_principal:1 gitlab
  expect_pass "a record with the mission id, tool and work id" assert_audit_names_mission "$ev" agent_principal:1 gitlab m-0001abcd
  expect_fail "a record of another mission" assert_audit_names_mission "$ev" agent_principal:1 gitlab m-9999zzzz
  expect_fail "a record with no mission id (a call with no claimed work id)" assert_audit_names_mission '{"events":[{"eventType":"connector.tool.call","actorId":"agent_principal:1","actorSource":"agent","targetObject":"connector:gitlab","details":{"tool":"t"}}]}' agent_principal:1 gitlab m-0001abcd
  expect_fail "a record with a mission id and no work id" assert_audit_names_mission '{"events":[{"eventType":"connector.tool.call","actorId":"agent_principal:1","actorSource":"agent","targetObject":"connector:gitlab","details":{"tool":"t","mission_id":"m-0001abcd"}}]}' agent_principal:1 gitlab m-0001abcd
  expect_fail "the camel case key of the mission id" assert_audit_names_mission '{"events":[{"eventType":"connector.tool.call","actorId":"agent_principal:1","actorSource":"agent","targetObject":"connector:gitlab","details":{"tool":"t","work_id":"w","missionId":"m-0001abcd"}}]}' agent_principal:1 gitlab m-0001abcd
  expect_fail "an empty expected mission id" assert_audit_names_mission "$ev" agent_principal:1 gitlab ""
  expect_pass "a mission id" assert_mission_id 0198f0c2-aaaa-7bbb-8ccc-123456789abc
  expect_fail "an empty mission id" assert_mission_id ""
  expect_fail "an error line as a mission id" assert_mission_id "Error: no target"

  log "OpenBao returns on its own"
  expect_pass "a new pod that is unsealed" assert_bao_returned uid-1 uid-2 unsealed
  expect_fail "the same pod (nothing was deleted)" assert_bao_returned uid-1 uid-1 unsealed
  expect_fail "a new pod that is sealed" assert_bao_returned uid-1 uid-2 sealed
  expect_fail "a new pod with an unknown state" assert_bao_returned uid-1 uid-2 unknown
  expect_fail "no new pod yet" assert_bao_returned uid-1 "" unsealed

  log "host key kept"
  expect_pass "the same key" assert_host_key_kept abc abc
  expect_fail "a rewritten key" assert_host_key_kept abc def
  expect_fail "no key" assert_host_key_kept "" ""

  log "in-image probe selftest"
  command -v node >/dev/null || die "node is required for the selftest"
  node "${SCRIPT_DIR}/agent-probe.mjs" --selftest || failures=$((failures + 1))

  if [ "$failures" -gt 0 ]; then
    echo "selftest: ${failures} assertion(s) cannot fail correctly" >&2
    exit 1
  fi
  log "selftest passed: every assertion can fail"
  exit 0
fi

# ---------------------------------------------------------------------------
# Live mode: preconditions
# ---------------------------------------------------------------------------
log "preconditions (phase ${PHASE})"
[ -n "$(phase_steps "$PHASE")" ] || die "unknown phase '${PHASE}': want enroll | completion | all"
for tool in kubectl docker curl jq buf sha256sum node openssl; do
  command -v "$tool" >/dev/null || die "${tool} not on PATH"
done
command -v "$GIBSON_BIN" >/dev/null || die "the adk CLI is not on PATH (GIBSON_BIN=${GIBSON_BIN})"
[ -n "${AGENT_IMAGE:-}" ] || die "AGENT_IMAGE is required: the zerocool-agent image, pinned by digest"
case "$AGENT_IMAGE" in
  *@sha256:*) ;;
  *) die "AGENT_IMAGE must be pinned by digest, got ${AGENT_IMAGE}" ;;
esac
kubectl -n "$NS" get pods --no-headers >/dev/null || die "kubectl cannot reach namespace ${NS}"

WORK="${WORK_DIR:-$(mktemp -d)}"
# The adk CLI stores its session at ~/.gibson/auth/credentials and has no
# path flag, so HOME moves into the work dir. kubectl and docker read their
# config from HOME too: pin both to the runner's files BEFORE the move, or
# every kubectl call after this line answers as if there were no cluster
# (run 35625719878 died on "the gibson-domains ConfigMap names none").
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker}"
[ -r "$KUBECONFIG" ] || die "no kubeconfig at ${KUBECONFIG}"
# Playwright finds its browsers under HOME unless PLAYWRIGHT_BROWSERS_PATH is
# set. Keep the real browser cache before HOME moves to the temp dir.
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/.cache/ms-playwright}"
export HOME="${WORK}/home"
mkdir -p "$HOME"
kubectl -n "$NS" get configmap gibson-domains >/dev/null || die "kubectl lost the cluster after HOME moved to ${HOME}"
RUN_ID="${RUN_ID:-$(date +%s | tail -c 6)$(openssl rand -hex 2)}"
AGENT_NAME="${AGENT_NAME:-zerocool-demo-${RUN_ID}}"
STATE="${WORK}/state"
mkdir -p "$STATE"
# The image runs as uid 65532 and writes its host key into this bind mount.
chmod 0777 "$STATE"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../scripts/lib/port-forward-loop.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/port-forward-loop.sh"
CONTAINERS=()
cleanup() {
  for c in "${CONTAINERS[@]:-}"; do
    if [ -n "$c" ]; then docker rm -f "$c" >/dev/null 2>&1 || true; fi
  done
  pf_stop_all
}
trap cleanup EXIT

# The customer edge, the way an operator finds it.
if [ -z "${DOMAIN:-}" ]; then
  DOMAIN="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.domain}' 2>/dev/null || true)"
fi
[ -n "${DOMAIN:-}" ] || die "no DOMAIN and the gibson-domains ConfigMap names none"
APP_HOST="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.appHost}' 2>/dev/null || true)"
[ -n "$APP_HOST" ] || APP_HOST="app.${DOMAIN}"
API_HOST="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.apiHost}' 2>/dev/null || true)"
[ -n "$API_HOST" ] || API_HOST="api.${DOMAIN}"
if [ -z "${EDGE_IP:-}" ]; then
  EDGE_IP="$(kubectl -n "$NS" get svc "$ENVOY_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
fi
[ -n "${EDGE_IP:-}" ] || die "the ${ENVOY_SVC} Service has no LoadBalancer address. cloud-provider-kind did not give it one"
echo "edge: ${API_HOST} and ${APP_HOST} -> ${EDGE_IP}"

# The adk CLI and buf dial the hosts by name. The workflow maps them in
# /etc/hosts; this checks the map is there instead of guessing at it.
for h in "$API_HOST" "$APP_HOST"; do
  resolved="$(getent hosts "$h" | awk '{print $1}' | head -1 || true)"
  [ "$resolved" = "$EDGE_IP" ] || die "${h} resolves to '${resolved:-<nothing>}', want ${EDGE_IP}. Add '${EDGE_IP} ${API_HOST} ${APP_HOST}' to /etc/hosts"
done

# The edge CA. The baseline profile ships a self-signed edge, and every
# credential below travels over it, so the CA is pinned rather than skipped.
EDGE_CA="${WORK}/edge-ca.crt"
kubectl -n "$NS" get secret gibson-envoy-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$EDGE_CA" || true
if [ ! -s "$EDGE_CA" ]; then
  kubectl -n "$NS" get secret gibson-envoy-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$EDGE_CA" || true
fi
[ -s "$EDGE_CA" ] || die "cannot read the edge CA from Secret gibson-envoy-tls in ns/${NS}"
export GIBSON_CA_CERT="$EDGE_CA"
cp "$EDGE_CA" "${STATE}/edge-ca.crt"
chmod 0644 "${STATE}/edge-ca.crt"

log "waiting for the edge to answer"
edge=000
for _ in $(seq 1 60); do
  edge="$(curl -sS --cacert "$EDGE_CA" -o /dev/null -w '%{http_code}' "https://${API_HOST}/.well-known/gibson-login" || true)"
  [ "$edge" = "200" ] && break
  sleep 5
done
[ "$edge" = "200" ] || die "https://${API_HOST}/.well-known/gibson-login never answered 200 (last: ${edge}). The CLI cannot learn its issuer"

# The seeded first admin (ADR-0093, hosted#202): no password is ever
# generated or stored. The first-admin Job creates the Owner with no
# password and writes a one-time offline setup link to the Secret named
# below (this profile ships no mail transport). This test completes that
# setup itself — sets a password, enrolls TOTP — through the same
# Playwright/TOTP driver the Platform owner exit test uses
# (test/platform-owner/driver.mjs), never a second one.
FIRST_TENANT_OWNER_EMAIL="${FIRST_TENANT_OWNER_EMAIL:-admin@localhost.zeroroot.ai}"
FIRST_TENANT_OWNER_SETUP_SECRET="${FIRST_TENANT_OWNER_SETUP_SECRET:-gibson-first-tenant-owner-setup}"

log "step 0: complete the first tenant Owner's setup link (set password, enroll TOTP)"
SETUP_LINK=""
for _ in $(seq 1 30); do
  SETUP_LINK="$(kubectl -n "$NS" get secret "$FIRST_TENANT_OWNER_SETUP_SECRET" -o jsonpath='{.data.setup-link}' 2>/dev/null | base64 -d || true)"
  [ -n "$SETUP_LINK" ] && break
  sleep 5
done
[ -n "$SETUP_LINK" ] || die "Secret ${FIRST_TENANT_OWNER_SETUP_SECRET} has no setup-link — the first-admin Job did not complete"
case "$SETUP_LINK" in
  https://*) ;;
  *) die "the setup link '${SETUP_LINK}' does not start with https:// — it must name the platform's public host, never the in-cluster Zitadel Service (gibson#254 class of bug)" ;;
esac

ADMIN_USER="$FIRST_TENANT_OWNER_EMAIL"
# Generated here, never by gibson: the test is the one party that needs a
# known password afterward, to drive step 1's Zitadel session API the same
# way the login page does.
ADMIN_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9')Aa1!"
TOTP_FILE="${WORK}/owner-totp-secret"

PLATFORM_OWNER_PASSWORD="$ADMIN_PASS" SETUP_LINK="$SETUP_LINK" \
  LANDING_ORIGIN="https://${APP_HOST}" TOTP_SECRET_OUT="$TOTP_FILE" \
  DIAG_DIR="${DIAG_DIR:-}" \
  node "${SCRIPT_DIR}/../platform-owner/driver.mjs" --drill
echo "first admin: ${ADMIN_USER} (setup link completed, no password stored anywhere but this run)"

# The daemon under test, for its log and its version.
DAEMON_STS="$(kubectl -n "$NS" get sts -l app.kubernetes.io/component=daemon -o name | head -1)"
[ -n "$DAEMON_STS" ] || die "no StatefulSet with app.kubernetes.io/component=daemon in ${NS}"

# grpc_call <schema> <Service/Method> <json body>: one RPC through the api
# edge as the enrolling person. buf curl encodes the body from the schema.
# No x-gibson-tenant header: a person's tenant comes only from their token
# (ADR-0093 decision 4), and ext-authz refuses the header for a user.
HUMAN_TOKEN=""
TENANT=""
#
# stdout is the answer and nothing else. buf writes warnings about the schema
# workspace to stderr on each call, and a caller that read `2>&1` got them in
# front of the JSON, so jq read a good answer as a refusal (run 38202412416,
# step 6). The stderr of a call that succeeds is dropped; the stderr of a call
# that fails is printed, so a caller still sees the reason.
grpc_call() {
  local rc=0
  buf curl --schema "$1" --protocol grpc --cacert "$EDGE_CA" --timeout 60s \
    -H @<(printf 'authorization: Bearer %s\n' "${HUMAN_TOKEN}") \
    -d "$3" "https://${API_HOST}/$2" 2>"${WORK}/grpc-call.err" || rc=$?
  [ "$rc" -eq 0 ] || cat "${WORK}/grpc-call.err" >&2
  return "$rc"
}

# grpc_call_file <schema> <Service/Method> <json body file>: the same call
# with the body read from a file (mode 0600). A credential never goes on a
# command line.
grpc_call_file() {
  local rc=0
  buf curl --schema "$1" --protocol grpc --cacert "$EDGE_CA" --timeout 60s \
    -H @<(printf 'authorization: Bearer %s\n' "${HUMAN_TOKEN}") \
    -d "@$3" "https://${API_HOST}/$2" 2>"${WORK}/grpc-call.err" || rc=$?
  [ "$rc" -eq 0 ] || cat "${WORK}/grpc-call.err" >&2
  return "$rc"
}

diag() { # <label> <text>: keep a failure artifact
  [ -n "${DIAG_DIR:-}" ] || return 0
  mkdir -p "$DIAG_DIR"
  printf '%s\n' "$2" > "${DIAG_DIR}/$1.txt"
}

# tenant_schema: the daemon-local protos (ProviderService, ConnectorService,
# ConnectorAuthService, TenantService) are not in the published SDK module.
# The schema is the daemon-local tree plus the SDK module as a dependency.
# Built once, on first use, into SCHEMA_DIR.
SCHEMA_DIR="${WORK}/tenant-schema"
tenant_schema() {
  [ -f "${SCHEMA_DIR}/buf.lock" ] && return 0
  mkdir -p "${SCHEMA_DIR}/proto"
  cp -r "${GIBSON_SRC}/internal/server/daemon/api/gibson" "${SCHEMA_DIR}/proto/"
  cat > "${SCHEMA_DIR}/buf.yaml" <<EOF
version: v2
modules:
  - path: proto
deps:
  - ${SDK_SCHEMA}
EOF
  (cd "$SCHEMA_DIR" && buf dep update >/dev/null)
}

# fga_tuples <label> <tuple_key json>: the OpenFGA tuples a denial hangs on,
# read from the cluster's own store. Run 35638725251 denied RegisterComponent
# for a freshly enrolled agent, and the log named no reason. The model
# (gibson internal/platform/authz/model.fga) makes can_poll_work on
# component:_system depend on direct_execute by the principal AND
# tenant_enabled by the tenant, so both sets are dumped, not guessed at.
FGA_PF_STARTED=""
FGA_LOCAL_PORT="${FGA_LOCAL_PORT:-18081}"
fga_tuples() {
  local label="$1" key="$2" store ca out fga_key
  store="$(kubectl -n "$NS" get configmap gibson-fga-config -o jsonpath='{.data.store_id}' 2>/dev/null || true)"
  if [ -z "$store" ]; then echo "fga: no store_id in gibson-fga-config" >&2; return 0; fi
  ca="${WORK}/fga-ca.crt"
  kubectl -n "$NS" get secret gibson-openfga-http-tls -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$ca" || true
  if [ -z "$FGA_PF_STARTED" ]; then
    pf_loop "$NS" "svc/${RELEASE}-openfga" "${FGA_LOCAL_PORT}:8080"
    FGA_PF_STARTED=yes
    sleep 3
  fi
  # OpenFGA requires the preshared key (charts#645, hosted#634). The key goes
  # to curl on stdin, never on an argv.
  fga_key="$(kubectl -n "$NS" get secret gibson-openfga-preshared-key -o jsonpath='{.data.key}' 2>/dev/null | base64 -d || true)"
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$fga_key" \
    | curl -sS -K - --max-time 20 --cacert "$ca" -H 'Content-Type: application/json' \
    -d "{\"tuple_key\":${key}}" "https://127.0.0.1:${FGA_LOCAL_PORT}/stores/${store}/read" 2>&1 || true)"
  echo "--- FGA tuples ${label} (${key})"
  jq -c '.tuples[]?.key' <<<"$out" 2>/dev/null || echo "$out"
  diag "fga-${label}" "$out"
}

# ---------------------------------------------------------------------------
# Step 1: gibson login as the seeded first admin
# ---------------------------------------------------------------------------
log "step 1: gibson login (device flow, approved through the login-client credential)"
step_result 1 FAIL

LOGIN_OUT="${WORK}/login.out"
# The file exists before the background login starts: its shell opens the
# file only when it is scheduled, and a read before that ended the script
# under set -e (run 38202412416, "login.out: No such file or directory").
: > "$LOGIN_OUT"
"$GIBSON_BIN" login --gibson-url "https://${API_HOST}" --no-browser --timeout 5m >"$LOGIN_OUT" 2>&1 &
LOGIN_PID=$!

USER_CODE=""
for _ in $(seq 1 60); do
  USER_CODE="$(parse_user_code <"$LOGIN_OUT")"
  [ -n "$USER_CODE" ] && break
  if ! kill -0 "$LOGIN_PID" 2>/dev/null; then break; fi
  sleep 2
done
if [ -z "$USER_CODE" ]; then
  cat "$LOGIN_OUT" >&2
  die "gibson login printed no device code. The CLI could not start the device flow against ${API_HOST}"
fi
echo "device code: ${USER_CODE}"

# Zitadel's own API, reached the way the login page reaches it: the in-cluster
# Service, with the instance selected by the external host name.
pf_loop "$NS" "svc/${ZITADEL_SVC}" "${ZITADEL_LOCAL_PORT}:8080"
ZURL="http://127.0.0.1:${ZITADEL_LOCAL_PORT}"
LOGIN_PAT="$(kubectl -n "$NS" get secret login-client -o jsonpath='{.data.pat}' | base64 -d | tr -d '\r\n')"
[ -n "$LOGIN_PAT" ] || die "Secret login-client in ns/${NS} has no pat. The login page's own credential is missing"
zitadel_api() {
  curl -sS --max-time 30 -H "Host: ${APP_HOST}" -H @<(printf 'Authorization: Bearer %s\n' "${LOGIN_PAT}") \
    -H 'Content-Type: application/json' -H 'Accept: application/json' "$@"
}
for _ in $(seq 1 30); do
  if curl -s -o /dev/null --max-time 5 -H "Host: ${APP_HOST}" "${ZURL}/healthz"; then break; fi
  sleep 2
done

DEVICE_REQ="$(zitadel_api "${ZURL}/v2/oidc/device_authorization/${USER_CODE}" || true)"
DEVICE_ID="$(jq -r '.deviceAuthorizationRequest.id // empty' <<<"$DEVICE_REQ" 2>/dev/null || true)"
if [ -z "$DEVICE_ID" ]; then
  diag step1-device-request "$DEVICE_REQ"
  echo "$DEVICE_REQ" >&2
  die "Zitadel did not resolve device code ${USER_CODE} to a request. The device grant is not usable on this install"
fi

# The password goes to jq in its environment and to curl on stdin (-d @-), never
# as an argument that a process list shows.
SESSION="$(ADMIN_USER="$ADMIN_USER" ADMIN_PASS="$ADMIN_PASS" \
  jq -n '{checks:{user:{loginName:env.ADMIN_USER},password:{password:env.ADMIN_PASS}}}' \
  | zitadel_api -X POST "${ZURL}/v2/sessions" -d @- || true)"
SESSION_ID="$(jq -r '.sessionId // empty' <<<"$SESSION" 2>/dev/null || true)"
SESSION_TOKEN="$(jq -r '.sessionToken // empty' <<<"$SESSION" 2>/dev/null || true)"
if [ -z "$SESSION_ID" ] || [ -z "$SESSION_TOKEN" ]; then
  diag step1-session "$(jq -c 'del(.sessionToken)' <<<"$SESSION" 2>/dev/null || echo "$SESSION")"
  jq -c 'del(.sessionToken)' <<<"$SESSION" 2>/dev/null >&2 || echo "$SESSION" >&2
  die "Zitadel refused a password session for ${ADMIN_USER}. The seeded first-admin credential does not sign in"
fi

# The session token goes in the body on stdin: jq reads it from its
# environment, and curl reads the body with -d @- (drill sweep row 28).
APPROVE_CODE="$(TOK="$SESSION_TOKEN" jq -n --arg id "$SESSION_ID" '{session:{sessionId:$id,sessionToken:env.TOK}}' \
  | zitadel_api -o "${WORK}/approve.out" -w '%{http_code}' -X POST \
      "${ZURL}/v2/oidc/device_authorization/${DEVICE_ID}" -d @- || true)"
if [ "$APPROVE_CODE" != "200" ]; then
  diag step1-approve "$(cat "${WORK}/approve.out")"
  cat "${WORK}/approve.out" >&2
  die "Zitadel refused the device approval (HTTP ${APPROVE_CODE:-<none>})"
fi
echo "device request ${DEVICE_ID} approved by ${ADMIN_USER}"

LOGIN_RC=0
wait "$LOGIN_PID" || LOGIN_RC=$?
cat "$LOGIN_OUT"
[ "$LOGIN_RC" -eq 0 ] || die "gibson login exited ${LOGIN_RC} after the approval"

CREDS="${HOME}/.gibson/auth/credentials"
[ -s "$CREDS" ] || die "gibson login wrote no session at ${CREDS}"
HUMAN_TOKEN="$(jq -r '.access_token // empty' "$CREDS")"
TENANT="$(jq -r '.active_tenant // empty' "$CREDS")"
HUMAN_SUB="$(jwt_sub "$HUMAN_TOKEN")"
[ -n "$HUMAN_TOKEN" ] || die "the stored session has no access token"
[ -n "$TENANT" ] || die "gibson login pinned no active tenant. ListMyMemberships did not answer for the first admin"
[ -n "$HUMAN_SUB" ] || die "the access token is not a JWT with a subject. The api edge accepts only JWTs"
pass "step 1: logged in as ${ADMIN_USER} (subject ${HUMAN_SUB}), active tenant ${TENANT}"
step_result 1 PASS

# ---------------------------------------------------------------------------
# Step 2: gibson agent enroll
# ---------------------------------------------------------------------------
log "step 2: gibson agent enroll --name ${AGENT_NAME}"
step_result 2 FAIL
ENROLL_OUT="$("$GIBSON_BIN" agent enroll --name "$AGENT_NAME" --kind agent \
  --description "zerocool-plugins#10 demo, run ${RUN_ID}" 2>&1)" || {
  echo "$ENROLL_OUT" >&2
  die "gibson agent enroll failed"
}
sed -E 's/^(bootstrap_token:).*/\1 <redacted>/' <<<"$ENROLL_OUT"
BOOTSTRAP_TOKEN="$(parse_bootstrap_token <<<"$ENROLL_OUT")"
[ -n "$BOOTSTRAP_TOKEN" ] || die "gibson agent enroll printed no bootstrap_token"
PRINCIPAL_ID="$(sed -n -E 's/^principal_id:[[:space:]]+([^[:space:]]+).*$/\1/p' <<<"$ENROLL_OUT" | head -1)"
pass "step 2: a one-time bootstrap token was minted"
step_result 2 PASS

# ---------------------------------------------------------------------------
# Step 3: first start with the token
# ---------------------------------------------------------------------------
log "step 3: first start of ${AGENT_IMAGE} with GIBSON_BOOTSTRAP_TOKEN"
step_result 3 FAIL
docker pull -q "$AGENT_IMAGE" >/dev/null || die "cannot pull ${AGENT_IMAGE}"

ENV_BASE="${WORK}/agent.env"
umask 077
cat > "$ENV_BASE" <<EOF
GIBSON_PLATFORM_URL=https://${API_HOST}
GIBSON_HOST_KEY_PATH=/tmp/zerocool/host.key
NODE_EXTRA_CA_CERTS=/tmp/zerocool/edge-ca.crt
ZEROCOOL_AGENT_NAME=${AGENT_NAME}
ZEROCOOL_WORKSPACE=/tmp/zerocool/workspace
HOME=/tmp/zerocool
EOF
ENV_FIRST="${WORK}/agent-first.env"
{ cat "$ENV_BASE"; echo "GIBSON_BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}"; } > "$ENV_FIRST"
umask 022

# start_agent <container name> <env file>: the image as shipped, on the kind
# Docker network so the edge address is routable, with the api host mapped.
start_agent() {
  docker run -d --name "$1" --network kind --add-host "${API_HOST}:${EDGE_IP}" \
    --env-file "$2" -v "${STATE}:/tmp/zerocool" "$AGENT_IMAGE" >/dev/null
  CONTAINERS+=("$1")
}
# wait_registered <container name>: the agent's own log says it registered.
wait_registered() {
  for _ in $(seq 1 90); do
    if docker logs "$1" 2>&1 | grep -q "registered agent \"${AGENT_NAME}\""; then return 0; fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" != "true" ]; then break; fi
    sleep 2
  done
  return 1
}

C1="zerocool-demo-first-${RUN_ID}"
start_agent "$C1" "$ENV_FIRST"
if ! wait_registered "$C1"; then
  diag step3-first-start "$(docker logs "$C1" 2>&1)"
  docker logs "$C1" 2>&1 | tail -40 >&2
  fga_tuples system-backplane '{"object":"component:_system"}'
  fga_tuples principal "{\"user\":\"${PRINCIPAL_ID}\",\"object\":\"component:\"}"
  kubectl get agentenrollments.gibson.zeroroot.ai,tenantgrants.gibson.zeroroot.ai -A -o wide 2>&1 | tail -20 >&2 || true
  die "the first start did not register within 180 s. The capability-grant handshake failed"
fi
docker logs "$C1" 2>&1 | tail -5
# The image writes the key as uid 65532 with mode 0600, so the runner user
# cannot read it (run 35649274635: "sha256sum: Permission denied"). Hash it
# as the image does, inside the image, on a read-only mount.
host_key_sha() {
  docker run --rm -v "${STATE}:/tmp/zerocool:ro" --entrypoint sha256sum "$AGENT_IMAGE" /tmp/zerocool/host.key 2>/dev/null | cut -d' ' -f1
}
HOST_KEY_SHA="$(host_key_sha || true)"
[ -n "$HOST_KEY_SHA" ] || die "the first start registered but wrote no host key at ${STATE}/host.key"
docker rm -f "$C1" >/dev/null
rm -f "$ENV_FIRST"
pass "step 3: first start completed the handshake and persisted a host key (sha256 ${HOST_KEY_SHA:0:12})"
step_result 3 PASS

# ---------------------------------------------------------------------------
# Step 4: second start, no token, no person
if runs_step 4; then
# ---------------------------------------------------------------------------
log "step 4: second start with no token"
step_result 4 FAIL
C2="zerocool-demo-second-${RUN_ID}"
start_agent "$C2" "$ENV_BASE"
if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$C2" | grep -q '^GIBSON_BOOTSTRAP_TOKEN='; then
  die "the second start carries GIBSON_BOOTSTRAP_TOKEN. This step must run with no token"
fi
if ! wait_registered "$C2"; then
  diag step4-second-start "$(docker logs "$C2" 2>&1)"
  docker logs "$C2" 2>&1 | tail -40 >&2
  die "the second start did not register on the persisted host key"
fi
docker logs "$C2" 2>&1 | tail -3
HOST_KEY_SHA_2="$(host_key_sha || true)"
assert_host_key_kept "$HOST_KEY_SHA" "$HOST_KEY_SHA_2" \
  || die "the host key changed between starts (${HOST_KEY_SHA:0:12} -> ${HOST_KEY_SHA_2:0:12}). The second start did not re-register on the persisted key"
pass "step 4: the second start registered on the persisted host key with no token"
step_result 4 PASS
fi

# ---------------------------------------------------------------------------
# Step 5: the daemon lists the agent, healthy, heartbeating
if runs_step 5; then
# ---------------------------------------------------------------------------
log "step 5: DaemonService.ListAgents lists ${AGENT_NAME} with a fresh heartbeat"
step_result 5 FAIL
LISTED=""
AGENTS_JSON="{}"
for _ in $(seq 1 24); do
  AGENTS_JSON="$(grpc_call "$SDK_SCHEMA" gibson.daemon.v1.DaemonService/ListAgents '{}' 2>"${WORK}/list-agents.err" || true)"
  if assert_agent_listed "$AGENTS_JSON" "$AGENT_NAME" "$(date +%s)" 120; then LISTED=yes; break; fi
  sleep 5
done
if [ -z "$LISTED" ]; then
  diag step5-list-agents "$(printf '%s\n--- stderr\n%s\n' "$AGENTS_JSON" "$(cat "${WORK}/list-agents.err")")"
  cat "${WORK}/list-agents.err" >&2
  jq -c '.agents[]? | {name, health, lastSeen}' <<<"$AGENTS_JSON" 2>/dev/null >&2 || echo "$AGENTS_JSON" >&2
  fga_tuples system-backplane '{"object":"component:_system"}'
  fail "step 5: the daemon does not list ${AGENT_NAME} as healthy with a heartbeat in the last 120 s"
else
  jq -c --arg n "$AGENT_NAME" '.agents[] | select(.name == $n) | {id, name, kind, health, lastSeen}' <<<"$AGENTS_JSON"
  pass "step 5: the daemon lists ${AGENT_NAME} as healthy with a fresh heartbeat"
  step_result 5 PASS
fi
docker rm -f "$C2" >/dev/null
fi

# run_probe <mode> <env...>: one unattended start of the same image on the
# persisted host key, running test/demo/agent-probe.mjs instead of the agent
# loop. It prints one JSON line on stdout.
run_probe() {
  local mode="$1"; shift
  docker run --rm --network kind --add-host "${API_HOST}:${EDGE_IP}" \
    --env-file "$ENV_BASE" "$@" \
    -v "${STATE}:/tmp/zerocool" \
    -v "${SCRIPT_DIR}/agent-probe.mjs:/app/probe.mjs:ro" \
    --entrypoint node "$AGENT_IMAGE" /app/probe.mjs "$mode"
}

# bao_seal_state: "unsealed", "sealed", or "unknown", from the seal status
# that the openbao-auto-init sidecar reads over TLS (the same read as
# test/rotation/exit-test-rotation.sh).
BAO_POD="${RELEASE}-openbao-0"
bao_seal_state() {
  local st
  st="$(kubectl -n "$NS" exec "$BAO_POD" -c openbao-auto-init -- \
        sh -c 'curl -sS https://127.0.0.1:8200/v1/sys/seal-status' 2>/dev/null || true)"
  case "$st" in
    *'"initialized":true'*'"sealed":false'*) echo unsealed ;;
    *'"initialized":true'*'"sealed":true'*) echo sealed ;;
    *) echo unknown ;;
  esac
}

# mission_call <label>: one GitLab tool call by the enrolled agent, INSIDE a
# mission. A person (the admin session of step 1) submits a mission whose one
# agent node names the enrolled agent. The probe is that agent: it polls for
# the dispatch, claims it, and calls the tool with the work id of the item, so
# the harness scopes the call to the mission. Prints the probe's JSON line,
# and sets MISSION_ID to the id that `gibson mission submit --detach` printed.
MISSION_WAIT_SECONDS="${MISSION_WAIT_SECONDS:-300}"
TARGET_ID=""
MISSION_ID=""
MISSION_LINE=""
mission_call() {
  local label="$1" out err cname spid deadline
  out="${WORK}/mission-${label}.out"; err="${WORK}/mission-${label}.err"
  cname="probe-mission-${label}-${RUN_ID}"
  MISSION_ID=""
  if [ -z "$TARGET_ID" ]; then
    TARGET_ID="$("$GIBSON_BIN" target create --name "demo-gitlab-${RUN_ID}" --type custom \
      --url "${GITLAB_INSTANCE_URL}/${DEMO_GITLAB_PROJECT}" 2>"${WORK}/target.err" | tail -1)"
    assert_mission_id "$TARGET_ID" || { MISSION_LINE="{\"ok\":false,\"error\":\"gibson target create gave no target id: $(tr -d '"\n' < "${WORK}/target.err" | head -c 200)\"}"; TARGET_ID=""; return 0; }
  fi
  jq -n --arg n "demo-gitlab-${label}-${RUN_ID}" --arg a "$AGENT_NAME" --arg p "$DEMO_GITLAB_PROJECT" '{
    name: $n, description: "The demo: the enrolled agent calls the GitLab connector inside a mission.",
    version: "1.0.0",
    nodes: {call: {id: "call", type: "NODE_TYPE_AGENT",
      agentConfig: {agentName: $a, task: {goal: ("Call get_project of the GitLab connector for " + $p + " and report its path.")}}}},
    entryPoints: ["call"], exitPoints: ["call"]}' > "${WORK}/mission-${label}.json"
  : > "$out"; : > "$err"
  run_probe mission-gitlab --name "$cname" -e "PROBE_GITLAB_PROJECT=${DEMO_GITLAB_PROJECT}" \
    -e "PROBE_MISSION_WAIT_MS=$(( MISSION_WAIT_SECONDS * 1000 ))" >"$out" 2>"$err" &
  spid=$!
  deadline=$(( $(date +%s) + 120 ))
  until grep -q 'worker ready' "$err" 2>/dev/null; do
    if ! kill -0 "$spid" 2>/dev/null || [ "$(date +%s)" -ge "$deadline" ]; then
      docker rm -f "$cname" >/dev/null 2>&1 || true
      MISSION_LINE="{\"ok\":false,\"error\":\"the probe never started its agent worker: $(tail -3 "$err" | tr -d '"\n' | head -c 300)\"}"; return 0
    fi
    sleep 2
  done
  MISSION_ID="$("$GIBSON_BIN" mission submit --detach --format json --target "$TARGET_ID" "${WORK}/mission-${label}.json" 2>"${WORK}/mission-${label}.submit.err" | tail -1)"
  if ! assert_mission_id "$MISSION_ID"; then
    docker rm -f "$cname" >/dev/null 2>&1 || true
    MISSION_LINE="{\"ok\":false,\"error\":\"gibson mission submit gave no mission id: $(tr -d '"\n' < "${WORK}/mission-${label}.submit.err" | head -c 300)\"}"
    MISSION_ID=""; return 0
  fi
  deadline=$(( $(date +%s) + MISSION_WAIT_SECONDS + 60 ))
  while kill -0 "$spid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then docker rm -f "$cname" >/dev/null 2>&1 || true; break; fi
    sleep 3
  done
  wait "$spid" 2>/dev/null || true
  tail -20 "$err" >&2
  MISSION_LINE="$(tail -1 "$out")"
  [ -n "$MISSION_LINE" ] || MISSION_LINE='{"ok":false,"error":"the probe printed no result"}'
}

# ---------------------------------------------------------------------------
# Step 7: a finding, attributed, and a read of the tenant graph
if runs_step 7; then
# ---------------------------------------------------------------------------
log "step 7: the agent submits a finding and reads the tenant graph"
step_result 7 FAIL
FINDING_TITLE="Enrollment demo finding ${RUN_ID}"
PROBE_OUT="$(run_probe finding -e "PROBE_FINDING_TITLE=${FINDING_TITLE}" 2>"${WORK}/probe-finding.err" || true)"
tail -20 "${WORK}/probe-finding.err"
PROBE_LINE="$(echo "$PROBE_OUT" | tail -1)"
echo "$PROBE_LINE"
FINDING_ID="$(jq -r '.submitted // empty' <<<"$PROBE_LINE" 2>/dev/null || true)"
if ! jq -e --arg t "$FINDING_TITLE" '.ok == true and (.submitted | length) > 0 and .readBack.id == .submitted and .readBack.title == $t' <<<"$PROBE_LINE" >/dev/null 2>&1; then
  diag step7-probe "$(printf '%s\n--- stderr\n%s\n' "$PROBE_OUT" "$(cat "${WORK}/probe-finding.err")")"
  fail "step 7: the agent did not submit a finding and read it back from the tenant graph"
else
  echo "the agent read finding ${FINDING_ID} back from the tenant graph"
  GRAPH_JSON="$(grpc_call "$SDK_SCHEMA" gibson.graph.v1.GraphService/GetFindings "$(jq -n --arg s "$FINDING_TITLE" '{search:$s,page_size:50}')" 2>"${WORK}/graph.err" || true)"
  IDS_JSON="$(grpc_call "$SDK_SCHEMA" gibson.agentidentity.v1.AgentIdentityService/ListAgentIdentities '{}' 2>"${WORK}/identities.err" || true)"
  ok=yes
  if ! assert_finding_listed "$GRAPH_JSON" "$FINDING_TITLE" && ! assert_finding_listed "$GRAPH_JSON" "$FINDING_ID"; then
    diag step7-graph "$(printf '%s\n--- stderr\n%s\n' "$GRAPH_JSON" "$(cat "${WORK}/graph.err")")"
    cat "${WORK}/graph.err" >&2
    fail "step 7: the person's view of the tenant graph (GraphService.GetFindings) does not list the finding"
    ok=""
  fi
  if ! assert_finding_names_agent "$PROBE_LINE" "$AGENT_NAME"; then
    fail "step 7: the stored finding does not name ${AGENT_NAME} as its submitter (agent_name=$(jq -r '.readBack.agent_name' <<<"$PROBE_LINE")). The daemon records no submitting principal on a mission-less finding, so a reader cannot tell which agent raised it"
    ok=""
  fi
  if ! assert_identity_created_by "$IDS_JSON" "$AGENT_NAME" "$HUMAN_SUB"; then
    diag step7-identities "$(printf '%s\n--- stderr\n%s\n' "$IDS_JSON" "$(cat "${WORK}/identities.err")")"
    cat "${WORK}/identities.err" >&2
    jq -c '.identities[]? | {name, createdBySubject, revoked}' <<<"$IDS_JSON" 2>/dev/null >&2 || true
    fail "step 7: the agent identity ${AGENT_NAME} is not attributed to the enrolling person ${HUMAN_SUB}"
    ok=""
  fi
  if [ -n "$ok" ]; then
    jq -c --arg k "$FINDING_TITLE" '.findings[] | select(.name == $k) | {id, name, severity, type}' <<<"$GRAPH_JSON" | head -1
    jq -c --arg n "$AGENT_NAME" '.identities[] | select(.name == $n) | {principalId, name, createdBySubject}' <<<"$IDS_JSON" | head -1
    pass "step 7: the finding is attributed to ${AGENT_NAME}, and ${AGENT_NAME} is attributed to ${ADMIN_USER} (${HUMAN_SUB})"
    step_result 7 PASS
  fi
fi
fi

# ---------------------------------------------------------------------------
# Step 6: a completion through the shim, recorded by the daemon
if runs_step 6; then
# ---------------------------------------------------------------------------
log "step 6: a completion through the SDK shim on slot ${SLOT}"
step_result 6 FAIL
# Ask Anthropic about the key before the platform sees it (hosted#659). A
# 401 from the daemon alone cannot tell a revoked key (an owner item) from a
# platform that sends a different value (a defect). The key goes in a 0600
# header file, never on a command line. Only the HTTP status is kept.
KEY_STATUS=""
if [ -n "${EXIT_TEST_ANTHROPIC_API_KEY:-}" ]; then
  KEY_HDR="${WORK}/anthropic-key.hdr"
  ( umask 077; printf 'x-api-key: %s\nanthropic-version: 2023-06-01\n' "$EXIT_TEST_ANTHROPIC_API_KEY" > "$KEY_HDR" )
  KEY_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -H @"$KEY_HDR" https://api.anthropic.com/v1/models 2>/dev/null || true)"
  rm -f "$KEY_HDR"
  echo "step 6: Anthropic answers HTTP ${KEY_STATUS:-none} to the key in EXIT_TEST_ANTHROPIC_API_KEY"
fi
if [ -z "${EXIT_TEST_ANTHROPIC_API_KEY:-}" ]; then
  fail "step 6: EXIT_TEST_ANTHROPIC_API_KEY is empty. The baseline profile ships no model slot, so the completion needs a provider key in this repository's Actions secrets (hosted#123)"
elif [ "$KEY_STATUS" = 401 ] || [ "$KEY_STATUS" = 403 ]; then
  fail "step 6: Anthropic refuses the key in EXIT_TEST_ANTHROPIC_API_KEY with HTTP ${KEY_STATUS}, before the platform uses it. The key is revoked or wrong. An owner sets a valid key in this repository's Actions secrets (hosted#659)"
elif [ -z "${GIBSON_SRC:-}" ] || [ ! -f "${GIBSON_SRC}/internal/server/daemon/api/gibson/tenant/v1/provider.proto" ]; then
  fail "step 6: GIBSON_SRC does not hold internal/server/daemon/api/gibson/tenant/v1/provider.proto. The tenant ProviderService proto is daemon-local, so a gibson checkout is required"
else
  tenant_schema || die "buf dep update failed for the tenant schema"

  PROVIDER_NAME="demo-anthropic"
  # The body holds the provider key, so it goes in a 0600 file, never on a
  # command line (grpc_call_file).
  CREATE_BODY="${WORK}/create-provider.json"
  # jq reads the key from its environment (env.K), not from an argument.
  ( umask 077; K="$EXIT_TEST_ANTHROPIC_API_KEY" jq -n --arg n "$PROVIDER_NAME" \
    '{input:{name:$n,type:"anthropic",default_model:"claude-haiku-4-5",credentials:{api_key:env.K},set_as_default:true,capabilities:["CAPABILITY_CHAT"]}}' > "$CREATE_BODY" )
  CREATE_OUT="$(grpc_call_file "$SCHEMA_DIR" gibson.tenant.v1.ProviderService/CreateProvider "$CREATE_BODY" 2>&1 || true)"
  rm -f "$CREATE_BODY"
  if ! jq -e '.provider.name' <<<"$CREATE_OUT" >/dev/null 2>&1 && ! grep -q -i 'already exists' <<<"$CREATE_OUT"; then
    diag step6-create-provider "$CREATE_OUT"
    echo "$CREATE_OUT" >&2
    fail "step 6: ProviderService.CreateProvider refused the anthropic provider"
  else
    echo "provider ${PROVIDER_NAME} registered as the tenant default"
    T0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    PROBE_OUT="$(run_probe complete -e "PROBE_SLOT=${SLOT}" 2>"${WORK}/probe-complete.err" || true)"
    tail -20 "${WORK}/probe-complete.err"
    echo "$PROBE_OUT" | tail -1
    if ! jq -e '.ok == true and (.content | length) > 0' <<<"$(echo "$PROBE_OUT" | tail -1)" >/dev/null 2>&1; then
      diag step6-probe "$(printf '%s\n--- stderr\n%s\n' "$PROBE_OUT" "$(cat "${WORK}/probe-complete.err")")"
      fail "step 6: the shim did not return a completion"
    else
      sleep 5
      DAEMON_LOG="$(kubectl -n "$NS" logs "$DAEMON_STS" -c gibson --since-time="$T0" 2>/dev/null || true)"
      if assert_completion_logged "$DAEMON_LOG" "$SLOT"; then
        grep -F 'complete: LLM completion succeeded' <<<"$DAEMON_LOG" | tail -1
        pass "step 6: the completion went through the shim and the daemon recorded it on slot ${SLOT}"
        step_result 6 PASS
      else
        diag step6-daemon-log "$DAEMON_LOG"
        fail "step 6: the shim answered but the daemon wrote no completion record for slot ${SLOT} since ${T0}"
      fi
    fi
  fi
fi
fi

# ---------------------------------------------------------------------------
# Step 8: the admin enables the GitLab connector on the owner's token
# ---------------------------------------------------------------------------
if runs_step 8; then
log "step 8: EnableConnector gitlab and authorize it with OAuth as ${ADMIN_USER}"
step_result 8 FAIL
CONNECTOR="gitlab"
GITLAB_INSTANCE_URL="${GITLAB_INSTANCE_URL:-https://gitlab.com}"
AUTH_WAIT_SECONDS="${AUTH_WAIT_SECONDS:-900}"
[ -n "${DEMO_GITLAB_PROJECT:-}" ] || die "DEMO_GITLAB_PROJECT is empty. The GitLab steps need the project, group/project"
if [ -z "${GIBSON_SRC:-}" ] || [ ! -f "${GIBSON_SRC}/internal/server/daemon/api/gibson/tenant/v1/connector.proto" ]; then
  die "GIBSON_SRC does not hold internal/server/daemon/api/gibson/tenant/v1/connector.proto. The tenant ConnectorService proto is daemon-local, so a gibson checkout is required"
fi
tenant_schema || die "buf dep update failed for the tenant schema"

ENABLE_OUT="$(grpc_call "$SCHEMA_DIR" gibson.tenant.v1.ConnectorService/EnableConnector "$(jq -n --arg id "$CONNECTOR" '{catalog_id:$id}')" 2>&1 || true)"
if ! jq -e '.connector' <<<"$ENABLE_OUT" >/dev/null 2>&1 && ! grep -q -i -E 'already|exists' <<<"$ENABLE_OUT"; then
  diag step8-enable "$ENABLE_OUT"
  echo "$ENABLE_OUT" >&2
  die "ConnectorService.EnableConnector refused ${CONNECTOR}"
fi
echo "connector ${CONNECTOR} enabled: $(jq -c '{connector, phase}' <<<"$ENABLE_OUT" 2>/dev/null || echo 'already enabled')"

# GitLab refuses a personal access token on /api/v4/mcp (HTTP 403, run
# 37355956639), so the grant is OAuth (manifest auth: oauth). The daemon runs
# the discovery, the client registration and PKCE, and returns the vendor
# authorize URL. The consent is the one step a person does: open the URL and
# grant access. The vendor redirects to the daemon callback, which stores the
# grant and proves that it refreshes.
START_OUT="$(grpc_call "$SCHEMA_DIR" gibson.tenant.v1.ConnectorAuthService/StartConnectorAuthorization "$(jq -n --arg c "$CONNECTOR" --arg u "$GITLAB_INSTANCE_URL" '{connector:$c,instance_url:$u}')" 2>&1 || true)"
AUTHORIZE_URL="$(jq -r '.authorizeUrl // empty' <<<"$START_OUT" 2>/dev/null || true)"
if [ -z "$AUTHORIZE_URL" ]; then
  diag step8-start "$START_OUT"
  echo "$START_OUT" >&2
  die "ConnectorAuthService.StartConnectorAuthorization returned no authorize URL for ${CONNECTOR} at ${GITLAB_INSTANCE_URL}"
fi
echo
echo "A PERSON MUST NOW OPEN THIS URL, SIGN IN TO GITLAB AND GRANT ACCESS:"
echo "  ${AUTHORIZE_URL}"
echo "The script waits up to ${AUTH_WAIT_SECONDS} s for the grant."
echo

STATUS_JSON="{}"
GRANTED=""
for _ in $(seq 1 $(( AUTH_WAIT_SECONDS / 10 ))); do
  STATUS_JSON="$(grpc_call "$SCHEMA_DIR" gibson.tenant.v1.ConnectorAuthService/GetConnectorAuthStatus "$(jq -n --arg c "$CONNECTOR" '{connector:$c}')" 2>&1 || true)"
  if assert_oauth_grant "$STATUS_JSON" "$HUMAN_SUB"; then GRANTED=yes; break; fi
  sleep 10
done
jq -c '{state, authorizedBy, scope, lastRefreshError}' <<<"$STATUS_JSON" 2>/dev/null || echo "$STATUS_JSON"
[ -n "$GRANTED" ] || die "GetConnectorAuthStatus does not report an OAuth grant with the mcp scope authorized by user:${HUMAN_SUB} after ${AUTH_WAIT_SECONDS} s"

# The daemon materializes the credential for the proxy on its refresh pass
# (every 5 minutes), and the connector-operator turns the instance Ready once
# the MCP server serves and its tools are registered. Bounded at 12 minutes.
READY=""
CONNECTORS_JSON="{}"
for _ in $(seq 1 72); do
  CONNECTORS_JSON="$(grpc_call "$SCHEMA_DIR" gibson.tenant.v1.ConnectorService/ListConnectors '{}' 2>"${WORK}/list-connectors.err" || true)"
  if assert_connector_ready "$CONNECTORS_JSON" "$CONNECTOR"; then READY=yes; break; fi
  sleep 10
done
if [ -z "$READY" ]; then
  diag step8-connectors "$(printf '%s\n--- stderr\n%s\n' "$CONNECTORS_JSON" "$(cat "${WORK}/list-connectors.err")")"
  jq -c '.connectors[]? | {id, phase, discoveredTools, lastError}' <<<"$CONNECTORS_JSON" 2>/dev/null >&2 || echo "$CONNECTORS_JSON" >&2
  kubectl get connectorinstances.gibson.zeroroot.ai -A -o wide 2>&1 | tail -5 >&2 || true
  die "connector ${CONNECTOR} did not reach Ready with discovered tools within 12 minutes"
fi
jq -c --arg id "$CONNECTOR" '.connectors[] | select(.id == $id) | {id, shape, phase, discoveredTools}' <<<"$CONNECTORS_JSON"
pass "step 8: ${CONNECTOR} is enabled on an OAuth grant by ${ADMIN_USER} and reached Ready"
step_result 8 PASS
fi

# ---------------------------------------------------------------------------
# Step 9: the agent calls one read-only GitLab tool, inside a mission
# ---------------------------------------------------------------------------
if runs_step 9; then
log "step 9: a mission sends the agent to call a tool of the connector against ${DEMO_GITLAB_PROJECT}"
step_result 9 FAIL
mission_call first
GL_LINE="$MISSION_LINE"
MISSION_ID_9="$MISSION_ID"
echo "$GL_LINE"
if [ -n "$MISSION_ID_9" ] && assert_call_answered "$GL_LINE" "$DEMO_GITLAB_PROJECT"; then
  pass "step 9: mission ${MISSION_ID_9}: $(jq -r '.tool' <<<"$GL_LINE") answered and named ${DEMO_GITLAB_PROJECT}"
  step_result 9 PASS
else
  diag step9-probe "$(printf '%s\n--- stderr\n%s\n' "$GL_LINE" "$(cat "${WORK}/mission-first.err" 2>/dev/null)")"
  fail "step 9: the agent's GitLab tool call in a mission did not answer with ${DEMO_GITLAB_PROJECT} (mission id: ${MISSION_ID_9:-none})"
fi
fi

# ---------------------------------------------------------------------------
# Step 10: the trail resolves the call to the agent, the mission and the person
# ---------------------------------------------------------------------------
if runs_step 10; then
log "step 10: the audit trail names the agent and the mission of step 9 on the connector, and the identity names the person"
step_result 10 FAIL
AUDIT_JSON="{}"
NAMED=""
for _ in $(seq 1 12); do
  AUDIT_JSON="$(grpc_call "$SCHEMA_DIR" gibson.tenant.v1.TenantService/ListAuditEvents "$(jq -n --arg t "$TENANT" --arg c "$CONNECTOR" '{tenant_id:$t,event_types:["connector.tool.call"],target_match:$c,page_size:100}')" 2>"${WORK}/audit.err" || true)"
  if assert_audit_names_mission "$AUDIT_JSON" "$PRINCIPAL_ID" "$CONNECTOR" "${MISSION_ID_9:-}"; then NAMED=yes; break; fi
  sleep 5
done
IDS_JSON="$(grpc_call "$SDK_SCHEMA" gibson.agentidentity.v1.AgentIdentityService/ListAgentIdentities '{}' 2>"${WORK}/identities.err" || true)"
ok=yes
if [ -z "$NAMED" ]; then
  diag step10-audit "$(printf '%s\n--- stderr\n%s\n' "$AUDIT_JSON" "$(cat "${WORK}/audit.err")")"
  jq -c '.events[]? | {eventType, actorSource, actorId, targetObject, details}' <<<"$AUDIT_JSON" 2>/dev/null | head -20 >&2 || echo "$AUDIT_JSON" >&2
  fail "step 10: no audit event records ${PRINCIPAL_ID} as the actor of a call on ${CONNECTOR} with mission ${MISSION_ID_9:-none}. The trail does not show the agent and the mission"
  ok=""
fi
if ! assert_identity_created_by "$IDS_JSON" "$AGENT_NAME" "$HUMAN_SUB"; then
  fail "step 10: the agent identity ${AGENT_NAME} is not attributed to the enrolling person ${HUMAN_SUB}"
  ok=""
fi
if [ -n "$ok" ]; then
  jq -c --arg a "$PRINCIPAL_ID" '.events[] | select(.actorId == $a) | {eventType, actorSource, actorId, targetObject, details, timestamp}' <<<"$AUDIT_JSON" | head -1
  pass "step 10: the call shows ${PRINCIPAL_ID} and mission ${MISSION_ID_9}, and ${AGENT_NAME} resolves to ${ADMIN_USER} (${HUMAN_SUB})"
  step_result 10 PASS
fi
fi

# ---------------------------------------------------------------------------
# Step 12: the OpenBao pod is deleted, and it returns unsealed on its own
# ---------------------------------------------------------------------------
if runs_step 12; then
log "step 12: delete the OpenBao pod ${BAO_POD}, and wait for it to return unsealed with no hand step"
step_result 12 FAIL
BAO_RETURN_WAIT="${BAO_RETURN_WAIT:-300}"
OLD_UID="$(kubectl -n "$NS" get pod "$BAO_POD" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
[ -n "$OLD_UID" ] || die "step 12: no pod ${BAO_POD} in ${NS}, so there is nothing to delete"
# The one change this test makes to the cluster: it deletes the pod of its own
# install, as a crash would. Nothing unseals it, restarts it or patches it
# afterwards. The static seal opens the new pod from the keyring.
kubectl -n "$NS" delete pod "$BAO_POD" --wait=true --timeout=120s >/dev/null \
  || die "step 12: the pod ${BAO_POD} did not delete"
NEW_UID=""; STATE_NOW="unknown"
deadline=$(( $(date +%s) + BAO_RETURN_WAIT ))
T_KILL="$(date +%s)"
while [ "$(date +%s)" -lt "$deadline" ]; do
  NEW_UID="$(kubectl -n "$NS" get pod "$BAO_POD" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  if [ -n "$NEW_UID" ] && [ "$NEW_UID" != "$OLD_UID" ]; then
    STATE_NOW="$(bao_seal_state)"
    if assert_bao_returned "$OLD_UID" "$NEW_UID" "$STATE_NOW"; then break; fi
  fi
  sleep 5
done
if assert_bao_returned "$OLD_UID" "$NEW_UID" "$STATE_NOW"; then
  pass "step 12: ${BAO_POD} returned unsealed $(( $(date +%s) - T_KILL )) s after the delete, with no hand step"
  step_result 12 PASS
else
  diag step12-openbao "$(kubectl -n "$NS" get pod "$BAO_POD" -o wide 2>&1; kubectl -n "$NS" logs "$BAO_POD" -c openbao --tail=40 2>&1)"
  fail "step 12: ${BAO_POD} is not back unsealed ${BAO_RETURN_WAIT} s after the delete (new pod uid '${NEW_UID:-none}', seal state ${STATE_NOW})"
fi
fi

# ---------------------------------------------------------------------------
# Step 13: the next connector call, in a new mission, works
# ---------------------------------------------------------------------------
if runs_step 13; then
log "step 13: the next GitLab call by the agent, in a new mission, answers after OpenBao returned"
step_result 13 FAIL
# The call goes through the daemon, the connector proxy and the secret store.
# A few tries bound a daemon that is still reconnecting to OpenBao, and the
# number of tries is part of the record.
TRIES=0; GL3_LINE=""
for TRIES in 1 2 3; do
  mission_call "next${TRIES}"
  GL3_LINE="$MISSION_LINE"
  echo "$GL3_LINE"
  if [ -n "$MISSION_ID" ] && assert_call_answered "$GL3_LINE" "$DEMO_GITLAB_PROJECT"; then break; fi
  sleep 30
done
if [ -n "$MISSION_ID" ] && assert_call_answered "$GL3_LINE" "$DEMO_GITLAB_PROJECT"; then
  pass "step 13: mission ${MISSION_ID} answered on try ${TRIES} after the OpenBao pod was deleted"
  step_result 13 PASS
else
  diag step13-probe "$GL3_LINE"
  fail "step 13: no GitLab call in a mission answered in ${TRIES} tries after the OpenBao pod was deleted"
fi
fi

# ---------------------------------------------------------------------------
# Step 11: the admin revokes the grant, and the next call is refused
# ---------------------------------------------------------------------------
if runs_step 11; then
log "step 11: RevokeConnectorGrant ${CONNECTOR}, then the agent calls again"
step_result 11 FAIL
REVOKE_OUT="$(grpc_call "$SCHEMA_DIR" gibson.tenant.v1.ConnectorAuthService/RevokeConnectorGrant "$(jq -n --arg c "$CONNECTOR" '{connector:$c}')" 2>&1 || true)"
echo "$REVOKE_OUT"
jq -e '.hadGrant == true' <<<"$REVOKE_OUT" >/dev/null 2>&1 || die "RevokeConnectorGrant did not report a grant to revoke"
STATUS_JSON="$(grpc_call "$SCHEMA_DIR" gibson.tenant.v1.ConnectorAuthService/GetConnectorAuthStatus "$(jq -n --arg c "$CONNECTOR" '{connector:$c}')" 2>&1 || true)"
assert_no_grant "$STATUS_JSON" || die "GetConnectorAuthStatus still reports a grant after the revoke: $(jq -c . <<<"$STATUS_JSON" 2>/dev/null || echo "$STATUS_JSON")"
echo "status after revoke: $(jq -c '{state}' <<<"$STATUS_JSON")"

# The proxy's credential is withdrawn on the daemon's next refresh pass and
# the operator rechecks every 2 minutes, so the refusal is measured with a
# bound, and the time it took is part of the record.
REFUSED=""
T_REVOKE="$(date +%s)"
GL2_LINE=""
GL2_OUT=""
until [ "$(date +%s)" -ge $(( T_REVOKE + 450 )) ]; do
  MISSION_WAIT_SECONDS=90 mission_call "revoked"
  GL2_LINE="$MISSION_LINE"
  GL2_OUT="$GL2_LINE"
  if assert_call_refused "$GL2_LINE"; then REFUSED=yes; break; fi
  sleep 10
done
echo "$GL2_LINE"
if [ -z "$REFUSED" ]; then
  diag step11-probe "$(printf '%s\n--- stderr\n%s\n' "$GL2_OUT" "$(cat "${WORK}/mission-revoked.err" 2>/dev/null)")"
  fail "step 11: the agent's call still answers $(( $(date +%s) - T_REVOKE )) s after the revoke"
else
  pass "step 11: the call was refused $(( $(date +%s) - T_REVOKE )) s after the revoke, and the status reports no grant"
  step_result 11 PASS
fi
fi

# ---------------------------------------------------------------------------
# Summary. The demo script in docs/demo/enrollment.md is derived from this.
# ---------------------------------------------------------------------------
log "summary (run ${RUN_ID}, agent ${AGENT_NAME}, tenant ${TENANT})"
SUMMARY=""
for i in 1 2 3 4 5 6 7 8 9 10 12 13 11; do
  if runs_step "$i"; then r="${STEP_RESULT[$i]:-NOT RUN}"; else r="OUTSIDE PHASE ${PHASE}"; fi
  printf '  step %s: %s\n' "$i" "$r"
  SUMMARY="${SUMMARY}| ${i} | ${r} |"$'\n'
done
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### enrollment drill, phase %s (run %s, agent %s, tenant %s)\n\n| step | result |\n|---|---|\n%s' "$PHASE" "$RUN_ID" "$AGENT_NAME" "$TENANT" "$SUMMARY"
  } >> "$GITHUB_STEP_SUMMARY"
fi
if [ "$FAILED" -gt 0 ]; then
  die "${FAILED} step(s) failed"
fi
log "EXIT TEST PASSED (phase ${PHASE}): ${ADMIN_USER} enrolled ${AGENT_NAME} once, and it ran with no person"
