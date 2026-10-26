#!/usr/bin/env bats
#
# wait-apps.bats — convergence means the sync OPERATION finished, not only
# that the resources read Synced+Healthy.
#
# Argo runs post-sync hooks inside the operation. Resources read Healthy
# while a hook is still minting a Secret that Reloader then rolls the daemon
# for. Measured 2026-09-08: the verb returned at 00:34, the operation ended
# 00:36:28, and the next step raced pods being recreated. The stub below is a
# kubectl that answers the Application query with a phase that moves from
# Running to Succeeded after N calls, and pods that never change.
#
# Run:
#   bats tests/harness/wait-apps.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR" "$STATE"
  PATH="$STUB_DIR:$PATH"
  export STATE
  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
args="$*"
phase="$(cat "$STATE/phase")"
q=$(cat "$STATE/queries" 2>/dev/null || echo 0)
case "$args" in
  *"get applications --no-headers"*) printf 'gibson Synced Healthy\n'; exit 0 ;;
  # The deadline dump: the four fields, the way the real jsonpath prints them.
  *"get applications"*"sync={.status.sync.status} health="*"operation="*)
    msg="$(cat "$STATE/message" 2>/dev/null || true)"
    printf '  gibson: sync=Synced health=Healthy operation=%s %s\n' "${phase%%:*}" "$msg"; exit 0 ;;
  # The per-app dump list (name sync/health/phase). $STATE/applist, empty
  # by default.
  *'{.metadata.name} {.status.sync.status}/'*) cat "$STATE/applist" 2>/dev/null; exit 0 ;;
  "-n argocd get app drill-root -o json") cat "$STATE/root.json"; exit 0 ;;
  "-n argocd get Application monitoring -o json") cat "$STATE/child.json"; exit 0 ;;
  "-n argocd logs statefulset/argocd-application-controller --since=3h") cat "$STATE/controller.log" 2>/dev/null; exit 0 ;;
  "-n argocd logs statefulset/argocd-application-controller --previous") cat "$STATE/controller.previous.log" 2>/dev/null; exit 0 ;;
  "-n argocd get applications -o yaml") printf 'items:\n- metadata:\n    name: gibson\n'; exit 0 ;;
  *"get applications"*"operationState.phase"*)
    q=$((q+1)); echo "$q" > "$STATE/queries"
    # "Running:2,Succeeded" = Running for the first 2 status queries, then Succeeded.
    # A phase may carry a message after a slash: "Error/retried 5 times".
    msg="$(cat "$STATE/message" 2>/dev/null || true)"
    case "$phase" in
      *:*) first="${phase%%:*}"; rest="${phase#*:}"; k="${rest%%,*}"; later="${rest#*,}"
           if [ "$q" -le "$k" ]; then printf 'Synced,Healthy,%s,%s\n' "$first" "$msg"; else printf 'Synced,Healthy,%s,%s\n' "$later" "$msg"; fi ;;
      *) printf 'Synced,Healthy,%s,%s\n' "$phase" "$msg" ;;
    esac; exit 0 ;;
  # The diagnosis reads the whole object: the failing task lives in
  # .status.operationState.syncResult.resources, nowhere else.
  # The per-app operation message (hosted#651): $STATE/waitmsg while the
  # sync runs.
  *'{.metadata.name}{"\t"}{.status.operationState.message}'*)
    printf 'gibson\t%s\n' "$(cat "$STATE/waitmsg" 2>/dev/null || true)"; exit 0 ;;
  *"get applications -o json"*)
    cat "$STATE/apps.json" 2>/dev/null || printf '{"items":[]}'; exit 0 ;;
  *"get applications"*) printf 'gibson: sync=Synced health=Healthy\n'; exit 0 ;;
  *"get pods -A"*) cat "$STATE/pods.txt" 2>/dev/null || printf 'gibson gibson-0 1/1 Running 0 1m\n'; exit 0 ;;
  # ExternalSecrets (hosted#174). $STATE/es.txt holds the rows the jsonpath
  # prints. "ready-after:N" in $STATE/es-ready-after makes them all Ready
  # from the Nth query on.
  *"get externalsecrets"*)
    e=$(cat "$STATE/es-queries" 2>/dev/null || echo 0); e=$((e+1)); echo "$e" > "$STATE/es-queries"
    after="$(cat "$STATE/es-ready-after" 2>/dev/null || echo 0)"
    if [ "$after" -gt 0 ] && [ "$e" -ge "$after" ]; then exit 0; fi
    cat "$STATE/es.txt" 2>/dev/null; exit 0 ;;
  *"logs gibson-openbao-0 -c openbao-auto-init"*) cat "$STATE/openbao.log" 2>/dev/null; exit 0 ;;
  *"get pod platform-postgres-1"*) [ -f "$STATE/pg.log" ] && exit 0; exit 1 ;;
  *"logs platform-postgres-1"*) cat "$STATE/pg.log" 2>/dev/null; exit 0 ;;
  *"exec platform-postgres-1"*) cat "$STATE/pg-roles.txt" 2>/dev/null; exit 0 ;;
  # The daemon pods and their Ready status (hosted#582).
  *"get pods -l app.kubernetes.io/component=daemon"*) cat "$STATE/daemon-pods.txt" 2>/dev/null; exit 0 ;;
  # A port-forward records its call, then says it is up, as kubectl does.
  # With $STATE/pf-broken it never comes up (hosted#742).
  *"port-forward"*)
    echo "$args" > "$STATE/port-forward"
    if [ -f "$STATE/pf-broken" ]; then echo "error: unable to forward port"; sleep 30; exit 1; fi
    echo "Forwarding from 127.0.0.1 -> health"; sleep 30; exit 0 ;;
  # The ExternalSecret CRD is installed on this cluster.
  "get crd externalsecrets.external-secrets.io") exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$STUB_DIR/kubectl"
  # curl answers the forwarded daemon port: /healthz is up, /readyz prints
  # $STATE/readyz.txt (hosted#582).
  cat > "$STUB_DIR/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  */readyz*) cat "$STATE/readyz.txt" 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$STUB_DIR/curl"
  cat > "$BATS_TEST_TMPDIR/run.sh" <<SH
set -uo pipefail
HERE="$REPO_ROOT/scripts"
WORK="\$(mktemp -d)"
die() { printf 'DIE: %s\n' "\$*" >&2; exit 1; }
WAIT_APPS_TIMEOUT="\${WAIT_APPS_TIMEOUT:-45}"
WAIT_APPS_STALL="\${WAIT_APPS_STALL:-600}"
. "$REPO_ROOT/scripts/lib/wait-apps.sh"
if [ "\${GATE:-apps}" = es ]; then wait_externalsecrets; else wait_apps; fi
echo "RETURNED \$?"
SH
}

@test "Synced+Healthy with the operation still Running is NOT convergence; Succeeded is" {
  printf 'Running:2,Succeeded' > "$STATE/phase"
  start=$SECONDS
  run bash "$BATS_TEST_TMPDIR/run.sh"
  elapsed=$(( SECONDS - start ))
  [ "$status" -eq 0 ]
  [[ "$output" == *"RETURNED 0"* ]]
  [ "$elapsed" -ge 10 ]
  [ "$(cat "$STATE/queries")" -ge 3 ]
}

@test "an Application whose sync operation is absent (never synced) still counts" {
  printf '' > "$STATE/phase"
  run bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RETURNED 0"* ]]
}

@test "FAILING FIXTURE: a sync operation that failed with its retries spent is named at once, not waited out" {
  printf 'Failed' > "$STATE/phase"
  printf 'one or more synchronization tasks completed unsuccessfully (retried 5 times).' > "$STATE/message"
  start=$SECONDS
  run bash "$BATS_TEST_TMPDIR/run.sh"
  elapsed=$(( SECONDS - start ))
  [ "$status" -ne 0 ]
  [[ "$output" == *"spent its retries"* ]]
  [ "$elapsed" -lt 10 ]
}

@test "an Error between retries is NOT final: the wait continues and Succeeded then counts" {
  # Argo reads Error between attempts while retries remain (no "retried N
  # times" yet). Two such answers, then Succeeded.
  printf 'Error:2,Succeeded' > "$STATE/phase"
  printf 'one or more synchronization tasks completed unsuccessfully' > "$STATE/message"
  run bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RETURNED 0"* ]]
  [ "$(cat "$STATE/queries")" -ge 3 ]
}

@test "FAILING FIXTURE: at the deadline the dump names the operation phase that held the count, not just sync and health" {
  # Run 34315064565 (2026-09-09): 2/3 at the 90 m cap, every app printed
  # sync=Synced health=Healthy, and nothing said which operation was open.
  printf 'Running' > "$STATE/phase"
  printf 'waiting for completion of hook batch/Job/gibson-gibson-workloads-first-admin' > "$STATE/message"
  run env WAIT_APPS_TIMEOUT=12 bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"within 0m"* ]]
  [[ "$output" == *"operation=Running waiting for completion of hook batch/Job/gibson-gibson-workloads-first-admin"* ]]
}

@test "FAILING FIXTURE: a spent-retries death names the task that died, not only the Application" {
  # Measured on gibson exit-test-bank run 36915409646 (2026-10-01) and the 19
  # runs before it: the log read `gibson: sync=OutOfSync health=Degraded
  # operation=Failed one or more synchronization tasks completed
  # unsuccessfully (retried 5 times).` and stopped there. Argo's message never
  # names the task, so the run could not be diagnosed and the kind cluster
  # died with the runner. The deadline path already dumped the syncResult;
  # this path did not, which is the duplicate ADR-0027 forbids.
  printf 'Failed' > "$STATE/phase"
  printf 'one or more synchronization tasks completed unsuccessfully (retried 5 times).' > "$STATE/message"
  cat > "$STATE/apps.json" <<'JSON'
{"items":[{"metadata":{"name":"gibson"},"status":{"operationState":{"phase":"Failed",
 "syncResult":{"resources":[
   {"kind":"Job","name":"gibson-gibson-workloads-first-admin","hookType":"PostSync",
    "hookPhase":"Failed","status":null,"message":"job failed with 1 retries"},
   {"kind":"Job","name":"gibson-openbao-jwt-auth-init","hookType":"PostSync",
    "hookPhase":"Succeeded","status":null,"message":"job completed"},
   {"kind":"Deployment","name":"gibson-dashboard","hookPhase":null,"status":"Synced",
    "message":"deployment.apps/gibson-dashboard configured"}]}}}}]}
JSON
  run bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spent its retries"* ]]
  # the task, its hook type and Argo's own per-task message
  [[ "$output" == *"Job/gibson-gibson-workloads-first-admin"* ]]
  [[ "$output" == *"hook=PostSync"* ]]
  [[ "$output" == *"job failed with 1 retries"* ]]
  # a Succeeded hook and a Synced resource are NOT reported: that filter is
  # why a green staging listed 31 succeeded hooks as failures on the first try
  [[ "$output" != *"gibson-openbao-jwt-auth-init"* ]]
  [[ "$output" != *"gibson-dashboard"* ]]
}

# ---------------------------------------------------------------------------
# hosted#174: a dead secret plane. Every Application reads Synced+Healthy,
# every pod Runs, and the ExternalSecrets cannot reach their provider. The
# bringup must not report green over that state.
# ---------------------------------------------------------------------------

@test "the Application wait does not read the ExternalSecrets: a restore runs after it" {
  printf 'Succeeded' > "$STATE/phase"
  printf 'gibson/gibson-redis-auth\tFalse\tSecretSyncedError: x\n' > "$STATE/es.txt"
  run bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RETURNED 0"* ]]
}

@test "FAILING FIXTURE: every Application Healthy but one ExternalSecret not Ready fails, and names it" {
  printf 'Succeeded' > "$STATE/phase"
  printf 'gibson/gibson-redis-auth\tFalse\tSecretSyncedError: could not get secret data from provider\ngibson/gibson-zitadel\tTrue\tSecretSynced: ok\n' > "$STATE/es.txt"
  run env GATE=es WAIT_ES_TIMEOUT=12 bash "$BATS_TEST_TMPDIR/run.sh"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" != *"RETURNED 0"* ]]
  [[ "$output" == *"1 ExternalSecret(s) are not Ready after 12s"* ]]
  [[ "$output" == *"gibson/gibson-redis-auth Ready=False SecretSyncedError: could not get secret data from provider"* ]]
  [[ "$output" != *"gibson/gibson-zitadel"* ]]
}

@test "an ExternalSecret that syncs while the bringup waits is convergence" {
  printf 'Succeeded' > "$STATE/phase"
  printf 'gibson/gibson-redis-auth\t\t: \n' > "$STATE/es.txt"
  printf '3' > "$STATE/es-ready-after"
  run env GATE=es bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RETURNED 0"* ]]
  [ "$(cat "$STATE/es-queries")" -ge 3 ]
}

@test "FAILING FIXTURE: a death with an ExternalSecret not Ready prints the log of the OpenBao sidecar" {
  printf 'Failed' > "$STATE/phase"
  printf 'one or more synchronization tasks completed unsuccessfully (retried 5 times).' > "$STATE/message"
  printf 'gibson/zitadel-postgres-credentials\tFalse\tSecretSyncedError: unable to get dynamic secret: empty response from Vault\n' > "$STATE/es.txt"
  printf '[openbao-auto-init] the CNPG superuser Secret is not mounted yet; the database engine waits\n' > "$STATE/openbao.log"
  run bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"openbao-auto-init, the last 60 lines"* ]]
  [[ "$output" == *"the database engine waits"* ]]
}

@test "FAILING FIXTURE: a death prints why Postgres refused a login role, and the login roles that exist" {
  printf 'Failed' > "$STATE/phase"
  printf 'one or more synchronization tasks completed unsuccessfully (retried 5 times).' > "$STATE/message"
  printf 'gibson/openfga-postgres-credentials\tFalse\tSecretSyncedError: x\n' > "$STATE/es.txt"
  printf '2026-10-10 00:33:44 FATAL:  password authentication failed for user "v-kubernet-openfga-x"\n2026-10-10 00:33:44 DETAIL:  User "v-kubernet-openfga-x" has an expired password.\n' > "$STATE/pg.log"
  printf 'v-kubernet-openfga-x|2026-10-09 23:00:00+00|openfga\n' > "$STATE/pg-roles.txt"
  run bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has an expired password"* ]]
  [[ "$output" == *"v-kubernet-openfga-x|2026-10-09 23:00:00+00|openfga"* ]]
}

@test "FAILING FIXTURE: a death prints the /readyz body of each daemon pod that is not Ready" {
  printf 'Failed' > "$STATE/phase"
  printf 'one or more synchronization tasks completed unsuccessfully (retried 5 times).' > "$STATE/message"
  printf 'gibson-gibson-workloads-0 False\ngibson-gibson-workloads-1 True\n' > "$STATE/daemon-pods.txt"
  printf '{"status":"not ready","probes":[{"name":"fga","ok":false,"error":"dial tcp: i/o timeout"}]}' > "$STATE/readyz.txt"
  run bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/readyz of gibson-gibson-workloads-0 (not Ready):"* ]]
  [[ "$output" == *'"name":"fga","ok":false,"error":"dial tcp: i/o timeout"'* ]]
  # A Ready pod is not asked: its answer explains nothing.
  [[ "$output" != *"/readyz of gibson-gibson-workloads-1"* ]]
  [[ "$(cat "$STATE/port-forward")" == *"pod/gibson-gibson-workloads-0"*":health"* ]]
}

@test "FAILING FIXTURE: a port-forward that never starts is named, and /readyz is not asked (hosted#742)" {
  printf 'Failed' > "$STATE/phase"
  printf 'one or more synchronization tasks completed unsuccessfully (retried 5 times).' > "$STATE/message"
  printf 'gibson-gibson-workloads-0 False\n' > "$STATE/daemon-pods.txt"
  printf '{"status":"not ready"}' > "$STATE/readyz.txt"
  : > "$STATE/pf-broken"
  run bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the port-forward to gibson-gibson-workloads-0 did not start in 10 s: error: unable to forward port"* ]] || { echo "$output"; false; }
  [[ "$output" != *'{"status":"not ready"}'* ]] || { echo "$output"; false; }
}

# hosted#651: drill run 38224412842 died on "Operation terminated (retried 2
# times)" after the controller's sync timeout, and the dump could not say
# what the sync had been waiting on: Argo replaces that message when it ends
# the operation. The wait now keeps the last "waiting for" of each app, and
# the dump lists every pod that is not Running or Completed.
@test "FAILING FIXTURE: a terminated sync names what it last waited on, and the pods that were not ready" {
  printf 'Running:1,Failed' > "$STATE/phase"
  printf 'waiting for healthy state of batch/Job/postgres-logins-gate' > "$STATE/waitmsg"
  printf 'Operation terminated (retried 2 times).' > "$STATE/message"
  printf 'gibson gibson-0 1/1 Running 0 1m\ngibson postgres-logins-gate-x 0/1 Init:0/1 0 29m\ngibson gibson-envoy-y 0/1 Running 3 20m\ngibson rotate-z 0/1 Completed 0 5m\n' > "$STATE/pods.txt"
  run bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the last wait of each sync operation"* ]] || { echo "$output"; false; }
  [[ "$output" == *"waiting for healthy state of batch/Job/postgres-logins-gate"* ]]
  [[ "$output" == *"gibson/postgres-logins-gate-x 0/1 Init:0/1"* ]]
  [[ "$output" == *"gibson/gibson-envoy-y 0/1 Running restarts=3"* ]]
  [[ "$output" != *"gibson/gibson-0 "* ]]
  [[ "$output" != *"gibson/rotate-z "* ]]
}

@test "FAILING FIXTURE: a parent stuck on a drifted child Application names the fields each manager owns, and its controller log (hosted#758)" {
  # Drill run 39163206392: drill-root kept operation=Running, and its child
  # Application/monitoring read OutOfSync. The dump named two managers and
  # no field, so the drift could not be named.
  printf 'Running' > "$STATE/phase"
  printf 'drill-root OutOfSync/Healthy/Running\n' > "$STATE/applist"
  cat > "$STATE/root.json" <<'JSON'
{"status":{"operationState":{"phase":"Running","message":"successfully synced (all tasks run)"},
 "resources":[{"kind":"Application","name":"monitoring","namespace":"argocd","status":"OutOfSync"}]}}
JSON
  cat > "$STATE/child.json" <<'JSON'
{"kind":"Application","operation":{"initiatedBy":{"automated":true},"sync":{"revision":"7147848","source":{"helm":{"values":"password: hunter2-not-printed"}}}},
 "metadata":{"generation":7,"resourceVersion":"991",
 "annotations":{"argocd.argoproj.io/refresh":"normal"},
 "managedFields":[
  {"manager":"argocd-controller","operation":"Apply","fieldsV1":{"f:spec":{"f:project":{}}}},
  {"manager":"argocd-application-controller","operation":"Update","time":"2026-10-18T21:01:00Z",
   "fieldsV1":{"f:status":{"f:sync":{}},"f:spec":{"f:sources":{"i:0":{"f:helm":{}}}}}}]}}
JSON
  # Two log shapes: Argo CD 2.x (application=argocd/<name>) and 3.x
  # (application=<name> followed by more fields).
  printf 'time="2026-10-18T21:01:00Z" level=info msg="Sync operation timed out" application=argocd/drill-root\ntime="x" level=info msg="other" application=argocd/drill-root-other\ntime="y" level=info msg="Initiated automated sync" app-namespace=argocd application=drill-root project=default\n' > "$STATE/controller.log"
  run env WAIT_APPS_TIMEOUT=12 bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manager=argocd-application-controller op=Update"* ]] || { echo "$output"; false; }
  [[ "$output" == *"      spec.sources[0].helm"* ]] || { echo "$output"; false; }
  [[ "$output" != *"      status.sync"* ]] || { echo "$output"; false; }
  [[ "$output" == *"annotation argocd.argoproj.io/refresh=normal"* ]] || { echo "$output"; false; }
  [[ "$output" == *'initiatedBy={"automated": true}'*"revision=7147848"* ]] || { echo "$output"; false; }
  # The inline values of a sync can hold a secret, and never print.
  [[ "$output" != *"hunter2-not-printed"* ]] || { echo "$output"; false; }
  [[ "$output" == *'msg="Sync operation timed out" application=argocd/drill-root'* ]] || { echo "$output"; false; }
  [[ "$output" == *'msg="Initiated automated sync" app-namespace=argocd application=drill-root project'* ]] || { echo "$output"; false; }
  [[ "$output" != *"drill-root-other"* ]] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: with WAIT_APPS_LOG_DIR a death keeps the whole controller log and each Application (hosted#24)" {
  # Drill run 40325488009: gibson-velero kept its operation Running from 12:54,
  # and the dump held only the controller lines from 13:27 on. The whole log of
  # the window goes to a file, for the run artifact.
  printf 'Running' > "$STATE/phase"
  printf 'time="2026-10-26T12:54:56Z" level=info msg="Sync operation started" application=gibson-velero\ntime="2026-10-26T13:27:11Z" level=info msg="Skipping auto-sync" application=gibson-velero\n' > "$STATE/controller.log"
  printf 'time="2026-10-26T12:00:00Z" level=info msg="the container before a restart"\n' > "$STATE/controller.previous.log"
  run env WAIT_APPS_TIMEOUT=12 WAIT_APPS_LOG_DIR="$BATS_TEST_TMPDIR/argo-diag" bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the whole controller log and each Application are in $BATS_TEST_TMPDIR/argo-diag"* ]] || { echo "$output"; false; }
  grep -q 'msg="Sync operation started" application=gibson-velero' "$BATS_TEST_TMPDIR/argo-diag/application-controller.log"
  grep -q 'the container before a restart' "$BATS_TEST_TMPDIR/argo-diag/application-controller.previous.log"
  grep -q 'name: gibson' "$BATS_TEST_TMPDIR/argo-diag/applications.yaml"
}

@test "with no WAIT_APPS_LOG_DIR a death writes no log file" {
  printf 'Running' > "$STATE/phase"
  run env WAIT_APPS_TIMEOUT=12 bash "$BATS_TEST_TMPDIR/run.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"the whole controller log"* ]] || { echo "$output"; false; }
}

