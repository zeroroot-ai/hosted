#!/usr/bin/env bats
#
# restore.bats — proves the RESTORE half of `make recreate` fails closed, and
# that a recreate with no name restores NOTHING (deploy#1739, ADR-0083).
#
# WHY THIS SUITE EXISTS
# ---------------------
# Four ways the restore path can go quietly wrong, one fixture each:
#
#   1. A name that matches no backup. The recreate DELETES the cluster it
#      finds, so a typo discovered after that has destroyed a running
#      environment and has nothing to put back. The check must run before
#      stage 1 and must name the object it looked for.
#   2. A nameless recreate that restores anyway. The bucket still holds every
#      backup an earlier preserve teardown wrote, and reading the newest one
#      would collapse a wipe teardown into a preserve (ADR-0083). No Velero
#      Restore may be created, and nothing under backups/ may even be read.
#   3. A restore that runs before External Secrets has synced. Velero backups
#      carry no Secret, so a restored pod takes its Secrets from the store; a
#      tenant Neo4j pod restored too early sits in CreateContainerConfigError
#      and its volume never arrives. Half a tenant, reported as a success.
#   4. A Restore carrying a filter the CRD does not declare. Velero's scoped
#      resource filters are BACKUP fields; a Restore that names one has it
#      pruned silently and restores everything the filter was there to keep
#      out. Nothing fails, and the tenant records land before the volumes they
#      have to adopt.
#   5. A restore in the wrong order. The secret store has to come back before
#      anything reads a Secret, and the built-ins before the tenant records,
#      because the tenant operator ADOPTS a restored claim rather than
#      re-initialising it.
#
# HOW IT IS OFFLINE
# -----------------
# Every binary the verb shells out to is stubbed on PATH and logs its calls:
# kind, kubectl, helm, terraform, docker, aws, git, curl. The bucket is a
# directory. So the whole verb runs, end to end, in about a second, and the
# tests assert on what it DID: which objects it applied, in which order, and
# what it read from the bucket.
#
# Run:
#   bats tests/harness/restore.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
# The chart source moved to zeroroot-ai/charts in the 2026-09-04 split
# (ADR-0086). The suite reads it from CHARTS_ROOT, the same default the
# recreate verb uses: a sibling checkout. Three tests read the chart itself
# (the vendored Velero CRD, the velero values); every recreate the suite
# runs also needs it, because the verb refuses to start without chart
# source, so it is exported for the verb too.
CHARTS="${CHARTS_ROOT:-$REPO_ROOT/../charts}"
export CHARTS_ROOT="$CHARTS"
RECREATE="$REPO_ROOT/scripts/recreate-kind.sh"

SEAL_KEY="c2VhbC1rZXktZm9yLXRoZS1yZXN0b3JlLWJhdHMtc3U="
REPO_PASSWORD="dmVsZXJvLXJlcG8tcGFzc3dvcmQtcmVzdG9yZS1iYXQ="
export BACKUP="preserve-kind-20260902-031500"
BACKUP_ID="20260902T031500"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR" "$STATE/bucket"
  PATH="$STUB_DIR:$PATH"

  export STATE
  export KUBECONFIG="$BATS_TEST_TMPDIR/kubeconfig"
  : > "$KUBECONFIG"
  # Every External Secret is synced unless a test says otherwise.
  export STUB_ES_READY=True
  export STUB_STORE_READY=True

  KEYRING="$BATS_TEST_TMPDIR/keyring.env"
  SUBSTRATE="$BATS_TEST_TMPDIR/substrate.env"
  cat > "$KEYRING" <<EOF
OPENBAO_SEAL_KEY=$SEAL_KEY
VELERO_REPO_PASSWORD=$REPO_PASSWORD
BUCKET_ACCESS_KEY=AKIAEXAMPLEBATS00000
BUCKET_SECRET_KEY=YnVja2V0LXNlY3JldC1rZXktZm9yLWJhdHMtc3Vp
SETEC_DISK_SIGNING_SEED=nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=
GHCR_PULL_TOKEN=
EOF
  cat > "$SUBSTRATE" <<EOF
SUBSTRATE_ENV=kind
BUCKET_ENDPOINT=http://127.0.0.1:9000
BUCKET_REGION=us-east-1
BUCKET_NAME=gibson-kind
KEYRING_FILE=$KEYRING
SETEC_DISK_REPO=127.0.0.1:5000/setec-disks
EOF
  write_stubs
}

# arm_backup — put one preserve-teardown backup in the stub bucket: the
# manifest the existence check looks for, and the archive the CNPG base
# backup id is read out of.
arm_backup() {
  local name="$1"
  local id="$2"
  local archive="${3-platform-postgres-19700101000000}"
  local dir="$STATE/bucket/backups/velero/backups/$name"
  mkdir -p "$dir"
  printf '{"kind":"Backup","metadata":{"name":"%s"},"status":{"phase":"%s"}}' "$name" "${BACKUP_PHASE_IN_BUCKET:-Completed}" > "$dir/velero-backup.json"
  local build="$BATS_TEST_TMPDIR/build"
  rm -rf "$build"
  mkdir -p "$build/resources/backups.postgresql.cnpg.io/namespaces/gibson"
  if [ -n "$id" ]; then
    # status.serverName is the archive the base backup lives in; CNPG writes
    # it on every Backup. An empty third argument leaves it out.
    if [ -n "$archive" ]; then
      printf '{"kind":"Backup","metadata":{"name":"%s"},"status":{"backupId":"%s","serverName":"%s"}}' "$name" "$id" "$archive" \
        > "$build/resources/backups.postgresql.cnpg.io/namespaces/gibson/$name.json"
    else
      printf '{"kind":"Backup","metadata":{"name":"%s"},"status":{"backupId":"%s"}}' "$name" "$id" \
        > "$build/resources/backups.postgresql.cnpg.io/namespaces/gibson/$name.json"
    fi
  fi
  # The backup canary pod, with its label (review of hosted#798).
  mkdir -p "$build/resources/pods/namespaces/tenant-backup-canary"
  printf '{"metadata":{"labels":{"gibson.zeroroot.ai/backup-canary":"true"}}}' \
    > "$build/resources/pods/namespaces/tenant-backup-canary/backup-canary.json"
  tar -czf "$dir/$name.tar.gz" -C "$build" .
}

write_stubs() {
  for tool in terraform docker git; do
    cat > "$STUB_DIR/$tool" <<SH
#!/usr/bin/env bash
echo "$tool \$*" >> "\$STATE/$tool.log"
case "\$*" in *"rev-parse"*) printf 'deadbee' ;; esac
exit 0
SH
  done

  cat > "$STUB_DIR/kind" <<'SH'
#!/usr/bin/env bash
echo "kind $*" >> "$STATE/kind.log"
exit 0
SH

  # curl fetches the URL Velero signs for a restore log. The stub answers with
  # a gzipped log holding the SAME warning in two namespaces, so the fixture
  # measures the fold as well as the print.
  cat > "$STUB_DIR/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$STATE/curl.log"
out=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ] || exit 0
{
  echo 'time="2026-09-02T22:38:00Z" level=warning msg="Skipping restore of resource because it already exists in the cluster" restore=velero/r resource=pods namespace=\"gibson\" logSource="pkg/restore/restore.go:1"'
  echo 'time="2026-09-02T22:38:01Z" level=warning msg="Skipping restore of resource because it already exists in the cluster" restore=velero/r resource=pods namespace=\"tenant-one\" logSource="pkg/restore/restore.go:1"'
  echo 'time="2026-09-02T22:38:02Z" level=info msg="Restoring item"'
  # STUB_MANY_WARNINGS: 45 distinct warnings, each once, and one error, once
  # (drill run 39189378263 had 40 warnings and 10 errors, each once).
  if [ -n "${STUB_MANY_WARNINGS:-}" ]; then
    for i in $(seq 1 45); do echo "time=\"x\" level=warning msg=\"warning number ${i}\""; done
    echo 'time="x" level=error msg="error restoring pods/gibson/gibson-ext-authz-1: pods is forbidden: ValidatingAdmissionPolicy"'
  fi
} | gzip -c > "$out"
exit 0
SH

  # helm: the packaging steps have to leave a file behind, because the
  # publish step copies the directory and the index is fetched afterwards.
  cat > "$STUB_DIR/helm" <<'SH'
#!/usr/bin/env bash
echo "helm $*" >> "$STATE/helm.log"
dir=""
prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && dir="$a"
  prev="$a"
done
case "${1:-}" in
  package) [ -n "$dir" ] && { mkdir -p "$dir"; : > "$dir/chart.tgz"; } ;;
  repo) [ -n "${3:-}" ] && [ -d "$3" ] && : > "$3/index.yaml" ;;
esac
exit 0
SH

  cat > "$STUB_DIR/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$STATE/aws.log"
while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint-url) shift 2 ;;
    --no-progress|--recursive|--quiet) shift ;;
    s3) shift; break ;;
    *) shift ;;
  esac
done
verb="${1:-}"; shift || true
args=()
for a in "$@"; do case "$a" in --*) ;; *) args+=("$a") ;; esac; done
key_of() { printf '%s' "${1#s3://gibson-kind/}"; }
case "$verb" in
  ls)
    k="$(key_of "${args[0]}")"
    [ -e "$STATE/bucket/$k" ] || exit 1
    echo "2026-09-02 03:15:00        512 $k"
    exit 0 ;;
  cp)
    src="${args[0]}"; dst="${args[1]}"
    case "$dst" in
      s3://*)
        k="$(key_of "$dst")"
        if [ -d "$src" ]; then mkdir -p "$STATE/bucket/$k"; cp -r "$src/." "$STATE/bucket/$k"
        else mkdir -p "$STATE/bucket/$(dirname "$k")"; cp "$src" "$STATE/bucket/$k"; fi ;;
      *)
        k="$(key_of "$src")"
        [ -f "$STATE/bucket/$k" ] || exit 1
        cp "$STATE/bucket/$k" "$dst" ;;
    esac
    exit 0 ;;
esac
exit 0
SH

  # Every wait the verb makes is BOUNDED here, so a stub arm this suite is
  # missing fails in a second instead of sleeping to the CI job's timeout.
  # That is not hypothetical: the archiving proof polls for fifteen minutes by
  # default, and without its two stub arms below the job was CANCELLED rather
  # than failed — which reads as a slow runner, not as a broken test.
  export ARCHIVING_TIMEOUT=5 ARCHIVING_POLL=0

  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
args="$*"
echo "kubectl $args" >> "$STATE/kubectl.log"
case "$args" in
  *"apply -f -"*|*"apply --server-side"*)
    # Record every object the verb applies, in order, as <kind>/<name>.
    printf -- '---\n' >> "$STATE/applied-raw.yaml"
    tee -a "$STATE/applied-raw.yaml" \
      | python3 -c 'import sys, yaml
docs = list(yaml.safe_load_all(sys.stdin.read()))
for d in docs:
    if d:
        print("%s/%s" % (d.get("kind"), (d.get("metadata") or {}).get("name")))' >> "$STATE/applied.log"
    exit 0 ;;
  *"create namespace"*"--dry-run"*)
    ns="$(printf '%s' "$args" | sed 's/.*create namespace \([^ ]*\).*/\1/')"
    printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "$ns"
    exit 0 ;;
  # Cilium, the network plugin the verb installs after `kind create`
  # (scripts/lib/cilium.sh, hosted#436). One agent is desired and one is
  # ready, and the DNS proxy answers a denied lookup with NXDOMAIN. The proof pod reaches the permitted host, and its connection to
  # the other host gets no answer, which curl reports as exit 28.
  *"daemonset cilium"*"desiredNumberScheduled"*) printf '1'; exit 0 ;;
  *"daemonset cilium"*"numberReady"*) printf '1'; exit 0 ;;
  # The Cilium DNS proxy answers a denied lookup with NXDOMAIN (charts#518).
  *"configmap cilium-config"*"tofqdns-dns-reject-response-code"*) printf 'nameError'; exit 0 ;;
  *"exec cilium-proof"*"https://ghcr.io/"*) printf '200'; exit 0 ;;
  *"exec cilium-proof"*"https://quay.io/"*) exit 28 ;;
  *"get svc kubernetes"*) printf '10.96.0.1'; exit 0 ;;
  # The kubernetes Service's backing endpoint, the second half of
  # global.networkPolicy.apiServerCIDRs. The bring-up refuses a read that
  # returns the Service address and no endpoints, because a rule naming one of
  # the two names nothing on an engine that matches the other. A stub that
  # answers only the Service makes that refusal fire here instead of in the
  # test's own subject, so it answers both. 172.18.0.3 is a kind control-plane
  # address on the default docker network.
  *"get endpoints kubernetes"*) printf '172.18.0.3\n'; exit 0 ;;
  # The Corefile kind ships, so the bringup's CoreDNS record for the platform
  # hosts (scripts/lib/coredns-platform-hosts.sh, hosted#397) has a server
  # block to land in.
  # The apply, restart and rollout wait fall through to the default arm.
  *"get configmap coredns"*"Corefile"*) printf '.:53 {\n    errors\n    kubernetes cluster.local in-addr.arpa ip6.arpa {\n       pods insecure\n    }\n    forward . /etc/resolv.conf\n}\n'; exit 0 ;;
  *"get applications --no-headers"*) printf 'app Synced Healthy\n'; exit 0 ;;
  # sync,health,operation phase,operation message: the four fields wait_apps
  # reads. The operation Succeeded, as on a real converged bringup.
  *"get applications"*"sync.status"*) printf 'Synced,Healthy,Succeeded,successfully synced (all tasks run)\n'; exit 0 ;;
  *"get applications"*) printf 'app: sync=Synced health=Healthy\n'; exit 0 ;;
  *"get pods -A"*) printf 'gibson pod Running 1/1\n'; exit 0 ;;
  # The archiving proof the verb runs after stage 2 (scripts/lib/
  # wait-archiving.sh). A converged bringup archives, so the stub says so:
  # without these two arms the verb polls a Cluster that never appears and
  # the whole suite sleeps its way to the CI job's timeout, which is how it
  # first showed up — a cancelled job, not a failed test.
  *"type=='ContinuousArchiving'"*) printf '%s' "${STUB_ARCHIVING:-True}"; exit 0 ;;
  *"get backups.postgresql.cnpg.io"*) printf '%s\n' "${STUB_BASE_BACKUP:-platform-postgres-1}"; exit 0 ;;
  *"get clustersecretstore gibson-secrets"*)
    # A store that is not in the cluster yet: kubectl EXITS NON-ZERO. That is
    # the normal first state of the wait, and under set -e an unguarded
    # assignment from it kills the verb (deploy#1740).
    [ "${STUB_STORE_MISSING:-0}" = 1 ] && exit 1
    printf '%s' "${STUB_STORE_READY}"; exit 0 ;;
  # wait_apps reads the Ready condition with its reason and message,
  # tab-separated (hosted#174). wait_eso reads the short space-separated form.
  *"get externalsecrets"*"].reason"*) printf 'gibson/gibson-db-secrets\t%s\tSecretSynced: \n' "${STUB_ES_READY}"; exit 0 ;;
  *"get externalsecrets"*) printf 'gibson gibson-db-secrets %s\n' "${STUB_ES_READY}"; exit 0 ;;
  # The tenant-operator webhook the tenant records restore waits for: the
  # Deployment's replicas/updated/available and the Service's ready endpoints.
  *"get deploy gibson-tenant-operator"*)
    [ "${STUB_WEBHOOK_DOWN:-0}" = 1 ] && { printf '2/1/1'; exit 0; }
    printf '2/2/2'; exit 0 ;;
  *"get endpoints gibson-tenant-operator-webhook"*)
    [ "${STUB_WEBHOOK_DOWN:-0}" = 1 ] && exit 0
    printf '10.244.0.7 10.244.0.9'; exit 0 ;;
  # The chart-owned PriorityClasses the restored pods name. A class the chart
  # has not applied yet: kubectl EXITS NON-ZERO, the normal first state.
  *"get priorityclass "*)
    [ "${STUB_PC_MISSING:-0}" = 1 ] && exit 1
    printf 'priorityclass.scheduling.k8s.io/x\n'; exit 0 ;;
  *"get restore.velero.io/${BACKUP}-"*".status.phase"*) printf '%s' "${STUB_RESTORE_PHASE:-Completed}"; exit 0 ;;
  *"get restore.velero.io/${BACKUP}-"*) printf '{"phase":"%s"}' "${STUB_RESTORE_PHASE:-Completed}"; exit 0 ;;
  *"get restores.velero.io"*) printf '    restore x: Completed\n'; exit 0 ;;
  # The tenant volume check of the pods Restore: the backup canary is the one
  # tenant volume with data here, and the pods Restore moved it.
  "-n velero get podvolumebackups.velero.io -l velero.io/backup-name=${BACKUP} -o jsonpath={range .items[*]}{.spec.pod.namespace}{\"\\t\"}{.spec.pod.name}{\"\\t\"}{.spec.volume}{\"\\t\"}{.status.phase}{\"\\t\"}{.status.progress.totalBytes}{\"\\n\"}{end}")
    printf 'tenant-backup-canary\tbackup-canary\tdata\tCompleted\t65\n'; exit 0 ;;
  "-n velero get podvolumerestores.velero.io -l velero.io/restore-name=${BACKUP}-pods -o jsonpath={range .items[*]}{.spec.pod.namespace}/{.spec.pod.name}/{.spec.volume} {.status.phase}{\"\\n\"}{end}")
    printf 'tenant-backup-canary/backup-canary/data Completed\n'; exit 0 ;;
  # The PodVolumeRestores that hold a Restore open: the ones with no phase at
  # all. The diagnosis has to name the POD behind each, which is the only
  # thing that explains why the node-agent never started it.
  *"podvolumerestores.velero.io"*"spec.pod.namespace"*)
    [ "${STUB_STALLED_PVR:-0}" = 1 ] \
      && printf 'preserve-builtins-abcde tenant-primary tenant-primary-neo4j-0\n'
    exit 0 ;;
  *"get pod/tenant-primary-neo4j-0"*)
    printf 'phase=Pending neo4j=CreateContainerConfigErrorsecret "tenant-primary-neo4j-auth" not found '
    exit 0 ;;
  *"get podvolumerestores.velero.io"*) [ "${STUB_PVR:-1}" = 1 ] && printf 'Completed\n'; exit 0 ;;
  *"get downloadrequest.velero.io/recreate-explain-${BACKUP}-"*) printf 'http://bucket.invalid/signed/restore-logs.gz'; exit 0 ;;
  *"get tenants.gibson.zeroroot.ai"*) printf 'primary '; exit 0 ;;
  "--kubeconfig "*" config use-context kind-restore-bats") exit 0 ;;
  "wait --for=condition=Ready node --all --timeout=300s") exit 0 ;;
  "get crd ciliumnetworkpolicies.cilium.io") exit 0 ;;
  "-n kube-system get pods -l k8s-app=cilium -o wide") exit 0 ;;
  "-n kube-system rollout status daemonset/cilium --timeout=300s") exit 0 ;;
  "-n kube-system rollout status deployment/coredns --timeout=300s") exit 0 ;;
  "create namespace cilium-proof") exit 0 ;;
  "delete namespace cilium-proof --ignore-not-found --wait=true --timeout=120s") exit 0 ;;
  "-n cilium-proof run cilium-proof --image=ghcr.io/zeroroot-ai/mirror/curl:8.10.1 --labels=app=cilium-proof --restart=Never --command -- sleep 900") exit 0 ;;
  "delete namespace cilium-proof --ignore-not-found --wait=false") exit 0 ;;
  "-n cilium-proof describe pod/cilium-proof") exit 0 ;;
  "-n cilium-proof wait --for=condition=Ready pod/cilium-proof --timeout=240s") exit 0 ;;
  "annotate storageclass standard defaultVolumeType=local --overwrite") exit 0 ;;
  # The platform hosts in CoreDNS (lib/coredns-platform-hosts.sh): the
  # rendered Corefile is one argument, so the pattern names the ConfigMap.
  "-n kube-system create configmap coredns --from-literal=Corefile="*" --dry-run=client -o yaml") exit 0 ;;
  "-n kube-system rollout restart deployment/coredns") exit 0 ;;
  "-n kube-system rollout status deployment/coredns --timeout=120s") exit 0 ;;
  # The named backup exists in the cluster (the restore waits for Velero to
  # sync it from the bucket).
  "-n velero get backup.velero.io/${BACKUP}") exit 0 ;;
  "get crd externalsecrets.external-secrets.io") exit 0 ;;
  "-n velero delete downloadrequest.velero.io/recreate-explain-${BACKUP}-"*" --ignore-not-found") exit 0 ;;
  "-n velero get podvolumebackups.velero.io -l velero.io/backup-name=${BACKUP} "*) exit 0 ;;
  # The resource list of the backup (hosted row 11): the Tenant primary and
  # its namespace. The restore creates tenant-primary first, and the
  # operator labels it.
  "-n velero get pods -l name=velero --field-selector=status.phase=Running -o jsonpath={.items[0].metadata.name}") printf 'velero-7d9-abc'; exit 0 ;;
  "-n velero exec pod/velero-7d9-abc -c velero -- /velero backup describe ${BACKUP} --details -n velero")
    printf 'Name:  %s\n\nResource List:\n  gibson.zeroroot.ai/v1alpha1/Tenant:\n    - primary\n  v1/Namespace:\n    - gibson\n    - tenant-primary\n    - velero\n%s' "$BACKUP" "${PLUGIN_NS_IN_BACKUP:+    - $PLUGIN_NS_IN_BACKUP
}"
    exit 0 ;;
  "get namespace tenant-primary") echo 'Error from server (NotFound): namespaces "tenant-primary" not found' >&2; exit 1 ;;
  "get namespace tenant-primary -o jsonpath={.metadata.labels.gibson\.zeroroot\.ai/managed-by}") printf 'tenant-operator'; exit 0 ;;
  *) echo "$args" >> "${UNDECLARED_LOG:-$STATE/undeclared.log}"; echo "kubectl stub: undeclared call: $args" >&2; exit 1 ;;
esac
SH
  chmod +x "$STUB_DIR"/*
}

recreate() { env "$@" bash "$RECREATE" "$SUBSTRATE"; }

applied() { cat "$STATE/applied.log" 2>/dev/null; }

# recovery_param — the value the gibson Application carries for
# platformPostgres.recovery.backupID, which is the one knob that decides
# whether Postgres comes up empty or recovers (ADR-0083).
recovery_param() { gibson_param platformPostgres.recovery.backupID; }

# gibson_param <name> — the value the gibson Application carries for one
# Helm parameter. Fails when the Application or the parameter is absent.
gibson_param() {
  python3 -c '
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "Application" or d["metadata"]["name"] != "gibson":
        continue
    for p in d["spec"]["source"]["helm"]["parameters"]:
        if p["name"] == sys.argv[2]:
            sys.stdout.write(str(p.get("value") or ""))
            sys.exit(0)
    sys.exit("the gibson Application carries no %s parameter" % sys.argv[2])
sys.exit("no gibson Application was applied")
' "$STATE/applied-raw.yaml" "$1"
}
restores() { applied | grep '^Restore/' || true; }

refute_cluster_touched() {
  if [ -f "$STATE/kind.log" ]; then
    echo "kind was called: $(cat "$STATE/kind.log")" >&2
    return 1
  fi
}

# ===========================================================================
# 1. A name that matches no backup fails BEFORE anything is destroyed
# ===========================================================================

@test "RESTORE_FROM naming no backup fails fast and names the object it looked for" {
  run recreate RESTORE_FROM=preserve-kind-19700101-000000 CLUSTER=restore-bats
  [ "$status" -ne 0 ]
  [[ "$output" == *"there is no backup named 'preserve-kind-19700101-000000'"* ]]
  [[ "$output" == *"s3://gibson-kind/backups/velero/backups/preserve-kind-19700101-000000/velero-backup.json"* ]]
  [[ "$output" == *"ADR-0083"* ]]
  # The whole point: the cluster it would have deleted is untouched.
  refute_cluster_touched
}

@test "a RESTORE_FROM that is not a backup name is refused before the bucket is read" {
  run recreate RESTORE_FROM="Preserve Kind; rm -rf /" CLUSTER=restore-bats
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a backup name"* ]]
  refute_cluster_touched
  [ ! -f "$STATE/aws.log" ]
}

@test "a backup with no CNPG record is refused: Postgres would come back empty" {
  arm_backup "$BACKUP" ""
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -ne 0 ]
  [[ "$output" == *"carries no CNPG Backup record"* ]]
  refute_cluster_touched
}

@test "FAILING FIXTURE: a backup that Velero did not complete is refused before anything is touched (review of hosted#798)" {
  BACKUP_PHASE_IN_BUCKET=PartiallyFailed arm_backup "$BACKUP" "20260101T000000"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -ne 0 ]
  [[ "$output" == *"backup '$BACKUP' is PartiallyFailed, not Completed"* ]] || { echo "$output"; false; }
  refute_cluster_touched
}

# ===========================================================================
# 2. No name means no restore, with a backup sitting in the bucket
# ===========================================================================

@test "a backup in the bucket and no RESTORE_FROM: zero Restores, nothing read under backups/" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate CLUSTER=restore-bats
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The fixture has to still be armed, or this proves nothing.
  [ -f "$STATE/bucket/backups/velero/backups/$BACKUP/velero-backup.json" ]
  [ -z "$(restores)" ]
  run grep -c 'backups/velero' "$STATE/aws.log"
  [ "$output" = "0" ]
  [[ "$output" != *"restore"* ]]
}

@test "a nameless recreate hands the umbrella an EMPTY Postgres recovery id" {
  # The parameter is always present, on one code path. Its VALUE is what
  # decides whether the database comes up empty, so that is what is asserted.
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  [[ "$output" == *"stores    bootstrapped empty"* ]]
  run recovery_param
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "the umbrella gets the setec disk registry that stage 0 names (D85)" {
  run recreate CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  run gibson_param gibson-workloads.setec.launcher.diskRepo
  [ "$status" -eq 0 ]
  [ "$output" = "127.0.0.1:5000/setec-disks" ]
}

@test "the umbrella gets the public key of the keyring disk seed (D85)" {
  run recreate CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  run gibson_param "gibson-workloads.setec.launcher.diskBuilder.publicKeys[0]"
  [ "$status" -eq 0 ]
  # RFC 8032 test vector 1: the fixture seed gives this key.
  [ "$output" = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=" ]
}

@test "FAILING FIXTURE: a substrate.env with no disk registry stops the recreate before the cluster" {
  sed -i '/^SETEC_DISK_REPO=/d' "$SUBSTRATE"
  run recreate CLUSTER=restore-bats
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no SETEC_DISK_REPO"* ]]
}

@test "a named recreate hands the umbrella the id read out of that backup" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  run recovery_param
  [ "$status" -eq 0 ]
  [ "$output" = "$BACKUP_ID" ]
}

# ===========================================================================
# 3. The restore runs, in one order, and only after ESO has synced
# ===========================================================================

@test "a named backup restores the secret store, then the built-ins, then the tenants" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(restores)" = "Restore/${BACKUP}-openbao
Restore/${BACKUP}-builtins
Restore/${BACKUP}-pods
Restore/${BACKUP}-statefulsets
Restore/${BACKUP}-tenants" ]
  # The secret store comes back BEFORE the umbrella exists.
  run python3 -c "
import sys
order = [l.strip() for l in open(sys.argv[1]) if l.strip()]
sys.exit(0 if order.index('Restore/$BACKUP-openbao') < order.index('Application/gibson') else 1)
" "$STATE/applied.log"
  [ "$status" -eq 0 ]
}

@test "every recreate archives Postgres under a NEW stamped name, never the Cluster name" {
  # The durable bucket outlives the cluster (ADR-0083) and CNPG refuses to
  # archive into a directory that already holds another cluster's WAL
  # (measured 2026-09-07: walArchivingFailing on a bucket with 38 segments
  # from earlier bringups). So the archive name is stamped per bootstrap.
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  run gibson_param platformPostgres.backup.serverName
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^platform-postgres-[0-9]{14}$ ]]
  [[ "$output" != "platform-postgres" ]]
  # And a nameless bringup names no source archive.
  run gibson_param platformPostgres.recovery.serverName
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "a named recreate reads the OLD archive from the backup record and writes a NEW one" {
  arm_backup "$BACKUP" "$BACKUP_ID" platform-postgres-20260907153730
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  [[ "$output" == *"in archive platform-postgres-20260907153730"* ]]
  run gibson_param platformPostgres.recovery.serverName
  [ "$output" = "platform-postgres-20260907153730" ]
  run gibson_param platformPostgres.backup.serverName
  [[ "$output" =~ ^platform-postgres-[0-9]{14}$ ]]
  [ "$output" != "platform-postgres-20260907153730" ]
}

@test "FAILING FIXTURE: a backup record with no archive name is refused, Postgres cannot be pointed at nothing" {
  arm_backup "$BACKUP" "$BACKUP_ID" ""
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no status.serverName"* ]]
  refute_cluster_touched
}

@test "the named backup's CNPG base backup id reaches the umbrella" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  [[ "$output" == *"postgres recovers from base backup $BACKUP_ID"* ]]
  [[ "$output" == *"stores    restored from backup $BACKUP"* ]]
}

@test "FAILING FIXTURE: a store that is not in the cluster yet is a wait, not a silent death" {
  # kubectl exits non-zero for an object that does not exist. Under set -e an
  # unguarded `x="$(kubectl ...)"` makes that the end of the verb, with the
  # reason in /dev/null: the recreate printed the wait line and stopped, and
  # nothing said why (measured 2026-09-03, deploy#1740, run 33699848618).
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats \
    STUB_STORE_MISSING=1 RESTORE_TIMEOUT=1
  [ "$status" -ne 0 ]
  # It reached the deadline and said so, instead of dying at the first poll.
  [[ "$output" == *"External Secrets did not sync within"* ]]
  [[ "$output" == *"Ready=<none>"* ]]
}

@test "FAILING FIXTURE: a PriorityClass the chart has not applied yet is a wait, then a loud stop, never a half-restore" {
  # Run 34242900639 (2026-09-08): the built-ins Restore carried the classes
  # itself, Velero's scoped role could not create them, and every pod that
  # named one was refused at admission with the Restore PartiallyFailed.
  # The classes are the chart's (wave -20); the verb waits for them and
  # never restores them.
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats \
    STUB_PC_MISSING=1 RESTORE_TIMEOUT=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"PriorityClass gibson-platform gibson-platform-critical tenant-neo4j did not appear"* ]]
  [ "$(restores)" = "Restore/${BACKUP}-openbao" ]
}

@test "no Restore the verb builds carries priorityclasses: they are chart-owned and Velero cannot create them" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run python3 -c '
import sys, yaml
seen = 0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "Restore":
        continue
    seen += 1
    if "priorityclasses" in (d["spec"].get("includedResources") or []):
        sys.exit("Restore %s carries priorityclasses" % d["metadata"]["name"])
sys.exit(0 if seen == 5 else "expected 5 Restores, saw %d" % seen)
' "$STATE/applied-raw.yaml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: External Secrets never syncs, so no data restore is attempted" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats \
    STUB_ES_READY=False RESTORE_TIMEOUT=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"External Secrets did not sync"* ]]
  [[ "$output" == *"CreateContainerConfigError"* ]]
  # The secret store restore ran. The two that would land pods did NOT.
  [ "$(restores)" = "Restore/${BACKUP}-openbao" ]
}

@test "FAILING FIXTURE: a Restore that never finishes names the pods that held it open" {
  # The deadline was the ONE exit from wait_restore that printed no
  # diagnosis, and it is the exit that fires. Five runs of the blocker 3 loop
  # on main ended `restore <name>-builtins did not finish within 2400s` with
  # nothing in the log naming a single stalled PodVolumeRestore or the pod
  # behind it (deploy#1740, runs 33705234668, 33705244337, 33705253441,
  # 33706634985 and 33720474418). A Restore stays InProgress until every
  # PodVolumeRestore reaches a terminal phase, and the node-agent starts one
  # only after the kubelet mounts the volume of the pod it names, so the pod
  # that cannot run is the whole answer.
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats \
    STUB_RESTORE_PHASE=InProgress STUB_STALLED_PVR=1 RESTORE_TIMEOUT=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not finish within 1s"* ]]
  # The counts the Restore itself recorded.
  [[ "$output" == *"PodVolumeRestores:"* ]]
  # The pod behind the PodVolumeRestore that never started, and WHY it is not
  # running.
  [[ "$output" == *"pods behind the PodVolumeRestores that never started"* ]]
  [[ "$output" == *"tenant-primary/tenant-primary-neo4j-0"* ]]
  [[ "$output" == *"CreateContainerConfigError"* ]]
  # And the restore's own log, which is where Velero writes the item it
  # skipped and never writes to the server pod's stdout.
  [[ "$output" == *"distinct errors in the restore log"* ]]
  [[ "$output" == *"distinct warnings in the restore log"* ]]
}

@test "FAILING FIXTURE: the secret store restore that moves no volume data is refused" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  # A Restore that reports Completed with no PodVolumeRestore behind it: the
  # kind hostPath failure, where the restored store is an EMPTY store wearing
  # the name of a restored one.
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats STUB_PVR=0
  [ "$status" -ne 0 ]
  [[ "$output" == *"moved NO volume data"* ]]
  [[ "$output" == *"defaultVolumeType=local"* ]]
  # The counts alone name nothing, so the refusal carries the restore's own
  # log: the warnings and errors Velero recorded, grouped by fault with the
  # namespace folded away (deploy#1740).
  [[ "$output" == *"0 distinct errors in the restore log"* ]]
  [[ "$output" == *"1 distinct warnings in the restore log"* ]]
  [[ "$output" == *"Skipping restore of resource because it already exists"* ]]
  [[ "$output" != *"Restoring item"* ]]
}

@test "FAILING FIXTURE: an error that comes once is shown, ahead of 45 warnings that also come once (drill run 39189378263)" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats STUB_PVR=0 STUB_MANY_WARNINGS=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 distinct errors in the restore log"* ]] || { echo "$output"; false; }
  [[ "$output" == *"error restoring pods/gibson/gibson-ext-authz-1"* ]] || { echo "$output"; false; }
}

# ===========================================================================
# 4. Every Restore the verb builds is one the shipped Velero CRD understands
# ===========================================================================
#
# THE FAILURE THIS EXISTS FOR. A Velero `Restore` has no scoped resource
# filters: `includedNamespaceScopedResources` and its three siblings are
# fields of a `Backup`. A CustomResourceDefinition PRUNES a field it does not
# declare, silently, so a Restore carrying one is accepted, stored without it,
# and restores everything the filter was there to keep out. Nothing fails, and
# the tenant records land before the volumes they have to adopt.
#
# So every field of every Restore this verb builds is checked against the
# Restore CRD that ships in helm/gibson-velero, by content. A velero bump that
# renames a field fails here.

restore_fields_ok() {
  python3 -c '
import glob, sys, tarfile, yaml

tgz = sorted(glob.glob(sys.argv[1] + "/helm/gibson-velero/charts/velero-*.tgz"))  # sys.argv[1] is CHARTS_ROOT
if not tgz:
    sys.exit("no vendored velero chart under %s/helm/gibson-velero/charts (run make chart-deps in zeroroot-ai/charts)" % sys.argv[1])
with tarfile.open(tgz[-1]) as tf:
    member = [m for m in tf.getnames() if m.endswith("crds/restores.yaml")][0]
    crd = yaml.safe_load(tf.extractfile(member).read())
known = set(crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]
            ["properties"]["spec"]["properties"])

seen = 0
for doc in yaml.safe_load_all(open(sys.argv[2])):
    if not doc or doc.get("kind") != "Restore":
        continue
    seen += 1
    unknown = sorted(set(doc.get("spec") or {}) - known)
    if unknown:
        sys.exit("Restore %s carries field(s) the shipped Velero CRD does not declare: %s.\n"
                 "The API server prunes them silently, so the restore does NOT filter.\n"
                 "The Restore CRD declares: %s"
                 % (doc["metadata"]["name"], ", ".join(unknown), ", ".join(sorted(known))))
if seen == 0:
    sys.exit("no Restore object was applied, so this check proves nothing")
print("OK  %d Restore(s), every field declared by the shipped Velero CRD" % seen)
' "$CHARTS" "$STATE/applied-raw.yaml"
}

@test "every Restore the verb builds uses fields the shipped Velero CRD declares" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  run restore_fields_ok
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"5 Restore(s)"* ]]
}

@test "a Restore that narrows to pods also names both volume kinds, or it moves no data" {
  # Velero creates NO PodVolumeRestore when a restore's resource filter leaves
  # out persistentvolumeclaims or persistentvolumes, and it says nothing about
  # it: the restore reports Completed with the pod restored and the volume
  # empty (measured on kind 2026-09-02, deploy#1740). A Restore that names
  # `pods` in includedResources must name both volume kinds as well.
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  python3 - "$STATE/applied-raw.yaml" <<'VOLKINDS'
import sys, yaml
bad = []
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "Restore":
        continue
    inc = (d.get("spec") or {}).get("includedResources") or []
    if "pods" not in inc:
        continue
    for want in ("persistentvolumeclaims", "persistentvolumes"):
        if want not in inc:
            bad.append("%s: includedResources names pods but not %s"
                       % (d["metadata"]["name"], want))
assert not bad, "; ".join(bad)
print("every pod-restoring Restore names both volume kinds")
VOLKINDS
}

@test "FAILING FIXTURE: no Restore creates a pod or a StatefulSet in a plugin namespace of the backup (hosted#8)" {
  # The chart policy gibson-tenant-plugin-workloads lets only
  # replicaset-controller create a Pod in tenant-<t>-plugins and lets no one
  # create a StatefulSet. A Restore that does not exclude the namespace ends
  # PartiallyFailed on a backup that holds a running catalog plugin.
  arm_backup "$BACKUP" "$BACKUP_ID"
  export PLUGIN_NS_IN_BACKUP="tenant-primary-plugins"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  python3 - "$STATE/applied-raw.yaml" <<'PLUGINNS'
import sys, yaml
seen = {}
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "Restore":
        continue
    spec = d.get("spec") or {}
    name = d["metadata"]["name"].rsplit("-", 1)[-1]
    inc = spec.get("includedNamespaces") or []
    if "tenant-primary-plugins" in inc:
        sys.exit("Restore %s includes the plugin namespace" % d["metadata"]["name"])
    seen[name] = spec.get("excludedNamespaces") or []
for need in ("builtins", "pods", "statefulsets"):
    assert need in seen, "no %s Restore was applied" % need
    assert "tenant-primary-plugins" in seen[need], (
        "the %s Restore does not exclude the plugin namespace: %s" % (need, seen[need]))
print("builtins, pods and statefulsets Restores exclude the plugin namespace")
PLUGINNS
  # The spec check comes first, so a red result names the real defect.
  [[ "$output" == *"plugin namespaces left to the tenant-operator: tenant-primary-plugins"* ]]
}

@test "a backup with no plugin namespace adds no plugin exclusion (hosted#8)" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"plugin namespaces left to the tenant-operator: none"* ]]
  run grep -q 'plugins$' "$STATE/applied-raw.yaml"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: a Restore carrying a Backup-only scoped filter is caught" {
  # includedNamespaceScopedResources is a Backup field. On a Restore the API
  # server drops it without a word and the restore filters nothing.
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  cat >> "$STATE/applied-raw.yaml" <<'YAML'
---
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: pruned-silently
  namespace: velero
spec:
  backupName: whatever
  includedNamespaceScopedResources: ["pods"]
YAML
  run restore_fields_ok
  [ "$status" -ne 0 ]
  [[ "$output" == *"includedNamespaceScopedResources"* ]]
  [[ "$output" == *"prunes them silently"* ]]
}

# ===========================================================================
# 5. The velero Application can actually reach Synced
# ===========================================================================
#
# THE FAILURE THIS EXISTS FOR. The Velero schedule controller REWRITES
# spec.skipImmediately to false as soon as it has honoured it: the field is a
# one-shot instruction, not desired state. The chart sets it true so the first
# backup waits for the first cron tick instead of racing the node-agent
# rollout. The rendered Schedule and the live Schedule therefore never agree,
# and without an ignoreDifferences entry the Application sits OutOfSync
# forever with no defect behind it — and the recreate waits for Synced, so it
# never returns. Measured on kind 2026-09-02.

@test "the velero Application ignores the field Velero's own controller rewrites" {
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate CLUSTER=restore-bats
  [ "$status" -eq 0 ]
  run python3 -c '
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "Application" or d["metadata"]["name"] != "velero":
        continue
    ignored = d["spec"].get("ignoreDifferences") or []
    for entry in ignored:
        if (entry.get("kind") == "Schedule"
                and "/spec/skipImmediately" in (entry.get("jsonPointers") or [])):
            opts = d["spec"]["syncPolicy"]["syncOptions"]
            if "RespectIgnoreDifferences=true" not in opts:
                sys.exit("the velero Application ignores /spec/skipImmediately but does not "
                         "carry RespectIgnoreDifferences=true, so every sync writes it back")
            print("OK  Schedule /spec/skipImmediately is ignored, and the sync respects it")
            sys.exit(0)
    sys.exit("the velero Application does not ignore Schedule /spec/skipImmediately. "
             "Velero rewrites that field, so the Application can never reach Synced and "
             "the recreate waits for it forever")
sys.exit("no velero Application was applied")
' "$STATE/applied-raw.yaml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "Argo decides ownership by annotation, so a copied label owns nothing" {
  # Argo's DEFAULT tracking method is `label`, and Velero copies a Schedule's
  # labels onto every Backup it creates from it. Under label tracking that
  # hands Argo ownership of the platform's backups, and `prune: true` deletes
  # them. The kind workspace therefore pins annotation tracking, whose
  # tracking id names the object holding it and is inert when copied.
  run python3 -c "
import re, sys
tf = open(sys.argv[1]).read()
m = re.search(r'\"application.resourceTrackingMethod\"\s*=\s*\"([a-z-]+)\"', tf)
if not m:
    sys.exit('kind/gibson/operators.tf does not set application.resourceTrackingMethod. '
             'Argo then tracks by label, and Velero copies the Schedule label onto every '
             'Backup, so Argo adopts and prunes the platform backups')
if m.group(1) != 'annotation':
    sys.exit('application.resourceTrackingMethod is %r, want annotation' % m.group(1))
print('OK  annotation tracking')
" "$REPO_ROOT/bootstrap/kind/gibson/operators.tf"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# ===========================================================================
# 6. The bucket prefix the restore reads is the one the chart writes
# ===========================================================================

@test "the prefix the restore looks in is helm/gibson-velero's own bucket.prefix" {
  chart="$(python3 -c "
import yaml
print((yaml.safe_load(open('$CHARTS/helm/gibson-velero/values.yaml'))['bucket']['prefix']))
")"
  script="$(grep -oE 'VELERO_BUCKET_PREFIX:-[^}]+' "$RECREATE" | head -n1 | cut -d: -f2- | tr -d '-')"
  [ "$chart" = "$script" ]
}



@test "the tenant records Restore carries the membership records, not the Tenant alone" {
  # Loop #19 (2026-09-09): every volume and Tenant came back, and the
  # first-admin hook then crashlooped creating a founding TenantMember the
  # restore had left behind. A TenantMember is data; the operator does not
  # re-derive it for a Tenant whose status is already Ready.
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run python3 -c '
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d or d.get("kind") != "Restore" or not d["metadata"]["name"].endswith("-tenants"):
        continue
    inc = d["spec"].get("includedResources") or []
    for want in ("tenants.gibson.zeroroot.ai", "tenantmembers.gibson.zeroroot.ai"):
        if want not in inc:
            sys.exit("the tenants Restore does not name %s: %s" % (want, inc))
    sys.exit(0)
sys.exit("no -tenants Restore was applied")
' "$STATE/applied-raw.yaml"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: a tenant-operator webhook with no ready endpoint is a wait, then a loud stop, never a PartiallyFailed tenants Restore" {
  # Run 34391927116 (2026-09-09): the operator was rolling when the tenant
  # records Restore ran, every Tenant and TenantMember failed admission on
  # "connection refused", and the Restore ended PartiallyFailed.
  arm_backup "$BACKUP" "$BACKUP_ID"
  run recreate RESTORE_FROM="$BACKUP" CLUSTER=restore-bats \
    STUB_WEBHOOK_DOWN=1 RESTORE_TIMEOUT=1
  [ "$status" -ne 0 ]
  [[ "$output" == *"tenant-operator webhook did not become ready"* ]]
  [[ "$output" == *"replicas/updated/available=2/1/1"* ]]
  # The secret store and the built-ins restored; the tenant records did NOT.
  [ "$(restores)" = "Restore/${BACKUP}-openbao
Restore/${BACKUP}-builtins
Restore/${BACKUP}-pods
Restore/${BACKUP}-statefulsets" ]
}
