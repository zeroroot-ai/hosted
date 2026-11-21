#!/usr/bin/env bash
# preserve-restore-loop.sh — launch blocker 3, the whole loop (deploy#1739,
# ADR-0083).
#
# In plain words: prove that a planned teardown does not lose a customer's
# data, and that an unplanned one does not bring it back.
#
# Measured as one sequence, on one cluster, with the verbs an operator runs
# and no other path:
#
#   1. make recreate ENV=<env>                the platform, from nothing, empty
#   2. seed one tenant                        a Tenant CR, a node in its graph,
#                                             and a ciphertext under a key that
#                                             lives only in the secret store
#   3. make teardown ENV=<env> MODE=preserve  backup, backup-verify, destroy.
#                                             It prints the backup name.
#   4. make recreate ENV=<env> RESTORE_FROM=<that name>
#   5. THE EXIT TEST                          the key decrypts the ciphertext
#                                             recorded before the teardown, and
#                                             the graph node reads back
#   6. make teardown ENV=<env> MODE=wipe      destroy, keep nothing
#   7. make recreate ENV=<env>                no name, so no restore
#   8. THE OTHER HALF OF THE EXIT TEST        the tenant is ABSENT, its
#                                             namespace is ABSENT, its key is
#                                             ABSENT, and no Velero Restore ran
#                                             — while the bucket still holds
#                                             the backup from step 3
#
# Step 8 is ADR-0083. The bucket is unchanged between step 5 and step 8: the
# only difference is that nobody named the backup. If the tenant comes back
# there, a wipe teardown is indistinguishable from a preserve teardown and the
# two modes mean nothing.
#
# The ciphertext is the assertion that a transit key which merely EXISTS
# cannot fake. A fresh store mints a key of the same name that decrypts
# nothing, so the plaintext coming back is proof the store is the same store.
#
# It needs a stage 0 for the env (`make substrate ENV=<env>`), kubectl, helm,
# terraform, aws and python3, plus docker and kind for ENV=kind. It creates
# and destroys the cluster three times, so on an AWS env it spends real money
# and every run ends in a wipe.
#
# --env selects the substrate. Everything below the verbs is the same on all
# of them: the seed, the ciphertext, the graph node and every assertion speak
# kubectl only. Only `cluster_still_there` knows what a cluster is.
#
# Usage:
#   test/dr/preserve-restore-loop.sh --substrate-dir /bulk/substrate \
#     [--env kind|staging|prod] [--cluster gibson] \
#     [--rung ci]
set -euo pipefail

SUBSTRATE_DIR=""
ENV_NAME="kind"
CLUSTER="gibson"
# The rung of the profile ladder every recreate in this loop installs at
# (ADR-0090). It names a file that ships inside the chart, so nothing has to
# travel with it.
RUNG="${RUNG:-}"
NS="gibson"
TENANT="restoreloop"
TIER="team"
READY_TIMEOUT="${READY_TIMEOUT:-1800}"

while [ $# -gt 0 ]; do
  case "$1" in
    --substrate-dir) SUBSTRATE_DIR="$2"; shift 2 ;;
    --cluster)       CLUSTER="$2"; shift 2 ;;
    --rung)          RUNG="$2"; shift 2 ;;
    --tenant)        TENANT="$2"; shift 2 ;;
    --env)           ENV_NAME="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SUBSTRATE_DIR" ] || { echo "--substrate-dir is required (the stage 0 state make substrate ENV=<env> wrote)" >&2; exit 2; }
case "$ENV_NAME" in
  kind|staging|prod) ;;
  *) echo "--env must be kind, staging or prod (got '${ENV_NAME}')" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TENANT_NS="tenant-${TENANT}"
PLAINTEXT="the tenant key must survive the teardown"
GRAPH_MARKER="restore-loop graph node, written before the preserve teardown"

say()  { printf '\n\033[1;36m===> %s\033[0m\n' "$*"; }
note() { printf '     %s\n' "$*"; }

# diag — what the cluster looked like when the loop gave up. Best effort by
# design: every caller exits non-zero on the next line regardless, and a
# missing object is exactly the state that makes the query fail.
diag() {
  printf '\n--- tenants ---\n' >&2
  kubectl get tenants.gibson.zeroroot.ai -o wide >&2 2>/dev/null || true
  kubectl get "tenant/${TENANT}" -o yaml 2>/dev/null | sed -n '/^status:/,$p' >&2 || true
  printf '\n--- %s ---\n' "$TENANT_NS" >&2
  kubectl -n "$TENANT_NS" get pods,pvc -o wide >&2 2>/dev/null || true
  kubectl -n "$TENANT_NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 >&2 || true
  printf '\n--- velero ---\n' >&2
  kubectl -n velero get backups.velero.io,restores.velero.io,podvolumerestores.velero.io >&2 2>/dev/null || true
  printf '\n--- argo ---\n' >&2
  kubectl -n argocd get applications -o wide >&2 2>/dev/null || true
  printf '\n--- tenant-operator ---\n' >&2
  kubectl -n "$NS" logs deploy/gibson-tenant-operator --tail=60 >&2 2>/dev/null || true
}
die()  { diag; printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# cluster_still_there — the one check that cannot be substrate-agnostic. A
# teardown that reported success while its cluster stands is the failure this
# loop exists to catch, and "gone" is asked of the substrate that owns the
# cluster, never of a kubeconfig that may simply be stale.
cluster_still_there() {
  case "$ENV_NAME" in
    kind) kind get clusters 2>/dev/null | grep -qx "$CLUSTER" ;;
    *)    [ -n "$(aws eks describe-cluster --name "zeroroot-ai-${ENV_NAME}" \
            --region "${AWS_REGION:-us-east-1}" --query 'cluster.name' \
            --output text 2>/dev/null)" ] ;;
  esac
}

# use_cluster — point this shell at the cluster the recreate just built.
#
# On kind `kind create cluster` sets the current context for us. On an AWS env
# the recreate writes its own kubeconfig inside its own process, so nothing
# reaches this shell unless it asks. Every assertion below, and the preserve
# teardown's own "am I destroying what I backed up" check, reads the CURRENT
# context — so this is a correctness step, not a convenience.
use_cluster() {
  case "$ENV_NAME" in
    kind) return 0 ;;
    *)
      export KUBECONFIG="${EKS_KUBECONFIG:-/tmp/eks-${ENV_NAME}.kubeconfig}"
      aws eks update-kubeconfig --name "zeroroot-ai-${ENV_NAME}" \
        --region "${AWS_REGION:-us-east-1}" --kubeconfig "$KUBECONFIG" >/dev/null \
        || die "could not write a kubeconfig for zeroroot-ai-${ENV_NAME} after the recreate"
      note "kubeconfig -> ${KUBECONFIG}"
      ;;
  esac
}

verb() {
  # Every step of the loop is a bringup verb and nothing else. One path: what
  # this script runs is what an operator runs.
  say "make $*"
  # RUNG=ci also shrinks the Velero release and the metrics-server add-on on
  # the 2-vCPU runner, or the umbrella's neo4j never schedules
  # (scripts/check-2core-overlay.py). No values file travels (hosted#425).
  ( cd "$REPO" && SUBSTRATE_DIR="$SUBSTRATE_DIR" CLUSTER="$CLUSTER" \
      RUNG="$RUNG" \
      WAIT_APPS_TIMEOUT="${WAIT_APPS_TIMEOUT:-3600}" make "$@" )
}

# The stores, the records and their checks are one library, shared with the
# drill workflow (hosted#443).
# shellcheck source=lib/restore-markers.sh
. "$HERE/lib/restore-markers.sh"

# ===========================================================================
say "1/8  a recreate with no name: the platform, from nothing, EMPTY"
# ===========================================================================
verb recreate ENV="$ENV_NAME"
use_cluster

# ===========================================================================
say "2/8  seed one tenant: a Tenant CR, a graph node, and a recorded ciphertext"
# ===========================================================================
markers_seed

# ===========================================================================
say "3/8  make teardown MODE=preserve: backup, backup-verify, destroy"
# ===========================================================================
TEARDOWN_LOG="$(mktemp)"
verb teardown ENV="$ENV_NAME" MODE=preserve 2>&1 | tee "$TEARDOWN_LOG"
BACKUP_NAME="$(grep -oE '^RESTORE_FROM=.*$' "$TEARDOWN_LOG" | tail -n1 | cut -d= -f2-)"
[ -n "$BACKUP_NAME" ] \
  || die "the preserve teardown printed no RESTORE_FROM=<name> line. That name is the only thing a restore accepts (ADR-0083)"
note "backup name: ${BACKUP_NAME}"
if cluster_still_there; then
  die "the preserve teardown reported success and the cluster is still there"
fi
note "the cluster is gone, the durable bucket is not"

# ===========================================================================
say "4/8  make recreate RESTORE_FROM=${BACKUP_NAME}"
# ===========================================================================
verb recreate ENV="$ENV_NAME" RESTORE_FROM="$BACKUP_NAME"
use_cluster

# ===========================================================================
say "5/8  THE EXIT TEST: the tenant key decrypts, and the graph reads back"
# ===========================================================================
markers_check

# ===========================================================================
say "5b/8 a deleted tenant leaves a last backup that the Schedule template shaped"
# ===========================================================================
# The tenant-operator takes the last Velero Backup of a tenant before its
# delete flow removes anything (ADR-0075). That Backup must exclude what the
# hourly Schedule excludes, or it ends PartiallyFailed on kinds the server may
# not list and holds a CiliumEndpoint a restore cannot create (C67,
# gibson#1177). Assert it on a second tenant, so the restored one stays.
final_backup_check() {
  local t="finalloop" uid name phase want got missing
  kubectl apply -f - <<YAML
apiVersion: gibson.zeroroot.ai/v1alpha1
kind: Tenant
metadata:
  name: ${t}
spec:
  displayName: Final Backup Loop
  owner: final-loop@zeroroot.ai
  tier: ${TIER}
YAML
  wait_for "$READY_TIMEOUT" "the tenant ${t} never got its namespace tenant-${t}" -- \
    kubectl get namespace "tenant-${t}"
  uid="$(kubectl get "tenant/${t}" -o jsonpath='{.metadata.uid}')"
  [ -n "$uid" ] || die "the tenant ${t} has no UID"
  name="tenant-final-${uid}"
  kubectl delete "tenant/${t}" --wait=false
  wait_for 1800 "the tenant-operator wrote no last Backup ${name} for the deleted tenant ${t}" -- \
    kubectl -n velero get "backups.velero.io/${name}"
  # The phase read keeps its error. A refused read is a failure of its own,
  # and a Backup that never reaches an end phase is a timeout, not an end.
  local ended="" readerr
  readerr="$(mktemp)"
  phase=""
  for _ in $(seq 1 180); do
    if ! phase="$(kubectl -n velero get "backups.velero.io/${name}" -o jsonpath='{.status.phase}' 2>"$readerr")"; then
      die "cannot read the phase of the last backup ${name}: $(cat "$readerr")"
    fi
    case "$phase" in Completed|PartiallyFailed|Failed|FailedValidation) ended=1; break ;; esac
    sleep 10
  done
  rm -f "$readerr"
  if [ -z "$ended" ]; then
    kubectl -n velero get "backups.velero.io/${name}" -o jsonpath='{.status}' >&2 || true
    die "the last backup ${name} of the deleted tenant did not end within 1800 s (phase '${phase}')"
  fi
  [ "$phase" = "Completed" ] || {
    kubectl -n velero get "backups.velero.io/${name}" -o jsonpath='{.status}' >&2 || true
    die "the last backup ${name} of the deleted tenant ended '${phase}', want Completed"
  }
  want="$(kubectl -n velero get schedules.velero.io/platform-hourly \
            -o jsonpath='{range .spec.template.excludedNamespaceScopedResources[*]}{@}{"\n"}{end}' | sort)"
  got="$(kubectl -n velero get "backups.velero.io/${name}" \
            -o jsonpath='{range .spec.excludedNamespaceScopedResources[*]}{@}{"\n"}{end}' | sort)"
  [ -n "$want" ] || die "the Schedule platform-hourly lists no exclusion, so this check would look at nothing"
  # Each exclusion of the Schedule must be in the backup. Velero adds its own
  # exclusions to a Backup spec when it validates it (run 39072438407 showed
  # volumesnapshots.snapshot.storage.k8s.io), so the two lists need not be
  # equal. A missing Schedule exclusion is C67.
  missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"
  [ -z "$missing" ] || {
    printf 'Schedule excludes:\n%s\nlast backup excludes:\n%s\nmissing from the backup:\n%s\n' "$want" "$got" "$missing" >&2
    die "the last backup ${name} does not exclude what the Schedule excludes"
  }
  printf '\033[1;32m     ✓ the last backup %s is Completed and excludes what platform-hourly excludes\033[0m\n' "$name"
}
final_backup_check

# ===========================================================================
say "6/8  make teardown MODE=wipe: destroy, keep nothing, delete nothing"
# ===========================================================================
verb teardown ENV="$ENV_NAME" MODE=wipe

# ===========================================================================
say "7/8  a recreate with NO name, while the bucket still holds that backup"
# ===========================================================================
SUBSTRATE_ENV="${SUBSTRATE_DIR}/kind/substrate.env"
sub_get() { grep -E "^$1=" "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2-; }
KEYRING_FILE="$(sub_get KEYRING_FILE)"
BUCKET_NAME="$(sub_get BUCKET_NAME)"
BUCKET_ENDPOINT="$(sub_get BUCKET_ENDPOINT)"
key_get() { grep -E "^$1=" "$KEYRING_FILE" | head -n1 | cut -d= -f2-; }
AWS_ACCESS_KEY_ID="$(key_get BUCKET_ACCESS_KEY)" \
AWS_SECRET_ACCESS_KEY="$(key_get BUCKET_SECRET_KEY)" \
AWS_DEFAULT_REGION="$(sub_get BUCKET_REGION)" \
  aws --endpoint-url "$BUCKET_ENDPOINT" s3 ls \
    "s3://${BUCKET_NAME}/backups/velero/backups/${BACKUP_NAME}/velero-backup.json" >/dev/null \
  || die "the backup ${BACKUP_NAME} is gone from the durable bucket, so step 8 would have no fixture to fail against"
note "the bucket still holds ${BACKUP_NAME}: the ONLY difference from step 4 is that nobody names it"
verb recreate ENV="$ENV_NAME"
use_cluster

# ===========================================================================
say "8/8  THE OTHER HALF: no name, so nothing came back (ADR-0083)"
# ===========================================================================
markers_absent

RESTORES="$(kubectl -n velero get restores.velero.io --no-headers 2>/dev/null | wc -l)"
[ "$RESTORES" -eq 0 ] \
  || { kubectl -n velero get restores.velero.io; die "a nameless recreate produced ${RESTORES} Velero Restore object(s)"; }
printf '\033[1;32m     ✓ zero Velero Restore objects\033[0m\n'

say "PASS — a preserve teardown and a named recreate bring one tenant back intact, and a wipe teardown and a nameless recreate do not"
printf 'backup used: %s\n' "$BACKUP_NAME"
