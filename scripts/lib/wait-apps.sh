#!/usr/bin/env bash
# wait-apps.sh — "every Argo Application is Synced+Healthy", for EVERY
# substrate (ADR-0083, deploy#1737, deploy#1746).
#
# Slow is fine; stuck is not. Getting that distinction right is the whole
# reason this is one file and not two: ENV=kind learned it the hard way
# (deploy#1737) and the AWS arm shipped a simpler copy that had not, which is
# a duplicate with drift (ADR-0027).
#
# What the AWS copy got wrong, measured on staging (deploy#1746): it counted
# only the Synced+Healthy APPLICATION count. A cold three-instance CNPG
# bringup streams a base backup for minutes while no Application flips, so the
# stall clock ran to 16 of its 20 minutes on a cluster that was working
# perfectly. The third replica finished with four minutes to spare. The next
# slow thing would not have been so lucky.
#
# Source this file, then call `wait_apps`. The caller supplies:
#
#   WAIT_APPS_TIMEOUT / WAIT_APPS_STALL  the hard cap and the stall window
#   HERE                                 the scripts/ directory, for
#                                        lib/argo-app-unhealthy.py
#   WORK                                 a scratch directory the caller cleans
#   die()                                MUST exit non-zero
#
# externalsecrets_unready — one line per ExternalSecret, in any namespace,
# whose Ready condition is not True: `namespace/name reason: message`.
# Prints nothing when every ExternalSecret is Ready, or when the cluster has
# no ExternalSecret CRD yet (a wait on the CRD Applications runs before it).
#
# WHY CONVERGENCE INCLUDES THIS (hosted#174). On 2026-09-22 every
# ExternalSecret in gibson read `could not get secret data from provider` for
# hours. Every pod was Running, every workload Ready, every Certificate True,
# and one Argo Application read Degraded. The pods kept running on Secrets
# written earlier: nothing deletes a Secret when its source stops answering.
# A bringup that reports green over that state reports green over a dead
# secret plane, and the first rotation or restart finds it.
externalsecrets_unready() {
    kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1 || return 0
    local rows
    if ! rows="$(kubectl get externalsecrets --all-namespaces \
        -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.conditions[?(@.type=="Ready")].reason}: {.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' 2>&1)"; then
        printf 'externalsecrets/*\t<unknown>\tcould not list the ExternalSecrets: %s\n' "$rows"
        return 0
    fi
    printf '%s\n' "$rows" | awk -F'\t' 'NF && $2!="True" {print $1" Ready="($2==""?"<none>":$2)" "$3}'
}

# wait_apps_diagnose <states> — everything the cluster can still be asked
# before a bringup is declared dead. Called from BOTH death paths.
#
# It used to be inline in the deadline path only, so the OTHER death, a sync
# operation whose retries are spent, printed one line per Application and
# nothing else. That is the death the gibson exit tests hit: twenty runs of
# exit-test-bank back to 2026-09-29 died on it, every log said "one or more
# synchronization tasks completed unsuccessfully (retried 5 times)", and not
# one named the task. Argo's own message never does; the task sits in
# .status.operationState.syncResult.resources. Two death paths with different
# diagnosis is the duplicate-with-drift ADR-0027 forbids, so there is one.
#
# A diagnostic NEVER changes the exit path: every command here ends in
# `|| true`, and the caller dies after it, with the same message as before.
wait_apps_diagnose() {
    # All four fields the healthy test reads. Run 34315064565 (2026-09-09)
    # died here at 2/3 with every line reading sync=Synced health=Healthy:
    # the third app's operation phase was what held it, and this dump did
    # not show it.
    kubectl -n argocd get applications \
      -o jsonpath='{range .items[*]}  {.metadata.name}: sync={.status.sync.status} health={.status.health.status} operation={.status.operationState.phase} {.status.operationState.message}{"\n"}{end}' >&2 || true
    # The last thing each sync waited on before it ended (hosted#651).
    if [ -s "${WORK:-/nonexistent}/argo-waits.tsv" ]; then
      printf '  the last wait of each sync operation (app, first seen, message):\n' >&2
      awk -F'\t' '{last[$1]=$0} END {for (a in last) print last[a]}' "$WORK/argo-waits.tsv" \
        | sed 's/^/    /' >&2 || true
    fi
    # Every pod that is not ready: a STATUS that is not Running or Completed
    # (Init:0/1, CrashLoopBackOff, Pending), or Running with fewer ready
    # containers than it has (a failing readiness probe).
    printf '  pods not ready:\n' >&2
    kubectl get pods -A --no-headers 2>/dev/null \
      | awk '{split($3, r, "/")} $4=="Completed" {next} $4!="Running" || r[1]!=r[2] {print "    "$1"/"$2" "$3" "$4" restarts="$5}' >&2 || true
    # The ExternalSecrets that are not Ready, by name and with the reason
    # External Secrets gives. Argo rolls them up into one word, Degraded.
    local es
    es="$(externalsecrets_unready 2>/dev/null || true)"
    if [ -n "$es" ]; then
      printf '  ExternalSecrets not Ready (the pods may run on stale Secrets):\n' >&2
      printf '%s\n' "$es" | sed 's/^/    /' >&2
      # The database logins come from the OpenBao database engine, which the
      # openbao-auto-init sidecar writes once the Postgres superuser exists.
      # A login ExternalSecret that never gets ready is explained by this log
      # and by the state of the database cluster, and by nothing else.
      printf '  openbao-auto-init, the last 60 lines:\n' >&2
      kubectl -n "${NS:-gibson}" logs gibson-openbao-0 -c openbao-auto-init --tail=60 2>&1 | sed 's/^/    /' >&2 || true
      printf '  the Postgres cluster and its bootstrap:\n' >&2
      kubectl -n "${NS:-gibson}" get platformbootstraps.gibson.zeroroot.ai,clusters.postgresql.cnpg.io,secret/platform-postgres-superuser -o wide 2>&1 | sed 's/^/    /' >&2 || true
    fi
    # A pod that cannot log in to Postgres with a login role from the OpenBao
    # database engine says "password authentication failed" and nothing more.
    # The server log gives the reason (expired, no password, no match), and the
    # catalog says which login roles exist and until when. The passwords are
    # never printed.
    if kubectl -n "${NS:-gibson}" get pod platform-postgres-1 >/dev/null 2>&1; then
      printf '  Postgres server log, the authentication lines:\n' >&2
      kubectl -n "${NS:-gibson}" logs platform-postgres-1 -c postgres --tail=400 2>&1 \
        | grep -iE 'password authentication|DETAIL|no pg_hba|FATAL' | tail -12 | sed 's/^/    /' >&2 || true
      printf '  Postgres login roles from the database engine (name, valid until, member of):\n' >&2
      kubectl -n "${NS:-gibson}" exec platform-postgres-1 -c postgres -- psql -U postgres -At \
        -c "select r.rolname, r.rolvaliduntil, (select string_agg(o.rolname, ',') from pg_auth_members m join pg_roles o on o.oid = m.roleid where m.member = r.oid) from pg_roles r where r.rolname like 'v-%' order by 1" \
        2>&1 | head -20 | sed 's/^/    /' >&2 || true
    fi
    # A daemon pod that runs and is never Ready answers its readiness probe
    # with 503, and the daemon logs no failed probe. The body of /readyz names
    # each store it checks and the result (hosted#582). port-forward reaches
    # the pod through the kubelet, not the pod network, so a network policy
    # that hides the store from the daemon does not hide this answer too.
    #
    # The port-forward is up when kubectl prints "Forwarding from" (hosted#742).
    # The script waits for that line before it asks /readyz, and stops the
    # port-forward only after. A curl that answers before the forward is up
    # does not prove the forward, and a kill before that line can stop a
    # port-forward that never started.
    local pod port pf_pid pf_out
    pf_out="$(mktemp)"
    for pod in $(kubectl -n "${NS:-gibson}" get pods -l app.kubernetes.io/component=daemon \
                   -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
                   | awk '$2!="True"{print $1}'); do
      port=$(( 20000 + RANDOM % 20000 ))
      printf '  /readyz of %s (not Ready):\n' "$pod" >&2
      : > "$pf_out"
      kubectl -n "${NS:-gibson}" port-forward "pod/$pod" "$port:health" >"$pf_out" 2>&1 &
      pf_pid=$!
      local tries=0
      until grep -q '^Forwarding from' "$pf_out" 2>/dev/null || [ $tries -ge 20 ]; do
        tries=$((tries + 1)); sleep 0.5
      done
      if grep -q '^Forwarding from' "$pf_out" 2>/dev/null; then
        curl -s --max-time 15 "http://127.0.0.1:$port/readyz" 2>&1 | head -c 4000 | sed 's/^/    /' >&2 || true
      else
        printf '    the port-forward to %s did not start in 10 s: %s\n' "$pod" "$(head -c 300 "$pf_out" | tr '\n' ' ')" >&2
      fi
      printf '\n' >&2
      kill "$pf_pid" 2>/dev/null || true
      wait "$pf_pid" 2>/dev/null || true
    done
    rm -f "$pf_out"
    if printf '%s\n' "$1" | grep -qvE '^Synced,Healthy(,Succeeded|,),'; then
      printf '  hooks and resources not Succeeded/Synced in the sync operation:\n' >&2
      kubectl -n argocd get applications -o json 2>/dev/null | python3 -c '
import json, sys
for a in json.load(sys.stdin).get("items", []):
  op = a["status"].get("operationState") or {}
  for r in (op.get("syncResult") or {}).get("resources", []):
      if r.get("hookPhase") not in (None, "Succeeded") or r.get("status") not in (None, "Synced"):
          print("    %s: %s/%s hook=%s %s %s %s" % (a["metadata"]["name"], r.get("kind"), r.get("name"), r.get("hookType"), r.get("hookPhase"), r.get("status"), (r.get("message") or "")[:160]))
' >&2 || true
    fi
    # An app list alone says an app is unhappy, never WHICH object made it
    # so, and that is the one thing needed to fix it. Name every resource
    # Argo itself considers out of sync or unhealthy, plus the operation
    # message and any app condition.
    for app in $(kubectl -n argocd get applications \
                   -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status}/{.status.health.status}/{.status.operationState.phase}{"\n"}{end}' 2>/dev/null \
                   | awk '$2!="Synced/Healthy/Succeeded" && $2!="Synced/Healthy/"{print $1}'); do
      printf '\n===== %s =====\n' "$app" >&2
      kubectl -n argocd get app "$app" -o json 2>/dev/null \
        | python3 "$HERE/lib/argo-app-unhealthy.py" > "$WORK/unhealthy.txt" 2>&1 || true
      grep -v "^DRIFT" "$WORK/unhealthy.txt" >&2 || true
      # Dump field ownership for every object that is OutOfSync with no
      # health problem — the signature of a controller-defaulted custom
      # resource. It has to happen HERE, while the cluster still exists.
      while IFS="$(printf '\t')" read -r _ kind name ns; do
        [ -n "$kind" ] || continue
        # The manager names alone did not say which field drifted (drill run
        # 39163206392, hosted#758). Print the field paths each manager owns.
        printf '  --- field owners of %s/%s\n' "$kind" "$name" >&2
        if [ -n "$ns" ]; then
          kubectl -n "$ns" get "$kind" "$name" -o json 2>/dev/null \
            | python3 "$HERE/lib/argo-field-owners.py" >&2 || true
        else
          kubectl get "$kind" "$name" -o json 2>/dev/null \
            | python3 "$HERE/lib/argo-field-owners.py" >&2 || true
        fi
      done < <(grep "^DRIFT" "$WORK/unhealthy.txt" || true)
      # The controller log of this Application: why its operation stays
      # open (a sync timeout, a retry, a self-heal loop), with its times.
      printf '  --- the application controller log of %s, the last 40 lines:\n' "$app" >&2
      kubectl -n argocd logs statefulset/argocd-application-controller --tail=20000 2>/dev/null \
        | grep -E "application=\"?(argocd/)?${app}([\" ]|$)" | tail -n 40 | cut -c1-400 | sed 's/^/    /' >&2 || true
    done
}

wait_apps() {
  # Wait until every Argo Application in the argocd namespace is
  # Synced+Healthy. Slow is fine; stuck is not: fail after WAIT_APPS_STALL
  # seconds with NO progress, or at the hard cap.
  #
  # Progress is more than the Synced+Healthy app count. A cold wave-0
  # convergence pulls every first-party image onto a fresh node and rolls
  # dozens of workloads: the app count sits still for twenty minutes while
  # pods go Ready one by one (measured, deploy#1737 run B). So the progress
  # fingerprint is the app count PLUS the cluster's pod phase tally: any pod
  # moving (pulled, started, Ready, completed) resets the stall clock, and
  # only a cluster where nothing moves at all is "stuck".
  local hard_deadline=$(( $(date +%s) + WAIT_APPS_TIMEOUT ))
  local start_ts=$(date +%s)
  local last_fp="" fp pods last_progress=$(date +%s) now total healthy stalled
  while :; do
    now=$(date +%s)
    total=$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l)
    # Synced+Healthy is resource state. The sync OPERATION is a separate
    # thing: Argo runs the post-sync hooks (the PAT minter, first-admin,
    # openbao-jwt-auth-init, the branding Job) inside it, and resources read
    # Healthy while those hooks are still writing Secrets that Reloader then
    # rolls the daemon and ext-authz for. Measured 2026-09-08 on the blocker
    # 3 loop: the verb declared convergence at 00:34, the operation finished
    # at 00:36:28, and the seed and the preserve teardown raced pods that
    # were being recreated underneath them. So the third field: the
    # operation phase, which must be Succeeded (or absent, on an Application
    # that has never synced). An Error or Failed phase is a dead sync, named
    # at once rather than waited out.
    states=$(kubectl -n argocd get applications \
      -o jsonpath='{range .items[*]}{.status.sync.status},{.status.health.status},{.status.operationState.phase},{.status.operationState.message}{"\n"}{end}' 2>/dev/null)
    healthy=$(printf '%s\n' "$states" | grep -cE '^Synced,Healthy(,Succeeded|,),' || true)
    # An Error or Failed phase is final only once Argo has spent its retries:
    # the Application carries `retry: limit 5`, and between attempts the
    # phase reads Error with a message that does not yet say "retried N
    # times". Dying on the first Error would kill a bringup that recovers
    # on the next attempt; waiting out an exhausted one wastes the stall
    # window. So the message decides.
    # The last thing each sync waited on. Argo says it while the operation
    # runs ("waiting for healthy state of batch/Job/x"), and replaces it with
    # "Operation terminated" when the controller's sync timeout ends the
    # operation. Drill run 38224412842 died that way, and the dump could not
    # name what the sync had waited on (hosted#651). So keep it.
    kubectl -n argocd get applications \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.operationState.message}{"\n"}{end}' 2>/dev/null \
      | grep -E $'\twaiting for ' | while IFS=$'\t' read -r _app _msg; do
          printf '%s\t%s\t%s\n' "$_app" "$(date -u +%H:%M:%SZ)" "$_msg" >> "$WORK/argo-waits.tsv"
        done || true
    if printf '%s\n' "$states" | grep -E ',(Error|Failed),' | grep -qE 'retried [0-9]+ times'; then
      printf '\n'
      wait_apps_diagnose "$states"
      die "an Application's sync operation failed and Argo has spent its retries (a sync task or hook Job keeps dying); the resources may read Healthy, the bringup is not"
    fi
    if [ "$total" -gt 0 ] && [ "$healthy" -eq "$total" ]; then printf '\n'; return 0; fi
    # Finished pods are EXCLUDED. The platform runs a redis-rotation CronJob
    # every minute, so counting Completed pods made the cluster look busy for
    # ever: the stall clock never reached its limit and a wedged bringup
    # burned the whole hard cap instead of failing at the stall (measured,
    # deploy#1737 run 33633490342). Only pods that are still working count as
    # movement.
    pods=$(kubectl get pods -A --no-headers 2>/dev/null \
      | awk '$4!="Completed" && $4!="Succeeded" {print $1"/"$2":"$3":"$4}' \
      | sort | sha256sum | cut -c1-16)
    fp="${healthy}/${total}:${pods}"
    if [ "$fp" != "$last_fp" ]; then last_fp="$fp"; last_progress=$now; fi
    stalled=$(( now - last_progress ))
    # Ask Argo to re-evaluate every app that is not yet Synced+Healthy.
    #
    # An Application's health is recomputed on a refresh, not on a timer that
    # can be relied on here. MEASURED (kind, deploy#1737): gibson-crds went
    # Progressing -> Degraded while its 58 CRDs were establishing, its last
    # reconcile was 38 s later, and it then sat Degraded for over four
    # minutes with every CRD Established and no child reporting anything but
    # Healthy. One refresh request flipped it to Synced+Healthy immediately.
    # Nothing else was going to move: the CRDs had settled, so no resource
    # event was coming.
    #
    # This is exactly what `argocd app get --refresh` and the Refresh button
    # do, and it cannot make a broken app report healthy: the refresh
    # recomputes health from live cluster state. Every 60 s, so a converging
    # app is not hammered.
    if [ $(( (now - start_ts) % 60 )) -lt 10 ]; then
      kubectl -n argocd get applications \
        -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null \
        | awk -F= '$2!="Synced/Healthy"{print $1}' \
        | while read -r app; do
            [ -n "$app" ] && kubectl -n argocd annotate application "$app" \
              argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
          done
    fi
    if [ "$now" -ge "$hard_deadline" ] || [ "$stalled" -ge "$WAIT_APPS_STALL" ]; then
      printf '\n'
      wait_apps_diagnose "$states"
      if [ "$now" -ge "$hard_deadline" ]; then
        die "not every Application reached Synced+Healthy within $(( WAIT_APPS_TIMEOUT / 60 ))m"
      fi
      die "no Synced+Healthy progress for $(( stalled / 60 ))m (stuck, not slow)"
    fi
    printf '  apps: %d/%d Synced+Healthy  [%dm since last progress; stall-fail at %dm]\r' \
      "$healthy" "$total" "$(( stalled / 60 ))" "$(( WAIT_APPS_STALL / 60 ))"
    sleep 10
  done
}

# wait_externalsecrets — the last gate of a bringup: every ExternalSecret in
# the cluster is Ready (hosted#174). Every Application Synced+Healthy is not
# enough. A secret plane that stopped answering leaves the pods Running, and
# Argo rolls it up into one word, Degraded.
#
# Call it once, after the final wait_apps and after any restore. An earlier
# wait_apps runs before a restored store exists, when an ExternalSecret that
# is not Ready yet is normal. WAIT_ES_TIMEOUT (default 300 s) bounds the wait
# for one refresh of External Secrets.
wait_externalsecrets() {
  local deadline=$(( $(date +%s) + ${WAIT_ES_TIMEOUT:-300} )) unready
  while :; do
    unready="$(externalsecrets_unready)"
    if [ -z "$unready" ]; then
      printf '  ✓ every ExternalSecret is Ready\n'
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf '  ExternalSecrets not Ready (the pods may run on stale Secrets):\n' >&2
      printf '%s\n' "$unready" | sed 's/^/    /' >&2
      die "$(printf '%s\n' "$unready" | grep -c .) ExternalSecret(s) are not Ready after ${WAIT_ES_TIMEOUT:-300}s (named above). The pods run on Secrets that nothing backs any more (hosted#174)"
    fi
    sleep 10
  done
}
