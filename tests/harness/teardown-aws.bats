#!/usr/bin/env bats
#
# teardown-aws.bats — proves the AWS teardown verb FAILS CLOSED, and proves
# the destroy retry is bounded and conditional (deploy#1746, ADR-0083,
# ADR-0070).
#
# WHY THIS SUITE EXISTS
# ---------------------
# The AWS teardown is the one verb that can leave a cluster half-destroyed and
# STILL BILLING. Four ways it can go quietly wrong, and a fixture each:
#
#   1. A retryable failure treated as fatal. An EC2 API throttle
#      (deploy#1126) or a blocked admission webhook (deploy#1592) leaves a
#      half-destroyed, still-billing cluster if the destroy gives up on it.
#      Both classes retry ONCE, and the webhook sweep runs again first —
#      without that the retry hits the same wall, because nothing that could
#      answer the webhook still exists.
#   2. A non-retryable failure retried anyway. Retrying a real error twice
#      wastes forty minutes and hides the cause.
#   3. An unbounded retry. A destroy that fails twice is a defect to
#      diagnose, not a flake to paper over, so the second failure is fatal.
#   4. A green run over a still-billing account. The post-destroy
#      verification is fail-closed (deploy#1393): if it fails, the teardown
#      fails, whatever terraform said.
#
# The preserve half is scripts/lib/preserve-backup.sh, the SAME code ENV=kind
# runs, and tests/harness/teardown.bats already measures every one of its
# abort paths against the same stubs. This suite tests what is NEW here: the
# destroy, its retry, and the cluster-identity refusal that replaces the kind
# context check.
#
# HOW IT IS OFFLINE
# ----------------
# `terraform`, `aws`, `kubectl` and the two bootstrap/eks/gibson destroy scripts are
# stubbed on PATH and record every call. Nothing reaches AWS.
#
# Run:
#   bats tests/harness/teardown-aws.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
TEARDOWN="$REPO_ROOT/scripts/teardown-aws.sh"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR" "$STATE"
  PATH="$STUB_DIR:$PATH"
  export STATE

  KEYRING="$BATS_TEST_TMPDIR/keyring.env"
  SUBSTRATE="$BATS_TEST_TMPDIR/substrate.env"
  cat > "$KEYRING" <<EOF
OPENBAO_SEAL_KEY=c2VhbC1rZXktZm9yLXRoZS10ZWFyZG93bi1iYXRzLXN1aQ==
VELERO_REPO_PASSWORD=dmVsZXJvLXJlcG8tcGFzc3dvcmQtZm9yLXRoZS1iYXRzLXM=
BUCKET_ACCESS_KEY=AKIAEXAMPLEBATS00000
BUCKET_SECRET_KEY=YnVja2V0LXNlY3JldC1rZXktZm9yLWJhdHMtc3Vp
EOF
  cat > "$SUBSTRATE" <<EOF
SUBSTRATE_ENV=staging
BUCKET_ENDPOINT=https://s3.us-east-1.amazonaws.com
BUCKET_REGION=us-east-1
BUCKET_NAME=zeroroot-ai-staging-durable-000000000000
KEYRING_FILE=$KEYRING
ZONE_NAME=staging.zeroroot.ai
ZONE_ID=Z0BATSSTAGINGZONE
ZONE_NAMESERVER=ns-1.awsdns-00.org
APEX_ZONE_NAME=zeroroot.ai
APEX_ZONE_NAMESERVER=ns-2.awsdns-00.org
EOF

  # Stub knobs. Each test flips exactly one.
  export STUB_DESTROY_1_FAIL=""     # text the first destroy fails with
  export STUB_DESTROY_2_FAIL=""     # text the retry fails with
  export STUB_VERIFY_RC=0           # post-destroy verification exit code
  # What the env sub-zone holds. "own" = nothing but its NS and SOA;
  # "residue" = those plus the A/AAAA the dead edge left behind.
  export STUB_ZONE_CONTENT=residue
  export RETRY_DELAY=0              # the retry wait, so the suite is offline AND fast
  export STUB_EKS_ENDPOINT="https://ABCDEF.gr7.us-east-1.eks.amazonaws.com"
  export STUB_LIVE_SERVER="$STUB_EKS_ENDPOINT"
  export STUB_LOCK_WHO=""           # who holds the S3 state lockfile, "" = none
  # When the lock was taken, RFC3339Nano, the format the lockfile writes
  # (statemgr.LockInfo.Created is a time.Time). "" = the moment the first
  # destroy died, which is what a lock our own dead attempt left says.
  export STUB_LOCK_CREATED=""
  write_stubs
}

write_stubs() {
  cat > "$STUB_DIR/terraform" <<'SH'
#!/usr/bin/env bash
echo "terraform $*" >> "$STATE/terraform.log"
for a in "$@"; do
  if [ "$a" = destroy ]; then
    n=$(( $(grep -c ' destroy' "$STATE/terraform.log") ))
    if [ "$n" = 1 ] && [ -n "${STUB_DESTROY_1_FAIL:-}" ]; then
      # The dying attempt leaves its lockfile, stamped when it died. The
      # verb has already recorded its own start, so this is never earlier.
      date -u +%Y-%m-%dT%H:%M:%S.%NZ > "$STATE/lock-created"
      echo "Error: ${STUB_DESTROY_1_FAIL}" >&2
      echo "Error: ${STUB_DESTROY_1_FAIL}"
      exit 1
    fi
    if [ "$n" = 2 ] && [ -n "${STUB_DESTROY_2_FAIL:-}" ]; then
      echo "Error: ${STUB_DESTROY_2_FAIL}"
      exit 1
    fi
    echo "Destroy complete! Resources: 42 destroyed."
    exit 0
  fi
done
exit 0
SH

  cat > "$STUB_DIR/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$STATE/aws.log"
case "$*" in
  *"sts get-caller-identity"*) echo "000000000000"; exit 0 ;;
  *"eks describe-cluster"*)    printf '%s' "${STUB_EKS_ENDPOINT}"; exit 0 ;;
  *"route53 list-resource-record-sets"*)
    case "${STUB_ZONE_CONTENT:-own}" in
      own) cat <<'JSON'
{"ResourceRecordSets":[
 {"Name":"staging.zeroroot.ai.","Type":"NS","TTL":172800,"ResourceRecords":[{"Value":"ns-1.awsdns-00.org."}]},
 {"Name":"staging.zeroroot.ai.","Type":"SOA","TTL":900,"ResourceRecords":[{"Value":"ns-1.awsdns-00.org. a.b. 1 7200 900 1209600 86400"}]}
]}
JSON
      ;;
      *) cat <<'JSON'
{"ResourceRecordSets":[
 {"Name":"staging.zeroroot.ai.","Type":"NS","TTL":172800,"ResourceRecords":[{"Value":"ns-1.awsdns-00.org."}]},
 {"Name":"staging.zeroroot.ai.","Type":"SOA","TTL":900,"ResourceRecords":[{"Value":"ns-1.awsdns-00.org. a.b. 1 7200 900 1209600 86400"}]},
 {"Name":"staging.zeroroot.ai.","Type":"A","AliasTarget":{"HostedZoneId":"Z1","DNSName":"k8s-gibson-gibsonen-920c6946b9-9fb2b74a61f759f0.elb.us-east-1.amazonaws.com.","EvaluateTargetHealth":true}},
 {"Name":"staging.zeroroot.ai.","Type":"AAAA","AliasTarget":{"HostedZoneId":"Z1","DNSName":"k8s-gibson-gibsonen-920c6946b9-9fb2b74a61f759f0.elb.us-east-1.amazonaws.com.","EvaluateTargetHealth":true}},
 {"Name":"extdns-app.staging.zeroroot.ai.","Type":"TXT","TTL":300,"ResourceRecords":[{"Value":"\"heritage=external-dns\""}]}
]}
JSON
      ;;
    esac
    exit 0 ;;
  *"s3api get-object"*)
    # The backend's native S3 lockfile. Absent unless a test plants one.
    [ -n "${STUB_LOCK_WHO:-}" ] || exit 1
    # get-object writes the BODY to the outfile (the last argument) and its
    # own metadata to stdout. The real CLI does this, so the stub must too.
    for outfile in "$@"; do :; done
    created="${STUB_LOCK_CREATED:-$(cat "$STATE/lock-created" 2>/dev/null || true)}"
    printf '{"ID":"deadbeef-0000-0000-0000-000000000000","Operation":"OperationTypeApply","Info":"","Who":"%s","Version":"1.15.8","Created":"%s","Path":"tfstate/eks/gibson/terraform.tfstate"}' \
      "$STUB_LOCK_WHO" "$created" > "$outfile"
    echo '{"ContentLength":123,"ContentType":"binary/octet-stream"}'
    exit 0 ;;
esac
exit 0
SH

  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
echo "kubectl $*" >> "$STATE/kubectl.log"
case "$*" in
  *"cluster-info"*) exit 0 ;;
  *"config view"*)  printf '%s' "${STUB_LIVE_SERVER}"; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
exit 0
SH

  # The two bootstrap/eks/gibson scripts the destroy shells out to, and the sweep the
  # retry re-runs. `bash <path>` and `( cd … && bash scripts/… )` both reach
  # the real files, so they are shadowed by copying stubs over a scratch
  # bootstrap/eks/gibson tree the test points the script at.
  chmod +x "$STUB_DIR"/*
}

# run_teardown <mode> — the verb, against a scratch bootstrap/eks/gibson whose three
# scripts are stubs. REPO is faked by copying the script into a tree that has
# the stub bootstrap/eks/gibson beside it.
run_teardown() {
  local mode="$1"
  FAKE="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FAKE/scripts/lib" "$FAKE/bootstrap/eks/gibson/scripts" "$FAKE/test/dr"
  cp "$REPO_ROOT/scripts/teardown-aws.sh" "$FAKE/scripts/"
  cp "$REPO_ROOT/scripts/lib/preserve-backup.sh" "$FAKE/scripts/lib/"
  cp "$REPO_ROOT/scripts/lib/tf-state-lock.sh" "$FAKE/scripts/lib/"
  for s in eks-pre-destroy.sh eks-post-destroy-verify.sh eks-sweep-admission-webhooks.sh; do
    cat > "$FAKE/bootstrap/eks/gibson/scripts/$s" <<SH
#!/usr/bin/env bash
echo "$s \$*" >> "\$STATE/eks.log"
case "$s" in
  eks-post-destroy-verify.sh) exit \${STUB_VERIFY_RC:-0} ;;
esac
exit 0
SH
    chmod +x "$FAKE/bootstrap/eks/gibson/scripts/$s"
  done
  mkdir -p "$FAKE/bootstrap/eks/gibson/envs" && : > "$FAKE/bootstrap/eks/gibson/envs/staging.tfvars"
  MODE="$mode" run "$FAKE/scripts/teardown-aws.sh" "$SUBSTRATE" staging
}

# A missing log file means zero calls, not an empty string: `grep -c` on a
# file that does not exist prints nothing, and an empty count silently passes
# an equality test against anything.
count_in() { [ -f "$1" ] || { echo 0; return; }; grep -c "$2" "$1" || true; }
destroys() { count_in "$STATE/terraform.log" ' destroy'; }
sweeps()   { count_in "$STATE/eks.log" 'eks-sweep-admission-webhooks.sh'; }
# The retry re-runs the WHOLE pre-destroy sweep, not just the webhook half: a
# failed destroy leaves pods stuck Terminating that the first run never saw
# (deploy#1746). Two pre-destroy runs means the retry swept properly.
predestroys() { count_in "$STATE/eks.log" 'eks-pre-destroy.sh'; }

@test "the script refuses an unset MODE, so no other caller can slip one past" {
  run env -u MODE "$TEARDOWN" "$SUBSTRATE" staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"MODE=wipe or MODE=preserve"* ]]
}

@test "the script refuses an unknown MODE" {
  MODE=nearly run "$TEARDOWN" "$SUBSTRATE" staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"MODE is required and has no default"* ]]
}

@test "the script refuses to run without an env name" {
  MODE=wipe run "$TEARDOWN" "$SUBSTRATE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: teardown-aws.sh"* ]]
}

@test "MODE=wipe sweeps, destroys, verifies, and never touches the durable bucket" {
  run_teardown wipe
  [ "$status" -eq 0 ]
  [ "$(destroys)" = 1 ]
  grep -q 'eks-pre-destroy.sh' "$STATE/eks.log"
  grep -q 'eks-post-destroy-verify.sh' "$STATE/eks.log"
  # Retention is the bucket lifecycle rule and nothing else (ADR-0083): a
  # wipe makes no s3 call of its own.
  ! grep -q ' s3 ' "$STATE/aws.log"
  [[ "$output" == *"Nothing was kept"* ]]
}

@test "the pre-destroy sweep runs BEFORE terraform destroy, never after" {
  run_teardown wipe
  [ "$status" -eq 0 ]
  # The sweep is the first destructive step: its log line exists before the
  # destroy is issued, which is what stops the webhook deadlock (deploy#1592).
  first_sweep="$(grep -n 'eks-pre-destroy.sh' "$STATE/eks.log" | head -n1 | cut -d: -f1)"
  [ -n "$first_sweep" ]
  [ "$first_sweep" = 1 ]
}

@test "a retryable EC2 throttle re-runs the FULL sweep and retries the destroy ONCE" {
  export STUB_DESTROY_1_FAIL="waiting for EKS Node Group delete: unexpected state 'DELETE_FAILED': Request limit exceeded"
  run_teardown wipe
  [ "$status" -eq 0 ]
  [ "$(destroys)" = 2 ]
  # The FULL sweep ran twice: once before the first destroy, once before the
  # retry. A retry that swept only the webhooks would leave the pods that got
  # stuck during the failed attempt, and hit the same wall.
  [ "$(predestroys)" = 2 ]
  [[ "$output" == *"retryable destroy failure"* ]]
}

# ---------------------------------------------------------------------------
# A destroy killed on its context deadline keeps the backend's S3 lockfile.
# The retry then fails in seconds on "Error acquiring the state lock ...
# PreconditionFailed" having done no work at all, and the teardown reports a
# half-destroyed cluster that is still billing. Measured on the 2026-09-14
# staging teardown. The retry releases a lock that is demonstrably OURS, and
# nobody else's.
# ---------------------------------------------------------------------------
@test "the retry releases the state lock our own dead attempt left" {
  export STUB_DESTROY_1_FAIL="Error: context deadline exceeded"
  export STUB_LOCK_WHO="$(whoami)@$(hostname)"
  # Created is stamped by the dying destroy (see the terraform stub). Taking
  # it here instead, before the verb starts, raced the verb's own start
  # stamp across a one-second clock and failed ci on main (run 35625720007).
  run_teardown wipe
  [ "$status" -eq 0 ]
  [ "$(destroys)" = 2 ]
  grep -q 'force-unlock -force deadbeef-0000-0000-0000-000000000000' "$STATE/terraform.log"
  [[ "$output" == *"releasing the state lock our own attempt left behind"* ]]
  # The unlock happens BEFORE the retry, or it buys nothing.
  unlock_line=$(grep -n 'force-unlock' "$STATE/terraform.log" | head -1 | cut -d: -f1)
  second_destroy=$(grep -n ' destroy' "$STATE/terraform.log" | sed -n 2p | cut -d: -f1)
  [ "$unlock_line" -lt "$second_destroy" ]
}

@test "FAILING FIXTURE: a lock held by someone else is never force-unlocked" {
  export STUB_DESTROY_1_FAIL="Error: context deadline exceeded"
  export STUB_LOCK_WHO="someone-else@their-laptop"
  run_teardown wipe
  run grep -c 'force-unlock' "$STATE/terraform.log"
  [ "$output" = "0" ]
}

@test "FAILING FIXTURE: a lock that predates this teardown is never force-unlocked" {
  export STUB_DESTROY_1_FAIL="Error: context deadline exceeded"
  export STUB_LOCK_WHO="$(whoami)@$(hostname)"
  export STUB_LOCK_CREATED="2001-01-01T00:00:00Z"
  run_teardown wipe
  run grep -c 'force-unlock' "$STATE/terraform.log"
  [ "$output" = "0" ]
}

# The lockfile's Created is RFC3339Nano. A string compare against a
# "%Y-%m-%d %H:%M:%S" start stamp put 'T' against ' ' at the eleventh
# character, so every same-day lock compared as newer than the start, and a
# lock of ours from earlier today was released. The compare is on epoch
# seconds now. This fixture fails on the string compare.
@test "FAILING FIXTURE: a lock of ours from earlier today is never force-unlocked" {
  export STUB_DESTROY_1_FAIL="Error: context deadline exceeded"
  export STUB_LOCK_WHO="$(whoami)@$(hostname)"
  export STUB_LOCK_CREATED="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S.%NZ)"
  run_teardown wipe
  run grep -c 'force-unlock' "$STATE/terraform.log"
  [ "$output" = "0" ]
}

@test "FAILING FIXTURE: a lock whose Created cannot be read is never force-unlocked" {
  export STUB_DESTROY_1_FAIL="Error: context deadline exceeded"
  export STUB_LOCK_WHO="$(whoami)@$(hostname)"
  export STUB_LOCK_CREATED="not-a-time"
  run_teardown wipe
  [[ "$output" == *"the state lock carries no readable Created (not-a-time); leaving it alone"* ]]
  run grep -c 'force-unlock' "$STATE/terraform.log"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# The environment's own sub-zone (2026-09-14).
#
# external-dns publishes the edge A/AAAA aliases and cert-manager's DNS-01
# solver publishes challenge TXTs. Both controllers die with the cluster and
# neither gets a reconcile tick between the Service going and the node going,
# so the records outlive the load balancer they point at. Measured on the
# staging teardown: A and AAAA for staging.zeroroot.ai still aliased
# k8s-gibson-gibsonen-920c6946b9-*.elb after a clean destroy, with
# external-dns's ownership TXT already gone.
#
# The missing TXT is what breaks the NEXT bringup. external-dns runs
# policy: sync and only manages records it owns, so an A record with no
# ownership TXT is one it will never touch: the new edge comes up and the
# environment's name keeps resolving to a deleted load balancer, for ever.
# ---------------------------------------------------------------------------
@test "the teardown clears the cluster records from the env sub-zone" {
  export STUB_ZONE_CONTENT=residue
  run_teardown wipe
  [ "$status" -eq 0 ]
  grep -q 'route53 change-resource-record-sets --hosted-zone-id Z0BATSSTAGINGZONE' "$STATE/aws.log"
  [[ "$output" == *"clearing 3 cluster-created record(s)"* ]]
  [[ "$output" == *"back to its own NS and SOA"* ]]
}

@test "a sub-zone holding only its own NS and SOA is left alone" {
  export STUB_ZONE_CONTENT=own
  run_teardown wipe
  [ "$status" -eq 0 ]
  ! grep -q 'change-resource-record-sets' "$STATE/aws.log"
  [[ "$output" == *"nothing but its own NS and SOA"* ]]
}

# FAILING FIXTURE: the apex. It carries the estate's mail (MX, SPF, DKIM) and
# the public web surfaces (ADR-0077), belongs to stage 0, and no teardown may
# touch it. A substrate.env that names the apex as the environment's own zone
# is a stage 0 defect, and the teardown refuses rather than sweeping it.
@test "FAILING FIXTURE: a substrate naming the APEX as the env zone is refused" {
  sed -i 's/^ZONE_NAME=.*/ZONE_NAME=zeroroot.ai/' "$SUBSTRATE"
  run_teardown wipe
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to sweep records"* ]]
  [[ "$output" == *"APEX zone"* ]]
  ! grep -q 'change-resource-record-sets' "$STATE/aws.log"
}

# A substrate with no zone at all (kind) has no sub-zone to sweep and must not
# fail the verb over it.
@test "a substrate that names no zone sweeps nothing and does not fail" {
  sed -i '/^ZONE_ID=/d;/^ZONE_NAME=/d' "$SUBSTRATE"
  run_teardown wipe
  [ "$status" -eq 0 ]
  ! grep -q 'change-resource-record-sets' "$STATE/aws.log"
  [[ "$output" == *"no ZONE_ID/ZONE_NAME"* ]]
}

@test "a retryable admission-webhook timeout retries the same way" {
  export STUB_DESTROY_1_FAIL="Error: context deadline exceeded"
  run_teardown wipe
  [ "$status" -eq 0 ]
  [ "$(destroys)" = 2 ]
  [ "$(predestroys)" = 2 ]
}

@test "the webhook signature that never names the webhook is still retryable" {
  export STUB_DESTROY_1_FAIL='no endpoints available for service "external-secrets-webhook"'
  run_teardown wipe
  [ "$status" -eq 0 ]
  [ "$(destroys)" = 2 ]
}

@test "FIXTURE: a NON-retryable destroy failure is never retried, and the verb fails" {
  export STUB_DESTROY_1_FAIL="InvalidParameterValue: the subnet does not exist"
  run_teardown wipe
  [ "$status" -ne 0 ]
  [ "$(destroys)" = 1 ]
  # Only the opening sweep ran: a non-retryable error never reaches the retry.
  [ "$(predestroys)" = 1 ]
  [[ "$output" == *"non-retryable"* ]]
  [[ "$output" == *"STILL BILLING"* ]]
}

@test "FIXTURE: the retry is bounded — a second failure fails the verb" {
  export STUB_DESTROY_1_FAIL="Request limit exceeded"
  export STUB_DESTROY_2_FAIL="Request limit exceeded"
  run_teardown wipe
  [ "$status" -ne 0 ]
  [ "$(destroys)" = 2 ]
  [[ "$output" == *"FAILED after one retry"* ]]
}

@test "FIXTURE: a failing post-destroy verification FAILS the teardown, fail-closed" {
  export STUB_VERIFY_RC=1
  run_teardown wipe
  [ "$status" -ne 0 ]
  [ "$(destroys)" = 1 ]
  [[ "$output" == *"still holds billable resources"* ]]
}

@test "FIXTURE: a kubeconfig pointing at another cluster is refused before anything happens" {
  export STUB_LIVE_SERVER="https://some-other-cluster.eks.amazonaws.com"
  run_teardown preserve
  [ "$status" -ne 0 ]
  [ "$(destroys)" = 0 ]
  [[ "$output" == *"back up one cluster and destroy another"* ]]
}

@test "FIXTURE: a preserve teardown of an env AWS has no cluster for is refused, and names wipe" {
  export STUB_EKS_ENDPOINT=""
  export STUB_LIVE_SERVER="https://something.example"
  run_teardown preserve
  [ "$status" -ne 0 ]
  [ "$(destroys)" = 0 ]
  [[ "$output" == *"MODE=wipe is the mode that says so"* ]]
}
