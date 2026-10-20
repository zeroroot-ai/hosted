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
      echo '{"kind":"Deployment","spec":{"replicas":'"${STUB_WANT:-2}"',"selector":{"matchLabels":{"app.kubernetes.io/component":"ext-authz"}}}}'
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
    # STUB_GONE_B: with a surge, the pod ext-authz-b gets no replacement
    # after its delete, because the workload wants fewer pods.
    gone=false
    [ -z "${STUB_GONE_B:-}" ] || ! grep -qx ext-authz-b "$TMP/deleted" 2>/dev/null || gone=true
    jq -n --arg r "$r" --arg rb "$rb" --arg ua "$ua" --arg ub "$ub" --argjson extra "$extra" --argjson gone "$gone" '{items: ([
      {metadata: {name: "ext-authz-a", uid: $ua}, status: {conditions: [{type: "Ready", status: $r}]}},
      {metadata: {name: "ext-authz-b", uid: $ub}, status: {conditions: [{type: "Ready", status: $rb}]}}] + $extra)}
      | if $gone then .items |= map(select(.metadata.name != "ext-authz-b")) else . end' ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
}

teardown() { rm -rf "$TMP"; }

run_restart() {
  run env PATH="$TMP/bin:$PATH" RESTART_PODS_POLL=0 bash -c '. "$1"; restart_pods gibson "$2" 3; rc=$?; echo "RESULT=${RESTART_PODS_RESULT}"; exit $rc' _ \
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

# own_restarts FILE...: each logical line, not a comment, that runs
# `rollout restart` (a line continuation is joined first, so the verb on the
# next line is seen). Only the namespaces that the identity policy does not
# bind may use it: velero and kube-system. Prints "file:line: text" for each
# hit. Exit 0 when there is a hit, 1 when there is none, 2 when it read
# fewer than MIN files (a scan that read nothing proves nothing).
own_restarts() {
  python3 - "$@" <<'PY'
import re, sys
hits, read = [], 0
for path in sys.argv[1:]:
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except (IsADirectoryError, FileNotFoundError):
        continue
    read += 1
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        start, logical = i + 1, lines[i]
        while logical.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            logical = logical.rstrip()[:-1] + " " + lines[i].strip()
        i += 1
        code = logical.split("#", 1)[0]
        if re.search(r"kubectl|\$\(KUBECTL\)", code) and re.search(r"rollout\s+restart", code) \
                and not re.search(r"-n\s+(velero|kube-system)\s+rollout\s+restart", code):
            hits.append("%s:%d: %s" % (path, start, code.strip()))
print("\n".join(hits))
sys.exit(2 if read < int(__import__("os").environ.get("MIN", "1")) else (0 if hits else 1))
PY
}

@test "no script or test restarts a workload of a bound namespace with rollout restart" {
  files=("$REPO_ROOT/Makefile" "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh "$REPO_ROOT"/test/*/*.sh "$REPO_ROOT"/test/*/*/*.sh)
  while IFS= read -r f; do files+=("$f"); done < <(find "$REPO_ROOT/.github" -type f \( -name '*.yml' -o -name '*.sh' \))
  MIN=60 run own_restarts "${files[@]}"
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

@test "FAILING FIXTURE: a rollout restart on the next line of a continuation, or in a Makefile recipe, is found (hosted#12)" {
  printf 'kubectl -n "$NS" \\\n  rollout restart deployment/gibson-ext-authz\n' > "$TMP/e.sh"
  printf 'restart-x:\n\t@$(KUBECTL) -n $(NAMESPACE) rollout restart deployment/gibson-dashboard\n' > "$TMP/Makefile"
  printf 'kubectl -n velero rollout restart deployment/velero\n' > "$TMP/f.sh"
  run own_restarts "$TMP/e.sh"; [ "$status" -eq 0 ] || { echo "$output"; false; }
  run own_restarts "$TMP/Makefile"; [ "$status" -eq 0 ] || { echo "$output"; false; }
  run own_restarts "$TMP/f.sh"; [ "$status" -eq 1 ]
  MIN=2 run own_restarts "$TMP/f.sh"; [ "$status" -eq 2 ]
}

@test "restart_pods says restarted when it replaced each pod (hosted#12)" {
  run_restart
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT=restarted"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a workload that wants 0 pods returns 0 with the result nothing, never restarted (hosted#12)" {
  export STUB_KIND=DaemonSet STUB_DS_WANT=0
  run_restart daemonset/gibson-ext-authz
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT=nothing"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a surge pod that gets no replacement does not stall the wait (min of N and WANT) (hosted#12)" {
  # The workload wants 1 pod and lists 2. The pod b gets no replacement. The
  # wait after the second delete must ask for 1 new pod, not 2.
  export STUB_WANT=1 STUB_GONE_B=1
  run_restart
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"RESULT=restarted"* ]]
}

# --- three replicas: the stub keeps a state per pod --------------------------
# Each deleted pod gets a new UID and is Ready after STUB3_READY_AFTER reads of
# the pod list. At each delete the stub records how many new pods are Ready.
use3() {
  mkdir -p "$TMP/s3"
  cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
S="$TMP/s3"; R="${STUB3_READY_AFTER:-2}"
reads() { cat "$S/reads" 2>/dev/null || echo 0; }
gen() { cat "$S/gen.$1" 2>/dev/null || echo 0; }
born() { cat "$S/born.$1" 2>/dev/null || echo 0; }
ready_p() { [ "$(gen "$1")" -eq 0 ] || [ $(( $(reads) - $(born "$1") )) -ge "$R" ]; }
case "$*" in
  "-n gibson get deployment/gibson-ext-authz -o json")
    echo '{"kind":"Deployment","spec":{"replicas":3,"selector":{"matchLabels":{"app.kubernetes.io/component":"ext-authz"}}}}' ;;
  "-n gibson delete pod p"?" --ignore-not-found --wait=true --timeout="*)
    p="$5"; nr=0
    for q in p1 p2 p3; do [ "$(gen "$q")" -eq 0 ] || { ready_p "$q" && nr=$((nr + 1)); }; done
    echo "delete $p new_ready=$nr" >> "$S/events"
    echo $(( $(gen "$p") + 1 )) > "$S/gen.$p"; echo "$(reads)" > "$S/born.$p" ;;
  "-n gibson get pods -l app.kubernetes.io/component=ext-authz -o json")
    echo $(( $(reads) + 1 )) > "$S/reads"
    items=""
    for q in p1 p2 p3; do
      st=False; ready_p "$q" && st=True
      items="${items:+$items,}{\"metadata\":{\"name\":\"$q\",\"uid\":\"$q-$(gen "$q")\"},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"$st\"}]}}"
    done
    # STUB3_REVIVE: after the third delete, a pod with the old UID of p1 lives again.
    if [ -n "${STUB3_REVIVE:-}" ] && [ "$(gen p3)" -ge 1 ]; then
      items="$items,{\"metadata\":{\"name\":\"p1-again\",\"uid\":\"p1-0\"},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}"
    fi
    echo "{\"items\":[$items]}" ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/kubectl"
}

@test "FAILING FIXTURE: with 3 replicas, each delete waits until the pods before it are new and Ready (hosted#12)" {
  use3
  run env PATH="$TMP/bin:$PATH" TMP="$TMP" RESTART_PODS_POLL=0 bash -c '. "$1"; restart_pods gibson deployment/gibson-ext-authz 20' _ \
    "$REPO_ROOT/scripts/lib/restart-pods.sh"
  [ "$status" -eq 0 ] || { echo "$output"; cat "$TMP/s3/events"; false; }
  # Delete 1 sees 0 new Ready pods, delete 2 sees 1, delete 3 sees 2. A loop
  # that deleted without waiting would record 0, 0, 0.
  [ "$(tr '\n' ' ' < "$TMP/s3/events")" = "delete p1 new_ready=0 delete p2 new_ready=1 delete p3 new_ready=2 " ] \
    || { cat "$TMP/s3/events"; false; }
}

@test "FAILING FIXTURE: only the final check sees an old pod that lives again after the last delete (hosted#12)" {
  use3
  run env PATH="$TMP/bin:$PATH" TMP="$TMP" STUB3_REVIVE=1 RESTART_PODS_POLL=0 bash -c '. "$1"; restart_pods gibson deployment/gibson-ext-authz 3' _ \
    "$REPO_ROOT/scripts/lib/restart-pods.sh"
  [ "$status" -ne 0 ]
  # The three deletes happened in order and each wait passed ...
  [ "$(grep -c '^delete' "$TMP/s3/events")" -eq 3 ]
  # ... so the stop comes from the final check.
  [[ "$output" == *"an old pod of gibson/deployment/gibson-ext-authz still runs, or a new one is not Ready"* ]] || { echo "$output"; false; }
  [[ "$output" != *"new Ready pods within"* ]]
}

# restart_ext_authz of the rotation exit test, with the real restart_pods.
run_restart_ext_authz() {
  python3 - "$REPO_ROOT/test/rotation/exit-test-rotation.sh" "$TMP/rea.sh" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^restart_ext_authz\(\) \{.*?^\}\n", text, re.M | re.S)
if not m:
    sys.exit("no function restart_ext_authz in the script")
open(sys.argv[2], "w").write(m.group(0))
PY
  run env PATH="$TMP/bin:$PATH" RESTART_PODS_POLL=0 bash -c '. "$1"; . "$2"; NS=gibson RELEASE=gibson; restart_ext_authz 3' _ \
    "$REPO_ROOT/scripts/lib/restart-pods.sh" "$TMP/rea.sh"
}

@test "the exit test restarts ext-authz and accepts a real restart (hosted#12)" {
  run_restart_ext_authz
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: the exit test refuses an ext-authz that wants 0 pods, because no new pod proves the key (hosted#12)" {
  export STUB_WANT=0
  run_restart_ext_authz
  [ "$status" -ne 0 ]
  [[ "$output" == *"ext-authz wants 0 pods, so no new pod started"* ]] || { echo "$output"; false; }
}
