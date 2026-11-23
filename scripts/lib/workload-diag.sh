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
#   - each Deployment, StatefulSet and DaemonSet that is not ready, not fully
#     rolled out, or has a bad condition
#   - each pod that is not Running and Ready, with the reason of each container
#     that waits or ended, its last exit and its restarts
#   - the last Warning events of the namespace
#
# hosted is public, and so is each run log. This prints no container log, no
# env value, no spec and no Secret or ConfigMap data. A free-text message can
# hold text that a workload wrote (probe and hook output, a runtime error that
# quotes args, a webhook denial that quotes a field), and no pattern can find
# every secret in free text. So a message prints only when Kubernetes writes it
# from a fixed template that holds names, counts and image refs (ALLOWLIST
# below). Every other message prints its reason and its object only.
# tests/harness/workload-diag.bats puts a token into each message source and
# fails if it reaches the output.
#
# A diagnostic never changes an exit path: each command ends in `|| true`, and
# each kubectl read has a request timeout.
# ---------------------------------------------------------------------------

# The events whose message Kubernetes writes from a fixed template: the
# scheduler, the volume controllers, the image manager and the back-off. The
# kubelet writes an image pull failure as reason Failed with the prefix
# "Failed to pull image ". Reason Failed also carries "Error: <start error>",
# which can quote a command and its args, so only that prefix prints. Of the
# admission denials only the fixed quota and PodSecurity forms print.
# FailedMount holds the tail of a volume driver error. The only CSI driver of
# the chart is csi.spiffe.io. A new secrets CSI driver puts provider text there:
# drop FailedMount from the list when one comes.
# shellcheck disable=SC2016 # jq source, expanded by jq and not by the shell
WORKLOAD_DIAG_JQ_DEFS='
  def safe_event:
    (.reason // "") as $r | (.message // "") as $m
    | ($r | IN("FailedScheduling", "FailedMount", "FailedAttachVolume", "FailedMapVolume",
               "BackOff", "FailedKillPod", "InspectFailed", "ErrImageNeverPull"))
      or ($r == "Failed" and ($m | startswith("Failed to pull image ")))
      or ($r == "FailedCreate"
          and ($m | test("^Error creating: pods \"[^\"]*\" is forbidden: (exceeded quota|violates PodSecurity)")));
  def safe_waiting_reason:
    IN("ErrImagePull", "ImagePullBackOff", "CreateContainerConfigError", "InvalidImageName");
  def safe_condition: .type | IN("Available", "Progressing");
  def cut($max): tostring | if length > $max then .[0:$max] + "…" else . end;
'

# workload_diag_workloads reads `kubectl get deploy,statefulset,daemonset -o json`.
workload_diag_workloads() {
  jq -r --argjson max "${WORKLOAD_DIAG_MAX:-300}" "${WORKLOAD_DIAG_JQ_DEFS}"'
    .items[]?
    | (.status // {}) as $s
    | (.spec.replicas // $s.desiredNumberScheduled // 1) as $want
    | ($s.readyReplicas // $s.numberReady // 0) as $ready
    | ($s.updatedReplicas // $s.updatedNumberScheduled // $want) as $updated
    | [ $s.conditions[]? | select((.type == "ReplicaFailure") == (.status == "True")) ] as $bad
    | select($ready < $want or $updated < $want or ($bad | length) > 0)
    | "\(.kind)/\(.metadata.name) ready \($ready)/\($want) updated \($updated)/\($want)"
      + ([ $bad[] | " | \(.type): \(.reason // "")"
                    + (if safe_condition then " \((.message // "") | cut($max))" else "" end) ] | join(""))'
}

# workload_diag_pods reads `kubectl get pods -o json`.
workload_diag_pods() {
  jq -r --argjson max "${WORKLOAD_DIAG_MAX:-300}" "${WORKLOAD_DIAG_JQ_DEFS}"'
    .items[]?
    | select(.status.phase != "Succeeded")
    | select(.status.phase != "Running"
             or ([.status.containerStatuses[]? | select(.ready != true)] | length) > 0)
    | "Pod/\(.metadata.name) \(.status.phase)"
      + (if .status.reason then " \(.status.reason)" else "" end)
      + ([ (.status.initContainerStatuses // [])[], (.status.containerStatuses // [])[]
           | select(.ready != true)
           | " | \(.name): "
             + (if .state.waiting then
                  "waiting \(.state.waiting.reason // "")"
                  + (if (.state.waiting.reason // "" | safe_waiting_reason)
                     then " \((.state.waiting.message // "") | cut($max))" else "" end)
                elif .state.terminated then "ended \(.state.terminated.reason // "") exit \(.state.terminated.exitCode // "")"
                else "not ready" end)
             + (if .lastState.terminated then " (last: \(.lastState.terminated.reason // "") exit \(.lastState.terminated.exitCode // ""))" else "" end)
             + " restarts \(.restartCount // 0)" ] | join(""))'
}

# workload_diag_events reads `kubectl get events -o json` and prints the last
# WORKLOAD_DIAG_EVENTS (25) Warning events.
workload_diag_events() {
  jq -r --argjson n "${WORKLOAD_DIAG_EVENTS:-25}" --argjson max "${WORKLOAD_DIAG_MAX:-300}" \
    "${WORKLOAD_DIAG_JQ_DEFS}"'
    [ .items[]? | select(.type == "Warning") ]
    | sort_by(.series.lastObservedTime // .lastTimestamp // .eventTime // .metadata.creationTimestamp // "")
    | .[-$n:][]
    | "\(.involvedObject.kind)/\(.involvedObject.name) \(.reason // "")"
      + (if safe_event then ": \((.message // "") | cut($max))" else "" end)'
}

workload_diag() {
  local ns="$1" t="--request-timeout=${WORKLOAD_DIAG_TIMEOUT:-20s}"
  echo "▶ [diag] workloads of ${ns} that are not ready:"
  kubectl "$t" -n "$ns" get deploy,statefulset,daemonset -o json 2>/dev/null | workload_diag_workloads | sed 's/^/    /' || true
  echo "▶ [diag] pods of ${ns} that are not Running and Ready:"
  kubectl "$t" -n "$ns" get pods -o json 2>/dev/null | workload_diag_pods | sed 's/^/    /' || true
  echo "▶ [diag] last Warning events of ${ns}:"
  kubectl "$t" -n "$ns" get events -o json 2>/dev/null | workload_diag_events | sed 's/^/    /' || true
}
