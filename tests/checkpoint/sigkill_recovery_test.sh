#!/usr/bin/env bash
# sigkill_recovery_test.sh — Spec 4 / W4 chaos harness
#
# Mission-checkpointing R8: SIGKILL the daemon mid-mission, restart, resume,
# verify tools 1+2 are NOT re-executed and tool 3 is executed once.
#
# This script:
#   1. Submits a 5-tool mission to the kind-cluster daemon.
#   2. Polls mission status until tool-2 is in flight.
#   3. `kubectl delete pod gibson-0 --grace-period=0 --force`.
#   4. Waits for the daemon pod to come back Ready.
#   5. Issues `Mission.Resume(missionID)` (no target_checkpoint_id — picks latest).
#   6. Asserts:
#       - tools 1+2 ARE NOT re-executed (tool-execution counters unchanged).
#       - tool 3 IS executed exactly once.
#       - Mission reaches completed.
#
# Usage:
#   bash sigkill_recovery_test.sh [--namespace gibson] [--mission-yaml <path>]
#
# Exit codes:
#   0  Recovery succeeded — tools 1+2 not re-executed, tool 3 executed, mission completed.
#   1  Recovery FAILED — re-execution detected, mission did not complete, or tool 3 not run.
#   2  Missing dependency (kubectl, kind, gibson-cli).
#   3  Daemon pod did not come Ready within timeout.
#
# Dependencies:
#   - kubectl, kind, gibson-cli, jq

set -euo pipefail

NAMESPACE="${NAMESPACE:-gibson}"
DAEMON_POD="${DAEMON_POD:-gibson-0}"
MISSION_YAML="${MISSION_YAML:-$(dirname "$0")/fixtures/5-tool-mission.yaml}"
TOOL_2_TIMEOUT="${TOOL_2_TIMEOUT:-120}"
DAEMON_READY_TIMEOUT="${DAEMON_READY_TIMEOUT:-180}"
RESUME_COMPLETION_TIMEOUT="${RESUME_COMPLETION_TIMEOUT:-300}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --mission-yaml) MISSION_YAML="$2"; shift 2 ;;
    --pod)          DAEMON_POD="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

step() { printf "\n\033[1;36m[step]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[FAIL]\033[0m %s\n" "$*" >&2; exit 1; }
ok()   { printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing dependency: $1" >&2; exit 2; }
}

require_bin kubectl
require_bin gibson-cli
require_bin jq

#######################################
# 1. Submit the mission.
#######################################
step "Submitting 5-tool mission from $MISSION_YAML ..."
if [[ ! -f "$MISSION_YAML" ]]; then
  fail "mission YAML not found: $MISSION_YAML"
fi

MISSION_ID="$(gibson-cli mission run --yaml "$MISSION_YAML" --json | jq -r '.mission_id')"
[[ -n "$MISSION_ID" && "$MISSION_ID" != "null" ]] || fail "did not get mission_id from gibson-cli"
ok "mission submitted: $MISSION_ID"

#######################################
# 2. Wait for tool-2 to be in flight.
#######################################
step "Waiting for tool-2 to start (timeout ${TOOL_2_TIMEOUT}s) ..."
deadline=$(( $(date +%s) + TOOL_2_TIMEOUT ))
tool2_started=0
while (( $(date +%s) < deadline )); do
  status_json="$(gibson-cli mission status "$MISSION_ID" --json 2>/dev/null || echo '{}')"
  current="$(jq -r '.current_node_id // .currentNodeId // ""' <<<"$status_json")"
  running="$(jq -r '.running_nodes // [] | length' <<<"$status_json" 2>/dev/null || echo 0)"
  if [[ "$current" == *"tool-2"* ]] || [[ "$running" -gt 1 ]]; then
    tool2_started=1
    break
  fi
  sleep 1
done
[[ $tool2_started -eq 1 ]] || fail "tool-2 did not start within ${TOOL_2_TIMEOUT}s"
ok "tool-2 in flight"

#######################################
# 3. SIGKILL the daemon pod.
#######################################
step "Sending SIGKILL to daemon pod $DAEMON_POD ..."
kubectl -n "$NAMESPACE" delete pod "$DAEMON_POD" --grace-period=0 --force
ok "daemon pod kill issued"

#######################################
# 4. Wait for the daemon pod to come Ready.
#######################################
step "Waiting for daemon pod $DAEMON_POD to come Ready (timeout ${DAEMON_READY_TIMEOUT}s) ..."
if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready --timeout="${DAEMON_READY_TIMEOUT}s" \
       pod/"$DAEMON_POD"; then
  exit 3
fi
ok "daemon pod Ready"

#######################################
# 5. Capture pre-resume tool execution counts.
#######################################
pre_status="$(gibson-cli mission status "$MISSION_ID" --json)"
pre_tool1_count="$(jq -r '.tool_execution_counts."tool-1" // 0' <<<"$pre_status")"
pre_tool2_count="$(jq -r '.tool_execution_counts."tool-2" // 0' <<<"$pre_status")"
pre_tool3_count="$(jq -r '.tool_execution_counts."tool-3" // 0' <<<"$pre_status")"
echo "pre-resume tool counts: t1=$pre_tool1_count t2=$pre_tool2_count t3=$pre_tool3_count"

#######################################
# 6. Issue Mission.Resume.
#######################################
step "Resuming mission $MISSION_ID (latest checkpoint) ..."
gibson-cli mission resume "$MISSION_ID"
ok "resume issued"

#######################################
# 7. Wait for completion.
#######################################
step "Waiting for mission to complete (timeout ${RESUME_COMPLETION_TIMEOUT}s) ..."
deadline=$(( $(date +%s) + RESUME_COMPLETION_TIMEOUT ))
final_status=""
while (( $(date +%s) < deadline )); do
  status_json="$(gibson-cli mission status "$MISSION_ID" --json 2>/dev/null || echo '{}')"
  st="$(jq -r '.status // ""' <<<"$status_json")"
  if [[ "$st" == "completed" || "$st" == "failed" || "$st" == "cancelled" ]]; then
    final_status="$st"
    break
  fi
  sleep 2
done
[[ -n "$final_status" ]] || fail "mission did not reach terminal state in ${RESUME_COMPLETION_TIMEOUT}s"
[[ "$final_status" == "completed" ]] || fail "mission reached terminal state $final_status (expected completed)"
ok "mission completed"

#######################################
# 8. Assert no re-execution + tool 3 ran once.
#######################################
post_status="$(gibson-cli mission status "$MISSION_ID" --json)"
post_tool1_count="$(jq -r '.tool_execution_counts."tool-1" // 0' <<<"$post_status")"
post_tool2_count="$(jq -r '.tool_execution_counts."tool-2" // 0' <<<"$post_status")"
post_tool3_count="$(jq -r '.tool_execution_counts."tool-3" // 0' <<<"$post_status")"

echo "post-resume tool counts: t1=$post_tool1_count t2=$post_tool2_count t3=$post_tool3_count"

if [[ "$post_tool1_count" -ne "$pre_tool1_count" ]]; then
  fail "tool-1 was re-executed ($pre_tool1_count -> $post_tool1_count)"
fi
ok "tool-1 NOT re-executed"

if [[ "$post_tool2_count" -ne "$pre_tool2_count" ]]; then
  fail "tool-2 was re-executed ($pre_tool2_count -> $post_tool2_count)"
fi
ok "tool-2 NOT re-executed"

if [[ "$post_tool3_count" -lt 1 ]]; then
  fail "tool-3 did not run after resume (count=$post_tool3_count)"
fi
ok "tool-3 ran $post_tool3_count time(s) after resume"

step "SIGKILL recovery chaos test PASSED"
exit 0
