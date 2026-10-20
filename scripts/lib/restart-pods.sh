#!/usr/bin/env bash
# restart-pods.sh: restart a workload by deleting its pods, one at a time.
#
#   restart_pods <namespace> <kind/name> <timeout-seconds>
#
# WHY NOT `kubectl rollout restart`. The chart binds the ValidatingAdmissionPolicy
# gibson-platform-identity-workloads to the release namespace. It admits a
# CREATE or UPDATE of a workload whose pod template claims platform identity
# (the daemon, ext-authz, ratelimit, the operators, the dashboard, envoy,
# OpenBao) only from the controllers of the release (Argo CD) and a restart by
# the Reloader ServiceAccount. A `rollout restart` patches the workload, so the
# policy denies it (drill run 39125128505, hosted#775, charts#725). A pod
# delete is not a write of the workload: the controller of the workload makes
# the new pod, and the policy does not apply.
#
# The pods go one at a time, and each replacement must be Ready before the
# next delete, so a workload with more than one replica keeps serving. A KNOWN
# COST: a workload with one replica is down until its new pod is Ready. A
# rollout restart of a one-replica Deployment surged a new pod first, so this
# adds a short gap (ext-authz: Envoy cannot authorize a call in it). The
# daemon StatefulSet had the gap with a rollout restart too.
#
# The new pods are told apart from the old ones by UID, not by a clock, so a
# runner clock ahead of the node clock does no harm.
#
# Kinds: Deployment, StatefulSet (.spec.replicas) and DaemonSet
# (.status.desiredNumberScheduled). A workload that wants 0 pods has nothing
# to restart, and the call returns 0, as `rollout restart` did.
#
# Returns 0 when the workload has its pods again, each new and Ready, and 1
# with a reason on stderr at the timeout. Requires kubectl and jq.
#
# RESTART_PODS_RESULT tells the two returns of 0 apart. It is "restarted" when
# each pod was replaced, and "nothing" when the workload wants 0 pods. A caller
# that needs a real restart (an exit test) refuses "nothing". A caller that
# prints a line says which one happened (hosted#12).
RESTART_PODS_RESULT=""

restart_pods() {
  local ns="$1" w="$2" timeout="$3" obj sel want pods old deadline pod left n k
  RESTART_PODS_RESULT=""
  obj="$(kubectl -n "$ns" get "$w" -o json)" \
    || { echo "restart_pods: cannot read ${ns}/${w}" >&2; return 1; }
  sel="$(jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$obj")"
  [ -n "$sel" ] || { echo "restart_pods: ${ns}/${w} has no selector" >&2; return 1; }
  want="$(jq -r 'if .kind == "DaemonSet" then .status.desiredNumberScheduled else .spec.replicas end // empty' <<<"$obj")"
  [[ "$want" =~ ^[0-9]+$ ]] || { echo "restart_pods: ${ns}/${w} has no wanted pod count" >&2; return 1; }
  if [ "$want" -eq 0 ]; then
    echo "restart_pods: ${ns}/${w} wants 0 pods, so there is nothing to restart" >&2
    RESTART_PODS_RESULT=nothing
    return 0
  fi
  # One read gives the pods to delete and their UIDs. Only the live pods: an
  # evicted pod or a pod that is being deleted gets no replacement.
  pods="$(kubectl -n "$ns" get pods -l "$sel" -o json)" \
    || { echo "restart_pods: cannot list the pods of ${ns}/${w}" >&2; return 1; }
  old="$(jq -c "${_restart_pods_live} | map(.metadata.uid)" <<<"$pods")"
  deadline=$(( $(date +%s) + timeout ))
  n=0
  for pod in $(jq -r "${_restart_pods_live}[] | .metadata.name" <<<"$pods"); do
    left=$(( deadline - $(date +%s) )); [ "$left" -gt 0 ] || left=1
    kubectl -n "$ns" delete pod "$pod" --ignore-not-found --wait=true --timeout="${left}s" >/dev/null \
      || { echo "restart_pods: cannot delete pod ${ns}/${pod}" >&2; return 1; }
    # After the Nth delete, N new pods are Ready (at most WANT: a surge can
    # list more pods than the workload wants).
    n=$(( n + 1 )); k=$(( n < want ? n : want ))
    until _restart_pods_new_ready "$ns" "$sel" "$k" "$old"; do
      [ "$(date +%s)" -lt "$deadline" ] || { echo "restart_pods: ${ns}/${w} has not ${k} new Ready pods within ${timeout}s, after the delete of ${pod}" >&2; return 1; }
      sleep "${RESTART_PODS_POLL:-5}"
    done
  done
  until _restart_pods_ready "$ns" "$sel" "$want" "$old"; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "restart_pods: an old pod of ${ns}/${w} still runs, or a new one is not Ready, within ${timeout}s" >&2; return 1; }
    sleep "${RESTART_PODS_POLL:-5}"
  done
  RESTART_PODS_RESULT=restarted
}

# _restart_pods_live: the pods of the list that are not being deleted and
# are not Failed or Succeeded (an evicted pod stays in the list as Failed).
_restart_pods_live='[.items[] | select(.metadata.deletionTimestamp == null)
  | select((.status.phase // "") as $ph | $ph != "Failed" and $ph != "Succeeded")]'
# _restart_pods_is_ready: the pod has the condition Ready True.
_restart_pods_is_ready='([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)'

# _restart_pods_new_ready NS SELECTOR N OLD_UIDS: true when at least N live
# pods are Ready and have no UID of OLD_UIDS (a JSON list). This is the wait
# after the Nth delete. It counts only the new pods, so an old pod that is
# not Ready (a crash loop, an unschedulable pod) does not block it. That old
# pod is deleted later in the loop, as with `rollout restart`.
_restart_pods_new_ready() {
  kubectl -n "$1" get pods -l "$2" -o json | jq -e --argjson n "$3" --argjson old "$4" "
    ${_restart_pods_live} as \$p
    | [\$p[] | select(${_restart_pods_is_ready}) | select((.metadata.uid as \$u | \$old | index(\$u)) == null)]
    | length >= \$n" >/dev/null
}

# _restart_pods_ready NS SELECTOR WANT OLD_UIDS: true when at least WANT live
# pods are Ready, and no live pod has a UID of OLD_UIDS (a JSON list). This
# is the final check, after each old pod is deleted.
_restart_pods_ready() {
  kubectl -n "$1" get pods -l "$2" -o json | jq -e --argjson want "$3" --argjson old "$4" "
    ${_restart_pods_live} as \$p
    | ([\$p[] | select(${_restart_pods_is_ready})] | length) >= \$want
      and all(\$p[]; (.metadata.uid as \$u | \$old | index(\$u)) == null)" >/dev/null
}
