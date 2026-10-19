#!/usr/bin/env bash
# teardown-aws.sh — the teardown verb for ENV=staging and ENV=prod
# (ADR-0083, deploy#1746). `make teardown ENV=<env> MODE=wipe|preserve`
# runs preflight and then this script. The deleted `eks-down` target did the
# wipe half and asked for CONFIRM=reset; the verb asks for MODE instead,
# because MODE already says which of the two destructive things you meant.
#
# MODE has no default, here and in make. A teardown that picks a mode by
# omission is how a preserve teardown silently becomes a wipe, so this script
# refuses an unset or unknown MODE even though make already did: no other
# caller may slip one past.
#
#   MODE=wipe      Destroy stage 1 and keep nothing. It deletes NOTHING from
#                  the durable bucket and never reads it: retention is the
#                  bucket's lifecycle rule and nothing else, and the next
#                  recreate does not consult the bucket (ADR-0083).
#
#   MODE=preserve  Back up, PROVE the backup readable, then destroy, then
#                  print the backup name. Steps 0 through 3 are
#                  scripts/lib/preserve-backup.sh — the SAME code ENV=kind
#                  runs (scripts/teardown-kind.sh). Only the destroy differs
#                  per substrate, and only the destroy lives here.
#
# THE DESTROY, in order (docs/runbooks/eks-destroy.md):
#
#   1. terraform init against the env's durable bucket backend. A destroy on
#      a fresh checkout has no local .terraform/, and an uninitialised
#      destroy is a destroy that does nothing and says it worked.
#   2. bootstrap/eks/gibson/scripts/eks-pre-destroy.sh — the sweep. It clears the
#      service-backed admission webhooks FIRST, while their pods are still
#      up, then the Karpenter NodePools, the LoadBalancer Services, the
#      out-of-band ENIs and security groups. It detaches nothing from state.
#   3. terraform destroy, with ONE automatic retry for the two signatures
#      that are transient (TEARDOWN_RETRYABLE below). The retry re-runs the
#      webhook sweep first.
#   4. bootstrap/eks/gibson/scripts/eks-post-destroy-verify.sh — zero billable
#      resources account-wide, fail-closed (ADR-0070). A destroy that leaves
#      the account billing is not a teardown.
#
# Stage 1 is the bootstrap/eks/gibson workspace and everything its controllers made at
# runtime. Stage 0 (the durable bucket, the SES relay, the DNS sub-zone, the
# keyring) is NOT stage 1 and is never touched by either mode.
#
# Usage: teardown-aws.sh <substrate.env> <env>   (make teardown ENV=<env> calls it)
# Env:
#   MODE       wipe|preserve, REQUIRED, no default
#   NS         release namespace              (default: gibson)
#   VELERO_NS SCHEDULE CNPG_CLUSTER BACKUP_TIMEOUT VERIFY_TIMEOUT
#              the preserve inputs. Their defaults are in lib/preserve-backup.sh
#   AWS_REGION the cluster region             (default: us-east-1)
set -uo pipefail

SUBSTRATE_ENV="${1:-}"
ENV_NAME="${2:-}"
[ -n "$SUBSTRATE_ENV" ] && [ -n "$ENV_NAME" ] || { echo "usage: teardown-aws.sh <substrate.env> <env>" >&2; exit 2; }
[ -s "$SUBSTRATE_ENV" ] || { echo "FATAL: no substrate.env at ${SUBSTRATE_ENV}. Run make substrate ENV=${ENV_NAME} first (ADR-0083)." >&2; exit 2; }

# A key that is not in substrate.env yields the empty string. Without the
# `|| true` grep exits 1, and under `set -e` a command substitution carries
# that out to the whole script, so an ABSENT OPTIONAL key would kill the verb
# with no message at all. Same helper the recreate verb uses.
substrate_get() { grep -E "^$1=" "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true; }

# The moment this teardown began, as epoch seconds. Only a lock created at
# or after this can be ours. See lib/tf-state-lock.sh.
TEARDOWN_STARTED_EPOCH="$(date -u +%s)"

MODE="${MODE:-}"
case "$MODE" in
  wipe|preserve) ;;
  *) echo "FATAL: MODE is required and has no default: MODE=wipe or MODE=preserve (ADR-0083)." >&2; exit 2 ;;
esac

NS="${NS:-gibson}"
AWS_REGION="${AWS_REGION:-us-east-1}"
# How long the one retry waits for the EC2 API to stop throttling. A knob so
# the offline suite can drive the retry path in milliseconds
# (tests/harness/teardown-aws.bats); nothing else ever sets it.
RETRY_DELAY="${RETRY_DELAY:-60}"
CLUSTER_NAME="${CLUSTER_NAME:-zeroroot-ai-${ENV_NAME}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
EKS_DIR="$REPO/bootstrap/eks/gibson"

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n\033[1;32m▶\033[0m [teardown %s] %s\n' "$MODE" "$*"; }
die() { printf '\033[1;31m✗ [teardown %s] %s\033[0m\n' "$MODE" "$*" >&2; exit 1; }

for tool in kubectl terraform aws python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

# Destroy-failure signatures that earn ONE automatic retry. The matcher is the
# one `eks-down` carried, restored here verbatim (deploy#1745 deleted it with
# the target; its signatures are recorded in docs/runbooks/eks-destroy.md).
# It stays bounded on purpose: a second failure is reported, not retried
# again, because a destroy that fails twice is a defect to diagnose, not a
# flake to paper over. Both classes leave a half-destroyed, STILL-BILLING
# cluster if they go unhandled, which is the whole reason they retry at all.
#
#   Request limit exceeded / RequestLimitExceeded / DELETE_FAILED  deploy#1126
#     The destroy deletes many EC2 resources in parallel and trips the EC2 API
#     rate limit, which surfaces as a nodegroup in DELETE_FAILED.
#   failed calling webhook / no endpoints available for service    deploy#1592
#     The destroy graph can remove a webhook's backing workload before the CRs
#     that webhook gates. The API server then refuses those deletions and
#     terraform blocks until its context deadline. Neither the helm nor the
#     kubernetes provider names the webhook in its FINAL error, so matching
#     only "failed calling webhook" would miss the real teardown — which is
#     why "context deadline exceeded" and "timed out waiting for the
#     condition" are in the list too.
TEARDOWN_RETRYABLE='Request limit exceeded|RequestLimitExceeded|unexpected state .DELETE_FAILED.|failed calling webhook|no endpoints available for service|context deadline exceeded|timed out waiting for the condition'

# tf_init — the backend is the env's durable bucket, prefix tfstate/
# (ADR-0083). The bucket name carries the live account id, so it is derived
# here rather than committed. Locking is S3 native (use_lockfile), so there
# is no lock table and no KMS key.
TF_STATE_KEY="tfstate/eks-gibson/terraform.tfstate"

# durable_bucket — the one derivation of the backend bucket name. Both the
# init and the lock release must name the SAME bucket, so neither spells it.
durable_bucket() {
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    || die "no usable AWS credentials: aws sts get-caller-identity failed. A destroy without credentials would report success having destroyed nothing"
  printf 'zeroroot-ai-%s-durable-%s' "$ENV_NAME" "$acct"
}

tf_init() {
  local bucket
  bucket="$(durable_bucket)"
  log "terraform init against s3://${bucket}/${TF_STATE_KEY%/terraform.tfstate}"
  terraform -chdir="$EKS_DIR" init -reconfigure -input=false \
    -backend-config="key=${TF_STATE_KEY}" \
    -backend-config="bucket=${bucket}" \
    -backend-config="use_lockfile=true" >/dev/null \
    || die "terraform init failed against the ${ENV_NAME} durable bucket"
}

# The release of our own stale state lock is lib/tf-state-lock.sh, shared with
# teardown-ec2.sh.
# shellcheck source=lib/tf-state-lock.sh
. "$HERE/lib/tf-state-lock.sh"

# ensure_kubeconfig — the sweep talks to the LIVE cluster, so the destroy has
# to hand it one. eks-pre-destroy.sh exits 0 when the cluster is unreachable,
# by its own safety contract, so a teardown run with no kubeconfig sweeps
# NOTHING, says nothing, and then deadlocks in `terraform destroy` on the very
# admission webhooks the sweep exists to clear (deploy#1592). A verb may not
# depend on the operator having run `aws eks update-kubeconfig` first.
#
# It writes its own file under the scratch directory, so it never edits the
# caller's kubeconfig. A preserve teardown has already proven the current
# context IS this cluster, and this leaves that alone.
ensure_kubeconfig() {
  local endpoint
  endpoint="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.endpoint' --output text 2>/dev/null)"
  if [ -z "$endpoint" ] || [ "$endpoint" = None ]; then
    printf '  ! AWS reports no cluster named %s: nothing to sweep, going straight to the destroy\n' "$CLUSTER_NAME"
    return 0
  fi
  if [ "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)" = "$endpoint" ]; then
    printf '  ✓ the current kubeconfig already points at %s\n' "$CLUSTER_NAME"
    return 0
  fi
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --kubeconfig "$WORK/kubeconfig" >/dev/null \
    || die "could not write a kubeconfig for ${CLUSTER_NAME}. The pre-destroy sweep would reach nothing and the destroy would deadlock on the admission webhooks it clears"
  export KUBECONFIG="$WORK/kubeconfig"
  printf '  ✓ kubeconfig for %s written for the sweep\n' "$CLUSTER_NAME"
}

# destroy_stage1 — the sweep, the destroy with its one retry, the verify.
# sweep_env_zone_records — delete the records the CLUSTER created in the
# environment's own sub-zone, after the cluster is gone.
#
# external-dns publishes the A/AAAA aliases for the edge and cert-manager's
# DNS-01 solver publishes challenge TXTs. Both controllers die with the
# cluster, and neither gets a reconcile tick between the Service being deleted
# and the node going, so the records outlive the load balancer they point at.
# Measured on the 2026-09-14 staging teardown: A and AAAA for
# staging.zeroroot.ai still aliased k8s-gibson-gibsonen-920c6946b9-*.elb after
# a clean destroy, with external-dns's ownership TXT already gone.
#
# The missing TXT is the part that breaks the NEXT bringup, not just the
# ledger. external-dns runs policy: sync and only manages records it owns, so
# an A record with no ownership TXT is one it will never touch: the new edge
# would come up and the environment's name would keep resolving to a deleted
# load balancer, for ever, with nothing reporting it.
#
# Scoped to the ENV sub-zone by id, and refused outright when that id is the
# apex. The apex zone carries the estate's mail (MX, SPF, DKIM) and the public
# web surfaces (ADR-0077), belongs to stage 0, and no teardown may touch it.
# NS and SOA at the zone apex are the zone itself and stay.
sweep_env_zone_records() {
  local zone_id zone_name apex batch count
  zone_id="$(substrate_get ZONE_ID)"
  zone_name="$(substrate_get ZONE_NAME)"
  apex="$(substrate_get APEX_ZONE_NAME)"
  if [ -z "$zone_id" ] || [ -z "$zone_name" ]; then
    printf '  %s names no ZONE_ID/ZONE_NAME, so there is no env sub-zone to sweep\n' "$SUBSTRATE_ENV"
    return 0
  fi
  if [ -n "$apex" ] && [ "${zone_name%.}" = "${apex%.}" ]; then
    die "refusing to sweep records: ${SUBSTRATE_ENV} names the APEX zone ${apex} as this environment's zone. The apex carries the estate's mail and the public web surfaces (ADR-0077) and belongs to stage 0"
  fi

  batch="$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
      --output json 2>/dev/null \
    | python3 -c '
import json, sys
zone = sys.argv[1].rstrip(".") + "."
sets = json.load(sys.stdin).get("ResourceRecordSets", [])
drop = [r for r in sets
        if not (r["Name"] == zone and r["Type"] in ("NS", "SOA"))]
print(json.dumps({"Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r in drop]}))
' "$zone_name" 2>/dev/null)" \
    || { printf '  could not read the records in zone %s; the verification below reports what is left\n' "$zone_id"; return 0; }

  count="$(printf '%s' "$batch" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["Changes"]))' 2>/dev/null || echo 0)"
  if [ "${count:-0}" = 0 ]; then
    printf '  ✓ the %s sub-zone holds nothing but its own NS and SOA\n' "$zone_name"
    return 0
  fi
  printf '  clearing %s cluster-created record(s) from the %s sub-zone\n' "$count" "$zone_name"
  aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
    --change-batch "$batch" >/dev/null 2>&1 \
    && printf '  ✓ the %s sub-zone is back to its own NS and SOA\n' "$zone_name" \
    || printf '  the record delete did not succeed; the verification below reports what is left\n'
}

destroy_stage1() {
  tf_init
  ensure_kubeconfig

  # The edge certificate, kept for the next bringup (row 9 of the drill path
  # audit; scripts/lib/edge-cert.sh). A preserve teardown stops when it
  # cannot keep it. A wipe goes on: the cluster may already be gone, and a
  # lost certificate costs only one new issuance.
  # shellcheck source=lib/edge-cert.sh
  . "$HERE/lib/edge-cert.sh"
  EDGE_CERT_SECRET="$(substrate_get EDGE_CERT_SECRET)"
  if [ "$MODE" = preserve ]; then
    edge_cert_store
  elif ! ( edge_cert_store ); then
    log "the edge certificate was not kept (the reason is above). The wipe goes on, and the next bringup asks for a new one"
  fi

  log "pre-destroy sweep: admission webhooks first, then Karpenter, load balancers, ENIs, security groups"
  ( cd "$EKS_DIR" && CONFIRM=reset WORKSPACE="zeroroot-ai-${ENV_NAME}" bash scripts/eks-pre-destroy.sh ) \
    || die "the pre-destroy sweep failed. Nothing was destroyed by terraform. Read the output above, fix the cause, and run the teardown again"

  log "terraform destroy (ENV=${ENV_NAME})"
  local rc=0
  terraform -chdir="$EKS_DIR" destroy -var-file="envs/${ENV_NAME}.tfvars" \
    -auto-approve -input=false 2>&1 | tee "$WORK/destroy.log" || rc=1
  if [ "$rc" != 0 ]; then
    if grep -qE "$TEARDOWN_RETRYABLE" "$WORK/destroy.log"; then
      printf '\033[1;33m!\033[0m [teardown %s] retryable destroy failure (EC2 throttle deploy#1126, or admission-webhook timeout deploy#1592).\n' "$MODE"
      printf '    Re-running the FULL pre-destroy sweep, then retrying the destroy once in %ss.\n' "$RETRY_DELAY"
      # The WHOLE sweep, not just the webhook half. A failed destroy leaves
      # exactly the state the sweep exists to clear, and it leaves MORE of it
      # than the first run ever saw: pods that were healthy when the teardown
      # started are stuck Terminating by the time it fails, because their
      # nodes went away underneath them. A namespace cannot finish deleting
      # behind one of those, so terraform blocks on it and the retry hits the
      # same wall the first attempt did — measured twice on staging
      # (deploy#1746, gibson-openbao-0 then the gibson namespace itself).
      # eks-pre-destroy.sh is idempotent and exits 0 on an unreachable
      # cluster, so re-running all of it is both safe and the point.
      ( cd "$EKS_DIR" && CONFIRM=reset WORKSPACE="zeroroot-ai-${ENV_NAME}" bash scripts/eks-pre-destroy.sh ) || true
      # A destroy killed on its deadline keeps the S3 lockfile, and a retry
      # that cannot take the lock does nothing at all.
      tf_release_own_stale_lock "$EKS_DIR" "$(durable_bucket 2>/dev/null || true)" "$TF_STATE_KEY" "$TEARDOWN_STARTED_EPOCH"
      sleep "$RETRY_DELAY"
      terraform -chdir="$EKS_DIR" destroy -var-file="envs/${ENV_NAME}.tfvars" \
        -auto-approve -input=false \
        || die "the destroy FAILED after one retry. The cluster is half-destroyed and STILL BILLING.
    If the log names \"failed calling webhook\" or \"no endpoints available for service\", an
    admission webhook is blocking the deletions (deploy#1592). Clear it and run the teardown again:
      cd ${EKS_DIR} && CONFIRM=reset WORKSPACE=zeroroot-ai-${ENV_NAME} bash scripts/eks-pre-destroy.sh
      make teardown ENV=${ENV_NAME} MODE=${MODE}"
    else
      die "the destroy failed with a non-retryable error. The cluster is half-destroyed and STILL BILLING.
    Read the output above, fix the cause, then run: make teardown ENV=${ENV_NAME} MODE=${MODE}"
    fi
  fi

  sweep_env_zone_records

  log "post-destroy verification: zero billable resources account-wide (ADR-0070)"
  ( cd "$EKS_DIR" && CLUSTER_NAME="$CLUSTER_NAME" bash scripts/eks-post-destroy-verify.sh ) \
    || die "the destroy completed but the account still holds billable resources, or AWS did not answer a class. The verification is fail-closed on purpose (deploy#1393): read the named class above and clear it, then re-run: cd ${EKS_DIR} && bash scripts/eks-post-destroy-verify.sh"

  printf '  ✓ stage 1 destroyed and verified to zero\n'
  printf '  ✓ stage 0 untouched: the durable bucket, the SES relay, the sub-zone and the keyring outlive this\n'
}

if [ "$MODE" = wipe ]; then
  # Nothing is read from the bucket and nothing is written to it. The next
  # recreate bootstraps every store empty, even when the bucket holds a
  # hundred backups (ADR-0083).
  destroy_stage1
  printf '\n\033[0;32mteardown ENV=%s MODE=wipe complete.\033[0m Nothing was kept, and nothing was deleted from the durable bucket.\n' "$ENV_NAME"
  printf 'A recreate from here comes up EMPTY (ADR-0083). There is no backup name to carry.\n'
  exit 0
fi

# ===========================================================================
# MODE=preserve
# ===========================================================================
kubectl cluster-info >/dev/null 2>&1 \
  || die "no reachable cluster for the current kubeconfig context. A preserve teardown has nothing to back up; if the cluster is already gone, MODE=wipe is the mode that says so"

# The backup is taken through the CURRENT kubeconfig context and the destroy
# names the env's workspace. If those are two different clusters, a preserve
# teardown backs one up and destroys another, and reports success. Compare the
# API server the context talks to against the endpoint AWS reports for this
# env's cluster: context NAMES are an operator's choice, endpoints are not.
LIVE_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
EKS_SERVER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.endpoint' --output text 2>/dev/null)"
[ -n "$EKS_SERVER" ] && [ "$EKS_SERVER" != None ] \
  || die "AWS reports no cluster named '${CLUSTER_NAME}' in ${AWS_REGION}. A preserve teardown has nothing to destroy; if stage 1 is already gone, MODE=wipe is the mode that says so"
[ "$LIVE_SERVER" = "$EKS_SERVER" ] \
  || die "the current kubeconfig points at '${LIVE_SERVER:-<none>}' but the cluster this teardown destroys answers at '${EKS_SERVER}'. A preserve teardown would back up one cluster and destroy another. Run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}"

# One name for one teardown: the CNPG Backup CR, the Velero Backup and the
# canary record in the bucket all carry it, so a recreate finds every piece of
# a restore from the single name this script prints. Lower case and dashes
# only: a Velero backup name is a DNS-1123 label.
BACKUP_NAME="preserve-${ENV_NAME}-$(date -u +%Y%m%d-%H%M%S)"

log "backup name for this teardown: ${BACKUP_NAME}"

# Steps 0 through 3 are the substrate-agnostic preserve half
# (scripts/lib/preserve-backup.sh): record the canary, the CNPG base backup,
# the Velero backup from the shipped Schedule, and backup-verify. Any failure
# in there calls die() and leaves the estate standing.
# shellcheck source=lib/preserve-backup.sh
. "$HERE/lib/preserve-backup.sh"
preserve_backup "$BACKUP_NAME"

# --- 4. destroy -----------------------------------------------------------
log "4/4 the backup is proven readable, so the destroy may proceed"
destroy_stage1

# The last line is the backup name, in the form a later recreate takes.
# An agent told to preserve ends its report with it (docs/bringup.md).
printf '\n\033[0;32mteardown ENV=%s MODE=preserve complete.\033[0m Carry this name to the restore (ADR-0083):\n\n' "$ENV_NAME"
printf 'RESTORE_FROM=%s\n' "$BACKUP_NAME"
