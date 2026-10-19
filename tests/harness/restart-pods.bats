#!/usr/bin/env bats
#
# restart-pods.bats: a platform workload restarts by a pod delete, never by a
# `rollout restart`, which the identity admission policy of the chart denies
# (drill run 39125128505, charts#725).
#
# Offline. kubectl is a stub with one workload of two pods. Each pod gets a
# new UID when it is deleted.
#
# Run:
#   bats tests/harness/restart-pods.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  TMP="$(mktemp -d)"; export TMP
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
# STUB_KIND: Deployment (default) or DaemonSet (no .spec.replicas).
# STUB_NEVER_READY: the new pods never become Ready.
# STUB_OLD_STAYS: a deleted pod comes back with its old UID.
# STUB_OLD_DELETING: the list also holds the old pod, being deleted.
case "$*" in
  "-n gibson get deployment/gibson-ext-authz -o json"|"-n gibson get daemonset/gibson-ext-authz -o json")
    if [ "${STUB_KIND:-Deployment}" = DaemonSet ]; then
      echo '{"kind":"DaemonSet","spec":{"selector":{"matchLabels":{"app.kubernetes.io/component":"ext-authz"}}},"status":{"desiredNumberScheduled":'"${STUB_DS_WANT:-2}"'}}'
    else
      echo '{"kind":"Deployment","spec":{"replicas":2,"selector":{"matchLabels":{"app.kubernetes.io/component":"ext-authz"}}}}'
    fi ;;
  "-n gibson delete pod ext-authz-a --ignore-not-found --wait=true --timeout="*|"-n gibson delete pod ext-authz-b --ignore-not-found --wait=true --timeout="*)
    echo "$5" >> "$TMP/deleted"; echo "delete $5 $8" >> "$TMP/events"
    # STUB_SLOW_DELETE: each delete takes one second.
    [ -z "${STUB_SLOW_DELETE:-}" ] || sleep 1 ;;
  "-n gibson get pods -l app.kubernetes.io/component=ext-authz -o json")
    echo read >> "$TMP/events"
    r=True; [ -z "${STUB_NEVER_READY:-}" ] || r=False
    ua=a0; ub=b0; rb="$r"
    # STUB_CRASHING_B: the old pod ext-authz-b is in a crash loop (Running,
    # not Ready) until it is deleted.
    [ -z "${STUB_CRASHING_B:-}" ] || rb=False
    if [ -z "${STUB_OLD_STAYS:-}" ]; then
      ! grep -qx ext-authz-a "$TMP/deleted" 2>/dev/null || ua=a1
      ! grep -qx ext-authz-b "$TMP/deleted" 2>/dev/null || { ub=b1; rb="$r"; }
    fi
    extra='[]'
    # STUB_EVICTED: an old pod evicted by the kubelet stays in the list.
    [ -z "${STUB_EVICTED:-}" ] || extra='[{"metadata":{"name":"ext-authz-z-evicted","uid":"z0"},"status":{"phase":"Failed","conditions":[]}}]'
    # STUB_GAP: right after a delete, the first read lists one pod fewer.
    if [ -n "${STUB_GAP:-}" ] && [ -e "$TMP/deleted" ] && [ ! -e "$TMP/gap.$(wc -l < "$TMP/deleted")" ]; then
      : > "$TMP/gap.$(wc -l < "$TMP/deleted")"
      jq -n '{items: [{metadata: {name: "ext-authz-b", uid: "b0"}, status: {conditions: [{type: "Ready", status: "True"}]}}]}'
      exit 0
    fi
    [ -z "${STUB_OLD_DELETING:-}" ] || extra='[{"metadata":{"name":"ext-authz-old","uid":"a0","deletionTimestamp":"2026-10-18T12:00:00Z"},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]'
    jq -n --arg r "$r" --arg rb "$rb" --arg ua "$ua" --arg ub "$ub" --argjson extra "$extra" '{items: ([
      {metadata: {name: "ext-authz-a", uid: $ua}, status: {conditions: [{type: "Ready", status: $r}]}},
      {metadata: {name: "ext-authz-b", uid: $ub}, status: {conditions: [{type: "Ready", status: $rb}]}}] + $extra)}' ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
}

teardown() { rm -rf "$TMP"; }

run_restart() {
  run env PATH="$TMP/bin:$PATH" RESTART_PODS_POLL=0 bash -c '. "$1"; restart_pods gibson "$2" 3' _ \
    "$REPO_ROOT/scripts/lib/restart-pods.sh" "${1:-deployment/gibson-ext-authz}"
}

@test "restart_pods deletes each pod of the workload, one at a time, and waits for new Ready pods" {
  run_restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(tr '\n' ' ' < "$TMP/deleted")" = "ext-authz-a ext-authz-b " ]
}

@test "a DaemonSet restarts by its desiredNumberScheduled" {
  export STUB_KIND=DaemonSet
  run_restart daemonset/gibson-ext-authz
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "an old pod that is being deleted does not count against the restart" {
  export STUB_OLD_DELETING=1
  run_restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "a workload that wants 0 pods has nothing to restart" {
  export STUB_KIND=DaemonSet STUB_DS_WANT=0
  run_restart daemonset/gibson-ext-authz
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"wants 0 pods, so there is nothing to restart"* ]]
  [ ! -e "$TMP/deleted" ]
}

@test "FAILING FIXTURE: an evicted old pod in the list does not block the restart" {
  export STUB_EVICTED=1
  run_restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The evicted pod gets no replacement, so it is not deleted and not waited for.
  [ "$(tr '\n' ' ' < "$TMP/deleted")" = "ext-authz-a ext-authz-b " ]
}

@test "FAILING FIXTURE: right after a delete, a list with one pod fewer does not count as restarted" {
  # The count check: without it the next delete would take the second replica
  # before the first came back.
  export STUB_GAP=1
  run_restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -e "$TMP/gap.1" ] && [ -e "$TMP/gap.2" ]
  # The short read after the first delete must not end the wait: a second
  # read comes before the second delete.
  [ "$(awk '/^delete/{n++} n==1 && /^read/{r++} END{print r+0}' "$TMP/events")" -ge 2 ] \
    || { cat "$TMP/events"; false; }
}

@test "FAILING FIXTURE: an old pod in a crash loop does not block the restart" {
  export STUB_CRASHING_B=1
  run_restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(tr '\n' ' ' < "$TMP/deleted")" = "ext-authz-a ext-authz-b " ]
}

@test "FAILING FIXTURE: each delete gets the time left until the deadline, not the full timeout" {
  # Each delete takes one second of the 3s timeout, so the second delete
  # gets 2s or less.
  export STUB_SLOW_DELETE=1
  run_restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(grep -c '^delete' "$TMP/events")" -eq 2 ]
  t="$(grep '^delete ext-authz-b' "$TMP/events" | awk '{print $3}')"
  [[ "$t" =~ ^--timeout=([0-9]+)s$ ]] || { echo "bad: $t"; false; }
  [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[1]}" -le 2 ] || { echo "bad: $t"; false; }
}

@test "FAILING FIXTURE: a workload whose new pods never become Ready fails the restart" {
  export STUB_NEVER_READY=1
  run_restart
  [ "$status" -ne 0 ]
  [[ "$output" == *"has not 1 new Ready pods within 3s, after the delete of ext-authz-a"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a pod that still has its old UID is no restart" {
  export STUB_OLD_STAYS=1
  run_restart
  [ "$status" -ne 0 ]
  [[ "$output" == *"has not 1 new Ready pods within 3s, after the delete of ext-authz-a"* ]] || { echo "$output"; false; }
}

# own_restarts FILE...: each line, not a comment, that runs `rollout restart`.
# Only the namespaces that the identity policy does not bind may use it:
# velero and kube-system.
own_restarts() {
  grep -nE '^[^#]*kubectl[^#]*rollout restart' "$@" | grep -vE 'kubectl -n (velero|kube-system) rollout restart'
}

@test "no script or test restarts a workload of a bound namespace with rollout restart" {
  run own_restarts "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh "$REPO_ROOT"/test/*/*.sh
  [ "$status" -eq 1 ] || { echo "status ${status}: $output"; false; }
}

@test "FAILING FIXTURE: a rollout restart by name, by variable or by label is found, and a comment is not" {
  printf 'kubectl -n "$NS" rollout restart deployment/gibson-ext-authz >/dev/null\n' > "$TMP/a.sh"
  printf '  kubectl -n "$ns" rollout restart "$w" >/dev/null\n' > "$TMP/b.sh"
  printf 'kubectl -n "$NS" rollout restart deployment -l app.kubernetes.io/component=ratelimit\n' > "$TMP/c.sh"
  printf '# never: kubectl -n x rollout restart deployment/gibson-ext-authz\n' > "$TMP/d.sh"
  run own_restarts "$TMP/a.sh"; [ "$status" -eq 0 ]
  run own_restarts "$TMP/b.sh"; [ "$status" -eq 0 ]
  run own_restarts "$TMP/c.sh"; [ "$status" -eq 0 ]
  run own_restarts "$TMP/d.sh"; [ "$status" -eq 1 ]
}
