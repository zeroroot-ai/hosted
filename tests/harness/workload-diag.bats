#!/usr/bin/env bats
#
# workload-diag.bats: when a promotion does not land, the proof names the
# workloads that are not ready and why (promote-staging run 45101003946 named
# none, because Argo CD 3 keeps resource health out of the Application status).
#
# Offline: each filter reads a fixture of the kubectl JSON shape.
#
# Run:
#   bats tests/harness/workload-diag.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  # shellcheck source=../../scripts/lib/workload-diag.sh
  source "$REPO_ROOT/scripts/lib/workload-diag.sh"
}

@test "a Deployment below its replicas is named with its failed condition" {
  run workload_diag_workloads <<'JSON'
{"items":[
 {"kind":"Deployment","metadata":{"name":"gibson-ext-authz"},"spec":{"replicas":2},
  "status":{"readyReplicas":0,"conditions":[
   {"type":"Available","status":"False","reason":"MinimumReplicasUnavailable","message":"Deployment does not have minimum availability."},
   {"type":"Progressing","status":"False","reason":"ProgressDeadlineExceeded","message":"ReplicaSet has timed out progressing."}]}},
 {"kind":"Deployment","metadata":{"name":"gibson-dashboard"},"spec":{"replicas":1},"status":{"readyReplicas":1}}
]}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deployment/gibson-ext-authz ready 0/2"* ]]
  [[ "$output" == *"Progressing: ProgressDeadlineExceeded ReplicaSet has timed out progressing."* ]]
  [[ "$output" != *"gibson-dashboard"* ]]
}

@test "a StatefulSet and a DaemonSet that are not ready are named" {
  run workload_diag_workloads <<'JSON'
{"items":[
 {"kind":"StatefulSet","metadata":{"name":"gibson"},"spec":{"replicas":1},"status":{"readyReplicas":0}},
 {"kind":"DaemonSet","metadata":{"name":"node-agent"},"status":{"desiredNumberScheduled":3,"numberReady":2}}
]}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"StatefulSet/gibson ready 0/1"* ]]
  [[ "$output" == *"DaemonSet/node-agent ready 2/3"* ]]
}

@test "a crash-looping pod is named with its reason and its last exit" {
  run workload_diag_pods <<'JSON'
{"items":[
 {"metadata":{"name":"gibson-tenant-operator-abc"},"status":{"phase":"Running","containerStatuses":[
  {"name":"manager","ready":false,"restartCount":7,
   "state":{"waiting":{"reason":"CrashLoopBackOff","message":"back-off 5m0s"}},
   "lastState":{"terminated":{"reason":"Error","exitCode":1}}}]}},
 {"metadata":{"name":"gibson-dashboard-xyz"},"status":{"phase":"Running","containerStatuses":[
  {"name":"web","ready":true,"restartCount":0,"state":{"running":{}}}]}},
 {"metadata":{"name":"migrate-1"},"status":{"phase":"Succeeded"}}
]}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pod/gibson-tenant-operator-abc Running | manager: waiting CrashLoopBackOff (last: Error exit 1) restarts 7"* ]]
  [[ "$output" != *"gibson-dashboard-xyz"* ]]
  [[ "$output" != *"migrate-1"* ]]
}

@test "a pod that cannot pull its image is named" {
  run workload_diag_pods <<'JSON'
{"items":[
 {"metadata":{"name":"bootstrap-1"},"status":{"phase":"Pending","containerStatuses":[
  {"name":"runner","ready":false,"restartCount":0,
   "state":{"waiting":{"reason":"ImagePullBackOff","message":"manifest unknown"}}}]}}
]}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pod/bootstrap-1 Pending | runner: waiting ImagePullBackOff manifest unknown"* ]]
}

@test "only the last Warning events are printed, in time order" {
  export WORKLOAD_DIAG_EVENTS=2
  run workload_diag_events <<'JSON'
{"items":[
 {"type":"Normal","reason":"Pulled","message":"pulled","lastTimestamp":"2026-11-23T02:00:00Z","involvedObject":{"kind":"Pod","name":"a"}},
 {"type":"Warning","reason":"BackOff","message":"first","lastTimestamp":"2026-11-23T02:01:00Z","involvedObject":{"kind":"Pod","name":"a"}},
 {"type":"Warning","reason":"FailedMount","message":"second","lastTimestamp":"2026-11-23T02:03:00Z","involvedObject":{"kind":"Pod","name":"b"}},
 {"type":"Warning","reason":"Unhealthy","message":"third","lastTimestamp":"2026-11-23T02:02:00Z","involvedObject":{"kind":"Pod","name":"c"}}
]}
JSON
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Pod/c Unhealthy" ]
  [ "${lines[1]}" = "Pod/b FailedMount: second" ]
  [[ "$output" != *"first"* ]]
  [[ "$output" != *"pulled"* ]]
}

@test "a rollout that is stuck while the old pods stay ready is named" {
  run workload_diag_workloads <<'JSON'
{"items":[
 {"kind":"Deployment","metadata":{"name":"gibson-ext-authz"},"spec":{"replicas":2},
  "status":{"readyReplicas":2,"updatedReplicas":1,"conditions":[
   {"type":"Progressing","status":"False","reason":"ProgressDeadlineExceeded","message":"ReplicaSet has timed out progressing."}]}}
]}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deployment/gibson-ext-authz ready 2/2 updated 1/2"* ]]
  [[ "$output" == *"ProgressDeadlineExceeded"* ]]
}

@test "an evicted pod prints its reason" {
  run workload_diag_pods <<'JSON'
{"items":[{"metadata":{"name":"p1"},"status":{"phase":"Failed","reason":"Evicted"}}]}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pod/p1 Failed Evicted"* ]]
}

@test "a series event sorts by its last observed time" {
  export WORKLOAD_DIAG_EVENTS=1
  run workload_diag_events <<'JSON'
{"items":[
 {"type":"Warning","reason":"FailedScheduling","message":"recurring","eventTime":"2026-11-23T01:00:00.000000Z",
  "series":{"lastObservedTime":"2026-11-23T03:00:00.000000Z"},"involvedObject":{"kind":"Pod","name":"a"}},
 {"type":"Warning","reason":"BackOff","message":"older","lastTimestamp":"2026-11-23T02:00:00Z","involvedObject":{"kind":"Pod","name":"b"}}
]}
JSON
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Pod/a FailedScheduling: recurring" ]
}

# A token put into each message source never reaches the output. The shapes
# come from the review of hosted#211: a pattern missed each of them, so a
# message prints only for an allowlisted reason.
TOKEN="s3cr3t-T0KEN-value"

leak_shapes() {
  printf '%s\n' \
    "password: $TOKEN" "password=$TOKEN" "token=$TOKEN at start" "{\\\"token\\\":\\\"$TOKEN\\\"}" \
    "?access_token=$TOKEN" "client_secret=$TOKEN" "X-Amz-Signature=$TOKEN" \
    "BEARER $TOKEN" "Authorization: Basic $TOKEN" "token $TOKEN" "data: $TOKEN" \
    "exec: /app --db-password=$TOKEN --token $TOKEN" "https://user:$TOKEN@host/x"
}

@test "no message of an event outside the allowlist prints, for every leak shape" {
  while IFS= read -r m; do
    run workload_diag_events <<JSON
{"items":[
 {"type":"Warning","reason":"Unhealthy","message":"$m","lastTimestamp":"2026-11-23T02:00:00Z","involvedObject":{"kind":"Pod","name":"redis"}},
 {"type":"Warning","reason":"FailedPostStartHook","message":"$m","lastTimestamp":"2026-11-23T02:01:00Z","involvedObject":{"kind":"Pod","name":"daemon"}},
 {"type":"Warning","reason":"FailedCreate","message":"$m","lastTimestamp":"2026-11-23T02:02:00Z","involvedObject":{"kind":"ReplicaSet","name":"r"}},
 {"type":"Warning","reason":"UpdateFailed","message":"$m","lastTimestamp":"2026-11-23T02:03:00Z","involvedObject":{"kind":"ExternalSecret","name":"gibson-db"}}
]}
JSON
    [ "$status" -eq 0 ]
    [[ "$output" != *"$TOKEN"* ]] || { echo "leaked: $m -> $output"; return 1; }
    [[ "$output" == *"Pod/redis Unhealthy"* ]]
    [[ "$output" == *"ReplicaSet/r FailedCreate"* ]]
    [[ "$output" == *"ExternalSecret/gibson-db UpdateFailed"* ]]
  done < <(leak_shapes)
}

@test "an allowlisted event prints its message" {
  run workload_diag_events <<'JSON'
{"items":[{"type":"Warning","reason":"FailedScheduling","message":"0/3 nodes are available: 3 Insufficient cpu.","lastTimestamp":"2026-11-23T02:00:00Z","involvedObject":{"kind":"Pod","name":"p"}}]}
JSON
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Pod/p FailedScheduling: 0/3 nodes are available: 3 Insufficient cpu." ]
}

@test "a waiting message outside the allowlist does not print, for every leak shape" {
  while IFS= read -r m; do
    for reason in RunContainerError CreateContainerError PostStartHookError CrashLoopBackOff; do
      run workload_diag_pods <<JSON
{"items":[{"metadata":{"name":"p"},"status":{"phase":"Pending","containerStatuses":[
 {"name":"c","ready":false,"restartCount":0,"state":{"waiting":{"reason":"$reason","message":"$m"}}}]}}]}
JSON
      [ "$status" -eq 0 ]
      [[ "$output" != *"$TOKEN"* ]] || { echo "leaked: $reason $m"; return 1; }
      [[ "$output" == *"c: waiting $reason restarts 0"* ]]
    done
  done < <(leak_shapes)
}

@test "an image pull waiting message prints and is cut" {
  export WORKLOAD_DIAG_MAX=40
  run workload_diag_pods <<'JSON'
{"items":[{"metadata":{"name":"p"},"status":{"phase":"Pending","containerStatuses":[
 {"name":"c","ready":false,"restartCount":0,"state":{"waiting":{"reason":"ImagePullBackOff",
  "message":"Back-off pulling image ghcr.io/zeroroot-ai/gibson-bootstrap-runner@sha256:c254c8d0"}}}]}}]}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"waiting ImagePullBackOff Back-off pulling image ghcr.io/zeroroot"*"…"* ]]
}

@test "a container terminated message is never printed" {
  run workload_diag_pods <<JSON
{"items":[{"metadata":{"name":"p"},"status":{"phase":"Running","containerStatuses":[
 {"name":"c","ready":false,"restartCount":1,"state":{"terminated":{"reason":"Error","exitCode":2,"message":"log line $TOKEN"}}}]}}]}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"c: ended Error exit 2"* ]]
  [[ "$output" != *"$TOKEN"* ]]
}

@test "a ReplicaFailure condition that is True is named, without its message" {
  run workload_diag_workloads <<JSON
{"items":[{"kind":"Deployment","metadata":{"name":"d"},"spec":{"replicas":1},
 "status":{"readyReplicas":1,"updatedReplicas":1,"conditions":[
  {"type":"Available","status":"True"},
  {"type":"ReplicaFailure","status":"True","reason":"FailedCreate","message":"admission webhook denied: env $TOKEN"}]}}]}
JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deployment/d ready 1/1 updated 1/1 | ReplicaFailure: FailedCreate"* ]]
  [[ "$output" != *"$TOKEN"* ]]
  [[ "$output" != *"Available"* ]]
}
