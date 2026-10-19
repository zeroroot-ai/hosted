#!/usr/bin/env bats
#
# teardown-ec2.bats: the EC2 teardown runs MODE=preserve to its end, with
# only the inputs that `make teardown` gives it.
#
# WHY THIS SUITE EXISTS
# ---------------------
# scripts/lib/preserve-backup.sh reads VELERO_NS, SCHEDULE, CNPG_CLUSTER,
# BACKUP_TIMEOUT and VERIFY_TIMEOUT. teardown-kind.sh and teardown-aws.sh set
# them. teardown-ec2.sh did not, so under `set -u` the EC2 preserve teardown
# died at step 0 on an unbound variable, before it backed anything up. No
# test ran teardown-ec2.sh with MODE=preserve, so nothing saw it. The drill
# and staging both run on EC2.
#
# HOW IT IS OFFLINE
# -----------------
# The test copies scripts/ into a temporary tree. terraform, aws and kubectl
# are stubs on PATH. backup-verify.sh, test/dr/cnpg-backup-and-wait.sh and
# the post-destroy verify are stubs in the copy, because teardown.bats owns
# their behavior. Each stub records its arguments. The kubectl stub answers
# only the names this test declares. Any other name gets NotFound, the same
# answer a real cluster gives.
#
# Run:
#   bats tests/harness/teardown-ec2.bats
#
# It also measures two paths of the wipe that the drill runs first, on an
# account that is usually clean (hosted row 20):
#
#   * nothing to destroy is a result with a proof: an empty state and zero
#     tagged resources. A state that cannot be read, or a tagged survivor,
#     is a failure. The drill step used to read any failure as clean.
#   * a destroy that dies releases its own S3 state lock, and only its own.
#     The next teardown runs on another runner and could never take it.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

load "$BATS_TEST_DIRNAME/assert.bash"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$STUB_DIR" "$STATE" "$TREE/test/dr" "$TREE/bootstrap/ec2/gibson/scripts"
  PATH="$STUB_DIR:$PATH"
  export STATE

  cp -R "$REPO_ROOT/scripts" "$TREE/scripts"

  SUBSTRATE="$BATS_TEST_TMPDIR/substrate.env"
  printf 'SUBSTRATE_ENV=drill\nBUCKET_NAME=zeroroot-ai-drill-durable-000000000000\nEDGE_CERT_SECRET=zeroroot-ai/drill/edge-tls\n' > "$SUBSTRATE"

  # The forward binds this port. A free high port keeps the suite off a
  # forward that the host may run on 6443.
  export API_LOCAL_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  export KUBECONFIG_PATH="$BATS_TEST_TMPDIR/drill.kubeconfig"
  export STUB_BACKUP_PHASE=Completed
  # The Velero queue. STUB_BSL is the phase of the BackupStorageLocation.
  # STUB_IN_FLIGHT is a backup still running ahead of the preserve backup, for
  # the first STUB_IN_FLIGHT_POLLS lists. STUB_QUEUED_POLLS is how many reads
  # of the preserve backup answer Queued before STUB_BACKUP_PHASE.
  export STUB_BSL=Available STUB_IN_FLIGHT="" STUB_IN_FLIGHT_POLLS=0 STUB_QUEUED_POLLS=0
  export VELERO_QUEUE_POLL=0
  # Stub knobs. Each test flips one.
  export STUB_STATE=instance        # instance | empty | leftover | unreadable
  export STUB_DESTROY_FAIL=""       # non-empty: the destroy dies and leaves its lock
  export STUB_LOCK_WHO=""           # who holds the S3 state lockfile, "" = none
  export STUB_LOCK_CREATED=""       # "" = the moment the destroy died
  export STUB_VERIFY_RC=0           # the post-destroy verify exit code

  # Make sure that no preserve input comes from the environment of the host.
  unset VELERO_NS SCHEDULE CNPG_CLUSTER BACKUP_TIMEOUT VERIFY_TIMEOUT NS

  write_stubs
}

write_stubs() {
  # backup-verify.sh and cnpg-backup-and-wait.sh: record the argv. An empty
  # argument is a variable that the caller did not set, so it fails.
  for f in "$TREE/scripts/backup-verify.sh" "$TREE/test/dr/cnpg-backup-and-wait.sh"; do
    cat > "$f" <<'SH'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$STATE/steps.log"
for a in "$@"; do [ -n "$a" ] || { echo "$(basename "$0"): an empty argument" >&2; exit 3; }; done
exit 0
SH
    chmod +x "$f"
  done
  cat > "$TREE/bootstrap/ec2/gibson/scripts/ec2-post-destroy-verify.sh" <<'SH'
#!/usr/bin/env bash
echo "post-destroy-verify $*" >> "$STATE/steps.log"
exit "${STUB_VERIFY_RC:-0}"
SH
  chmod +x "$TREE/bootstrap/ec2/gibson/scripts/ec2-post-destroy-verify.sh"

  cat > "$STUB_DIR/terraform" <<'SH'
#!/usr/bin/env bash
echo "terraform $*" >> "$STATE/terraform.log"
case "$*" in
  *"output -raw instance_id"*)
    [ "$STUB_STATE" = instance ] || { echo "Error: Output \"instance_id\" not found" >&2; exit 1; }
    printf 'i-0drillbats00000001'; exit 0 ;;
  *" destroy "*|*" destroy")
    if [ -n "${STUB_DESTROY_FAIL:-}" ]; then
      date -u +%Y-%m-%dT%H:%M:%S.%NZ > "$STATE/lock-created"
      echo "Error: ${STUB_DESTROY_FAIL}" >&2; exit 1
    fi
    touch "$STATE/destroyed"; exit 0 ;;
  *"state list"*)
    [ -f "$STATE/destroyed" ] && exit 0
    case "$STUB_STATE" in
      instance) echo "aws_instance.node" ;;
      leftover) echo "aws_vpc.this"; echo "aws_subnet.public" ;;
      unreadable) echo "Error: Failed to load state: AccessDenied" >&2; exit 1 ;;
    esac
    exit 0 ;;
  *"force-unlock -force "*) exit 0 ;;
  *" init "*) exit 0 ;;
esac
echo "terraform stub: no answer for: $*" >&2
exit 1
SH

  cat > "$STUB_DIR/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$STATE/aws.log"
case "$*" in
  "secretsmanager put-secret-value --secret-id zeroroot-ai/drill/edge-tls --secret-string file://"*)
    f="${*: -1}"; cp "${f#file://}" "$STATE/edge-stored.json"; exit 0 ;;
  *"sts get-caller-identity"*) echo "000000000000"; exit 0 ;;
  *"ssm send-command"*"--instance-ids i-0drillbats00000001 "*) echo "cmd-bats-1"; exit 0 ;;
  *"ssm get-command-invocation --command-id cmd-bats-1 --instance-id i-0drillbats00000001"*"--query Status"*) echo "Success"; exit 0 ;;
  *"ssm get-command-invocation --command-id cmd-bats-1 --instance-id i-0drillbats00000001"*"StandardOutputContent"*)
    printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://10.60.1.10:6443\n  name: default\n'; exit 0 ;;
  *"ssm start-session --target i-0drillbats00000001 "*) exit 0 ;;
  "s3api get-object --bucket zeroroot-ai-drill-durable-000000000000 --key tfstate/ec2-gibson/terraform.tfstate.tflock --region us-east-1 "*)
    [ -n "${STUB_LOCK_WHO:-}" ] || { echo "An error occurred (NoSuchKey)" >&2; exit 254; }
    out="${*: -1}"
    created="${STUB_LOCK_CREATED:-$(cat "$STATE/lock-created" 2>/dev/null || true)}"
    printf '{"ID":"deadbeef-0000-0000-0000-000000000000","Operation":"OperationTypeApply","Who":"%s","Created":"%s"}' \
      "$STUB_LOCK_WHO" "$created" > "$out"
    exit 0 ;;
esac
echo "aws stub: no answer for: $*" >&2
exit 255
SH

  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
args="$*"
echo "kubectl $args" >> "$STATE/kubectl.log"
case "$args" in
  "cluster-info") exit 0 ;;
  "apply -f -") cat > /dev/null; exit 0 ;;
  "-n velero get schedule.velero.io/platform-hourly -o json")
    cat <<'JSON'
{"metadata":{"name":"platform-hourly","namespace":"velero"},
 "spec":{"schedule":"0 * * * *","template":{
   "includedNamespaces":["gibson","tenant-*"],
   "includedNamespaceScopedResources":["*"],
   "excludedNamespaceScopedResources":["secrets","*.generators.external-secrets.io"],
   "includedClusterScopedResources":["tenants.gibson.zeroroot.ai"],
   "defaultVolumesToFsBackup":true,"storageLocation":"default","ttl":"4320h0m0s"}}}
JSON
    exit 0 ;;
  "-n velero get backup.velero.io/preserve-drill-"*" -o jsonpath={.status.phase}")
    n=$(( $(cat "$STATE/phase-reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/phase-reads"
    if [ "$n" -le "${STUB_QUEUED_POLLS:-0}" ]; then printf Queued; else printf '%s' "$STUB_BACKUP_PHASE"; fi
    exit 0 ;;
  "-n velero get backupstoragelocation.velero.io/default -o jsonpath={.status.phase}|{.status.lastValidationTime}|{.status.message}")
    printf '%s|2026-10-14T11:13:47Z|%s' "$STUB_BSL" "${STUB_BSL_MSG:-}"; exit 0 ;;
  "-n velero get backups.velero.io -o jsonpath={range .items[*]}{.metadata.name}{\" \"}{.status.phase}{\"\\n\"}{end}")
    n=$(( $(cat "$STATE/list-reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/list-reads"
    echo "platform-hourly-20261013230035 Completed"
    if [ -n "$STUB_IN_FLIGHT" ] && { [ "$n" -le "$STUB_IN_FLIGHT_POLLS" ] || [ "$STUB_IN_FLIGHT_POLLS" = always ]; }; then
      echo "$STUB_IN_FLIGHT"
    fi
    exit 0 ;;
  # The tenant deletes in flight (hosted run 39072863923). STUB_TENANT_DELETING
  # names a Tenant that is being deleted, and its namespace is Terminating,
  # for STUB_TENANT_DELETING_POLLS reads (or always).
  "get tenants.gibson.zeroroot.ai -o jsonpath={range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{\"\\n\"}{end}")
    [ -z "${STUB_TENANTS_BROKEN:-}" ] || { echo "error: the server doesn't have a resource type \"tenants\"" >&2; exit 1; }
    n=$(( $(cat "$STATE/tenant-reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/tenant-reads"
    if [ -n "${STUB_TENANT_DELETING:-}" ] && { [ "${STUB_TENANT_DELETING_POLLS:-}" = always ] || [ "$n" -le "${STUB_TENANT_DELETING_POLLS:-0}" ]; }; then
      echo "$STUB_TENANT_DELETING"
    fi
    exit 0 ;;
  "get namespaces -o jsonpath={range .items[?(@.status.phase==\"Terminating\")]}{.metadata.name}{\"\\n\"}{end}")
    n="$(cat "$STATE/tenant-reads" 2>/dev/null || echo 0)"
    if [ -n "${STUB_TENANT_DELETING:-}" ] && { [ "${STUB_TENANT_DELETING_POLLS:-}" = always ] || [ "$n" -le "${STUB_TENANT_DELETING_POLLS:-0}" ]; }; then
      echo "tenant-${STUB_TENANT_DELETING}"
    fi
    exit 0 ;;
  "-n velero get podvolumebackups.velero.io -o custom-columns="*)
    printf 'BACKUP POD VOLUME PHASE STARTED\nplatform-hourly-20261014000035 neo4j-0 data InProgress 2026-10-14T00:11:02Z\n'; exit 0 ;;
  "-n velero logs deploy/velero --tail=40")
    echo 'level=info msg="Backup is queued" backup=velero/preserve-drill-x'; exit 0 ;;
  "-n argocd get applications.argoproj.io -o name") exit 0 ;;
  # The edge Secret (scripts/lib/edge-cert.sh). STUB_EDGE: absent (NotFound,
  # the default), present, or unreachable.
  "-n gibson get secret gibson-envoy-tls -o json")
    case "${STUB_EDGE:-absent}" in
      present) printf '%s' '{"metadata":{"annotations":{"cert-manager.io/certificate-name":"gibson-envoy-edge"}},"data":{"tls.crt":"Y3J0","tls.key":"a2V5"}}'; exit 0 ;;
      unreachable) echo "Unable to connect to the server: dial tcp 127.0.0.1:6443: connect: connection refused" >&2; exit 1 ;;
    esac ;;
esac
echo "Error from server (NotFound): kubectl stub: no object for: $args" >&2
exit 1
SH
  chmod +x "$STUB_DIR/terraform" "$STUB_DIR/aws" "$STUB_DIR/kubectl"
}

@test "FAILING FIXTURE (hosted row 2): MODE=preserve on EC2 with no preserve input set runs to the destroy and prints the backup name" {
  run env MODE=preserve "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  refute_output_has "unbound variable"
  assert_output_has "RESTORE_FROM=preserve-drill-"
  # Each step got the shared default, not an empty string.
  grep -q -- "backup-verify.sh record .*--velero-namespace velero --timeout 600" "$STATE/steps.log"
  grep -q -- "cnpg-backup-and-wait.sh --namespace gibson --cluster platform-postgres --name preserve-drill-.* --timeout 1800" "$STATE/steps.log"
  grep -q -- "backup-verify.sh verify .*--cnpg-cluster platform-postgres --timeout 600" "$STATE/steps.log"
  [ -f "$STATE/destroyed" ]
}

@test "a value the caller sets wins over the shared default" {
  run env MODE=preserve VERIFY_TIMEOUT=77 "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -q -- "backup-verify.sh record .*--timeout 77" "$STATE/steps.log"
}

@test "FAILING FIXTURE: a PartiallyFailed backup on EC2 stops before the destroy" {
  export STUB_BACKUP_PHASE=PartiallyFailed
  run env MODE=preserve "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ]
  assert_output_has "PartiallyFailed"
  [ ! -f "$STATE/destroyed" ]
}

# ---------------------------------------------------------------------------
# Row 20: nothing to destroy, with a proof.
# ---------------------------------------------------------------------------
@test "FAILING FIXTURE (row 20): a clean account is nothing to destroy, with the account check as the proof" {
  export STUB_STATE=empty
  run env MODE=wipe "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_output_has "nothing to destroy"
  grep -q -x "post-destroy-verify drill" "$STATE/steps.log"
  ! grep -q ' destroy ' "$STATE/terraform.log"
}

@test "FAILING FIXTURE (row 20): an empty state with a tagged survivor in the account is a failure, not a clean account" {
  export STUB_STATE=empty STUB_VERIFY_RC=1
  run env MODE=wipe "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ]
  refute_output_has "nothing to destroy."
  assert_output_has "Environment=drill"
}

@test "FAILING FIXTURE (row 20): a state that cannot be read is a failure, never an empty estate" {
  export STUB_STATE=unreadable
  run env MODE=wipe "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ]
  assert_output_has "AccessDenied"
  [ ! -f "$STATE/steps.log" ] || ! grep -q post-destroy-verify "$STATE/steps.log"
}

@test "a leftover state with no instance is destroyed, then checked against the account" {
  export STUB_STATE=leftover
  run env MODE=wipe "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -q ' destroy ' "$STATE/terraform.log"
  grep -q -x "post-destroy-verify drill" "$STATE/steps.log"
  refute_output_has "nothing to destroy"
}

@test "the drill workflow runs the from-zero wipe with no mask on its exit" {
  run python3 - "$REPO_ROOT/.github/workflows/drill.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["up"]["steps"]
s = [s for s in steps if str(s.get("name", "")).startswith("From zero")]
assert len(s) == 1, s
run = s[0]["run"].strip()
assert run == 'make teardown ENV="${ENV}" MODE=wipe', run
assert not s[0].get("continue-on-error"), s[0]
PY
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Row 20: the stale state lock, through lib/tf-state-lock.sh.
# ---------------------------------------------------------------------------
@test "FAILING FIXTURE (row 20): a destroy that dies releases the state lock it left" {
  export STUB_DESTROY_FAIL="context deadline exceeded"
  export STUB_LOCK_WHO="$(whoami)@$(hostname)"
  run env MODE=wipe "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ]
  grep -q 'force-unlock -force deadbeef-0000-0000-0000-000000000000' "$STATE/terraform.log"
  assert_output_has "releasing the state lock our own attempt left behind"
}

@test "FAILING FIXTURE: a lock held by someone else is never force-unlocked" {
  export STUB_DESTROY_FAIL="context deadline exceeded"
  export STUB_LOCK_WHO="someone-else@their-laptop"
  run env MODE=wipe "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ]
  ! grep -q 'force-unlock' "$STATE/terraform.log"
  assert_output_has "held by someone else"
}

@test "FAILING FIXTURE: a lock that predates this teardown is never force-unlocked" {
  export STUB_DESTROY_FAIL="context deadline exceeded"
  export STUB_LOCK_WHO="$(whoami)@$(hostname)"
  export STUB_LOCK_CREATED="2001-01-01T00:00:00Z"
  run env MODE=wipe "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ]
  ! grep -q 'force-unlock' "$STATE/terraform.log"
  assert_output_has "predates this teardown"
}

# ---------------------------------------------------------------------------
# The edge certificate is kept for the next bringup (row 9 of the drill path
# audit, scripts/lib/edge-cert.sh).
# ---------------------------------------------------------------------------
@test "a preserve teardown keeps the edge certificate before the destroy" {
  export STUB_EDGE=present
  run env MODE=preserve "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(jq -r '."tls.key"' "$STATE/edge-stored.json")" = "a2V5" ]
  [ -f "$STATE/destroyed" ]
}

@test "FAILING FIXTURE: a preserve teardown that cannot read the edge Secret stops before the destroy" {
  export STUB_EDGE=unreachable
  run env MODE=preserve "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ]
  assert_output_has "so the edge certificate is not kept"
  [ ! -f "$STATE/destroyed" ]
}

@test "a wipe that cannot read the edge Secret still destroys, and says so" {
  export STUB_EDGE=unreachable
  run env MODE=wipe "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  assert_output_has "the edge certificate was not kept"
  [ -f "$STATE/destroyed" ]
}

# ---------------------------------------------------------------------------
# The Velero queue (drill 38484872614: the preserve backup sat Queued for
# 1800 s behind the first hourly backup of a fresh cluster)
# ---------------------------------------------------------------------------

@test "FAILING FIXTURE: a BackupStorageLocation that is not Available stops the preserve before any backup is made" {
  export STUB_BSL=Unavailable STUB_BSL_MSG="BackupStorageLocation default is unavailable: AccessDenied"
  run env MODE=preserve "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  assert_output_has "BackupStorageLocation velero/default is not Available (phase|last validation|message: Unavailable|2026-10-14T11:13:47Z|BackupStorageLocation default is unavailable: AccessDenied)"
  [ "$(grep -c '^kubectl apply -f -$' "$STATE/kubectl.log")" = 0 ] || { cat "$STATE/kubectl.log"; false; }
  [ ! -f "$STATE/destroyed" ]
}

@test "a backup in flight is waited for, named, and then the preserve backup runs" {
  export STUB_IN_FLIGHT="platform-hourly-20261014000035 InProgress" STUB_IN_FLIGHT_POLLS=3 STUB_QUEUED_POLLS=2
  run env MODE=preserve "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_has "waiting for the backups and the tenant deletes already in flight, which cover the same namespaces:"
  assert_output_has "platform-hourly-20261014000035 InProgress"
  assert_output_has "phase=Queued"
  assert_output_has "preserve Velero backup: waited "
  assert_output_has "s for the queue, ran "
  [ -f "$STATE/destroyed" ]
}

@test "a tenant delete in flight is waited for, named, and then the preserve backup runs" {
  export STUB_TENANT_DELETING=smoke-75408 STUB_TENANT_DELETING_POLLS=2 VELERO_QUEUE_POLL=0
  run env MODE=preserve "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_has "Tenant smoke-75408 deleting"
  assert_output_has "namespace tenant-smoke-75408 Terminating"
  [ -f "$STATE/destroyed" ]
}

@test "FAILING FIXTURE: a Tenant list that cannot be read stops the preserve before its backup" {
  export STUB_TENANTS_BROKEN=1
  run env MODE=preserve "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  assert_output_has "cannot list the Tenants and the namespaces"
  [ "$(grep -c '^kubectl apply -f -$' "$STATE/kubectl.log")" = 0 ] || { cat "$STATE/kubectl.log"; false; }
  [ ! -f "$STATE/destroyed" ]
}

@test "FAILING FIXTURE: a tenant delete that does not end stops the preserve before its backup" {
  export STUB_TENANT_DELETING=smoke-75408 STUB_TENANT_DELETING_POLLS=always VELERO_QUEUE_POLL=1
  run env MODE=preserve QUEUE_TIMEOUT=2 "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  assert_output_has "Tenant smoke-75408 deleting"
  assert_output_has "still waiting for: Tenant smoke-75408 deleting;namespace tenant-smoke-75408 Terminating"
  [ "$(grep -c '^kubectl apply -f -$' "$STATE/kubectl.log")" = 0 ] || { cat "$STATE/kubectl.log"; false; }
  [ ! -f "$STATE/destroyed" ]
}

@test "FAILING FIXTURE: a backup in flight past QUEUE_TIMEOUT stops the preserve and shows the queue" {
  export STUB_IN_FLIGHT="platform-hourly-20261014000035 InProgress" STUB_IN_FLIGHT_POLLS=always VELERO_QUEUE_POLL=1
  run env MODE=preserve QUEUE_TIMEOUT=2 "$TREE/scripts/teardown-ec2.sh" "$SUBSTRATE" drill
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  assert_output_has "the Velero backups and the tenant deletes in flight did not finish within 2s (QUEUE_TIMEOUT), still waiting for: platform-hourly-20261014000035 InProgress"
  assert_output_has "platform-hourly-20261014000035 neo4j-0 data InProgress"
  assert_output_has 'msg="Backup is queued"'
  [ "$(grep -c '^kubectl apply -f -$' "$STATE/kubectl.log")" = 0 ] || { cat "$STATE/kubectl.log"; false; }
  [ ! -f "$STATE/destroyed" ]
}

