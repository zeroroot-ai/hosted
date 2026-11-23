# shellcheck shell=bash
# ---------------------------------------------------------------------------
# workload-diag.sh (library) — print why the workloads of a namespace are not
# healthy, when a promotion does not land.
#
#   workload_diag <namespace>
#
# Argo CD 3 keeps the health of each resource in the resource tree, not in the
# Application status. So a Degraded app names no resource in the document that
# check-promotion-landed.sh reads (promote-staging run 45101003946). This reads
# the workloads themselves and prints:
#   - each Deployment, StatefulSet and DaemonSet that is not ready, with the
#     message of its conditions that are not True
#   - each pod that is not Running and Ready, with the reason and message of
#     each container that waits or ended
#   - the last Warning events of the namespace
#
# hosted is public, and so is each run log: this prints status and events
# only, never a container log, an env value or a spec.
# A diagnostic never changes an exit path: each command ends in `|| true`.
# ---------------------------------------------------------------------------

# workload_diag_workloads reads `kubectl get deploy,statefulset,daemonset -o json`.
workload_diag_workloads() {
  jq -r '
    .items[]?
    | (.status // {}) as $s
    | (.spec.replicas // $s.desiredNumberScheduled // 1) as $want
    | ($s.readyReplicas // $s.numberReady // 0) as $ready
    | select($ready < $want)
    | "\(.kind)/\(.metadata.name) ready \($ready)/\($want)"
      + ([ $s.conditions[]? | select(.status != "True")
           | " | \(.type): \(.reason // "") \(.message // "")" ] | join(""))'
}

# workload_diag_pods reads `kubectl get pods -o json`.
workload_diag_pods() {
  jq -r '
    .items[]?
    | select(.status.phase != "Succeeded")
    | select(.status.phase != "Running"
             or ([.status.containerStatuses[]? | select(.ready != true)] | length) > 0)
    | "Pod/\(.metadata.name) \(.status.phase)"
      + ([ (.status.initContainerStatuses // [])[], (.status.containerStatuses // [])[]
           | select(.ready != true)
           | " | \(.name): "
             + (if .state.waiting then "waiting \(.state.waiting.reason // "") \(.state.waiting.message // "")"
                elif .state.terminated then "ended \(.state.terminated.reason // "") exit \(.state.terminated.exitCode // "")"
                else "not ready" end)
             + (if .lastState.terminated then " (last: \(.lastState.terminated.reason // "") exit \(.lastState.terminated.exitCode // ""))" else "" end)
             + " restarts \(.restartCount // 0)" ] | join(""))'
}

# workload_diag_events reads `kubectl get events -o json` and prints the last
# WORKLOAD_DIAG_EVENTS (25) Warning events.
workload_diag_events() {
  jq -r --argjson n "${WORKLOAD_DIAG_EVENTS:-25}" '
    [ .items[]? | select(.type == "Warning") ]
    | sort_by(.lastTimestamp // .eventTime // "")
    | .[-$n:][]
    | "\(.involvedObject.kind)/\(.involvedObject.name) \(.reason // ""): \(.message // "")"'
}

workload_diag() {
  local ns="$1"
  echo "▶ [diag] workloads of ${ns} that are not ready:"
  kubectl -n "$ns" get deploy,statefulset,daemonset -o json 2>/dev/null | workload_diag_workloads | sed 's/^/    /' || true
  echo "▶ [diag] pods of ${ns} that are not Running and Ready:"
  kubectl -n "$ns" get pods -o json 2>/dev/null | workload_diag_pods | sed 's/^/    /' || true
  echo "▶ [diag] last Warning events of ${ns}:"
  kubectl -n "$ns" get events -o json 2>/dev/null | workload_diag_events | sed 's/^/    /' || true
}
