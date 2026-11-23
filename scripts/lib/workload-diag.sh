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
#   - each Deployment, StatefulSet and DaemonSet that is not ready or not fully
#     rolled out, with its conditions that are not True
#   - each pod that is not Running and Ready, with the reason of each container
#     that waits or ended
#   - the last Warning events of the namespace
#
# hosted is public, and so is each run log. This prints no container log, no
# env value, no spec and no Secret or ConfigMap data. A message that a workload
# can fill is either dropped or cut and redacted:
#   - the message of a probe or hook event (exec output, probe URL) and of an
#     External Secrets event (a provider or template error) is dropped: only
#     the reason and the object print
#   - every other message is cut to WORKLOAD_DIAG_MAX (300) characters, and a
#     query value of token, key, secret, password, sig, signature or code, a
#     Bearer value and the user part of a URL are replaced by [redacted]
#   - terminated.message is never printed (FallbackToLogsOnError copies log
#     lines into it)
# tests/harness/workload-diag.bats puts a token into each message source and
# fails if it reaches the output.
#
# A diagnostic never changes an exit path: each command ends in `|| true`, and
# each kubectl read has a request timeout.
# ---------------------------------------------------------------------------

# The jq helpers that every filter shares.
WORKLOAD_DIAG_JQ_DEFS='
  def redact:
    tostring
    | gsub("(?<k>[?&;](token|key|secret|password|sig|signature|code)=)[^&;\" ]*"; "\(.k)[redacted]"; "i")
    | gsub("(?<b>[Bb]earer )[^ \"]*"; "\(.b)[redacted]")
    | gsub("(?<s>://)[^/@ \"]*@"; "\(.s)[redacted]@");
  def safe($max): redact | if length > $max then .[0:$max] + "…" else . end;
'

# workload_diag_workloads reads `kubectl get deploy,statefulset,daemonset -o json`.
workload_diag_workloads() {
  jq -r --argjson max "${WORKLOAD_DIAG_MAX:-300}" "${WORKLOAD_DIAG_JQ_DEFS}"'
    .items[]?
    | (.status // {}) as $s
    | (.spec.replicas // $s.desiredNumberScheduled // 1) as $want
    | ($s.readyReplicas // $s.numberReady // 0) as $ready
    | ($s.updatedReplicas // $s.updatedNumberScheduled // $want) as $updated
    | [ $s.conditions[]? | select(.status != "True") ] as $bad
    | select($ready < $want or $updated < $want or ($bad | length) > 0)
    | "\(.kind)/\(.metadata.name) ready \($ready)/\($want) updated \($updated)/\($want)"
      + ([ $bad[] | " | \(.type): \(.reason // "") \((.message // "") | safe($max))" ] | join(""))'
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
             + (if .state.waiting then "waiting \(.state.waiting.reason // "") \((.state.waiting.message // "") | safe($max))"
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
    def silent:
      (.reason | IN("Unhealthy", "FailedPostStartHook", "FailedPreStopHook", "ProbeWarning"))
      or (.involvedObject.kind | IN("ExternalSecret", "SecretStore", "ClusterSecretStore", "PushSecret"));
    [ .items[]? | select(.type == "Warning") ]
    | sort_by(.series.lastObservedTime // .lastTimestamp // .eventTime // .metadata.creationTimestamp // "")
    | .[-$n:][]
    | "\(.involvedObject.kind)/\(.involvedObject.name) \(.reason // "")"
      + (if silent then " (message not printed)" else ": \((.message // "") | safe($max))" end)'
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
