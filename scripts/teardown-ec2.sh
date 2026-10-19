#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# teardown-ec2.sh — the teardown verb for an environment whose stage 1 is one
# EC2 instance running k3s (ADR-0083, hosted#159). Staging runs here.
#
# `make teardown ENV=<env> MODE=wipe|preserve` runs this. MODE has no default,
# here and in make. A teardown that picks a mode by omission is how a preserve
# teardown silently becomes a wipe, so this script refuses an unset or unknown
# MODE even though make already did: no other caller may slip one past.
#
#   MODE=wipe      Destroy stage 1 and keep nothing. It deletes NOTHING from
#                  the durable bucket and never reads it: retention is the
#                  bucket's lifecycle rule and nothing else (ADR-0083).
#
#   MODE=preserve  Back up, PROVE the backup readable, then destroy, then
#                  print the backup name. Those four steps are
#                  scripts/lib/preserve-backup.sh — the SAME code every other
#                  substrate runs. Only the destroy differs, and only the
#                  destroy lives here.
#
# THE DESTROY ORDER IS NOT OPTIONAL. The cluster lives inside the instance,
# so Argo CD must go before the instance does. Terraform knows that from the
# module's depends_on, and this script clears the Application finalizers
# first, because an Application waiting on its finalizer blocks a destroy for
# as long as the API answers, which here is until the instance dies.
#
# Environment:
#   MODE             wipe | preserve                       (required)
#   KUBECONFIG_PATH  where the kubeconfig is written       (default: /tmp/<env>-k3s.kubeconfig)
#   API_LOCAL_PORT   the local end of the SSM port forward (default: 6443)
# ---------------------------------------------------------------------------
set -euo pipefail

SUBSTRATE_ENV="${1:-}"
ENV_NAME="${2:-}"
[ -n "$SUBSTRATE_ENV" ] && [ -n "$ENV_NAME" ] || { echo "usage: teardown-ec2.sh <substrate.env> <env>" >&2; exit 2; }
[ -s "$SUBSTRATE_ENV" ] || { echo "FATAL: no substrate.env at ${SUBSTRATE_ENV}. Run make substrate ENV=${ENV_NAME} first (ADR-0083)." >&2; exit 2; }

# The moment this teardown began, as epoch seconds. Only a state lock created
# at or after this can be ours (lib/tf-state-lock.sh).
TEARDOWN_STARTED_EPOCH="$(date -u +%s)"

MODE="${MODE:-}"
case "$MODE" in
  wipe|preserve) ;;
  *) echo "FATAL: MODE must be wipe or preserve. It has no default: a teardown that picks a mode by omission is how a preserve teardown becomes a wipe (ADR-0083)." >&2; exit 2 ;;
esac

NS="${NS:-gibson}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-zeroroot-ai-${ENV_NAME}}"
API_LOCAL_PORT="${API_LOCAL_PORT:-6443}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
EC2_DIR="$REPO/bootstrap/ec2/gibson"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/${ENV_NAME}-k3s.kubeconfig}"
TF_STATE_KEY="tfstate/ec2-gibson/terraform.tfstate"

umask 077
WORK="$(mktemp -d)"
# shellcheck source=lib/ssm-forward.sh
. "$HERE/lib/ssm-forward.sh"
# shellcheck source=lib/ec2-cluster-access.sh
. "$HERE/lib/ec2-cluster-access.sh"
# shellcheck source=lib/targets.sh
. "$HERE/lib/targets.sh"
# shellcheck source=lib/tf-state-lock.sh
. "$HERE/lib/tf-state-lock.sh"


# shellcheck source=lib/acme-challenge.sh
. "$HERE/lib/acme-challenge.sh"
# acme_sweep_env_zone — delete the ACME challenge records of the env sub-zone
# that substrate.env names, and export ZONE_ID so the post-destroy check
# counts them. A substrate.env with no zone has nothing to sweep.
acme_sweep_env_zone() {
  local zone_id zone_name apex
  zone_id="$(grep -E '^ZONE_ID=' "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true)"
  zone_name="$(grep -E '^ZONE_NAME=' "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true)"
  apex="$(grep -E '^APEX_ZONE_NAME=' "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true)"
  if [ -z "$zone_id" ] || [ -z "$zone_name" ]; then
    log "${SUBSTRATE_ENV} names no ZONE_ID/ZONE_NAME, so there is no env zone to sweep"
    return 0
  fi
  log "deleting the ACME challenge records left in the ${zone_name} zone"
  acme_sweep "$zone_id" "$zone_name" "$apex" \
    || die "the ACME challenge records of ${zone_name} could not be deleted (the reason is above). The teardown is idempotent: run it again"
  export ZONE_ID="$zone_id"
}
trap 'ssm_forward_stop; rm -rf "$WORK"' EXIT

log() { printf '\n\033[1;32m▶\033[0m [teardown %s] %s\n' "$MODE" "$*"; }
die() { printf '\033[1;31m✗ [teardown %s] %s\033[0m\n' "$MODE" "$*" >&2; exit 1; }

for tool in kubectl terraform aws python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

durable_bucket() {
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    || die "no usable AWS credentials: aws sts get-caller-identity failed. A destroy without credentials would report success having destroyed nothing"
  printf 'zeroroot-ai-%s-durable-%s' "$ENV_NAME" "$acct"
}

log "terraform init against s3://$(durable_bucket)/${TF_STATE_KEY%/terraform.tfstate}"
terraform -chdir="$EC2_DIR" init -reconfigure -input=false \
  -backend-config="key=${TF_STATE_KEY}" \
  -backend-config="bucket=$(durable_bucket)" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="use_lockfile=true" >/dev/null \
  || die "terraform init failed against the ${ENV_NAME} durable bucket"

INSTANCE_ID="$(terraform -chdir="$EC2_DIR" output -raw instance_id 2>/dev/null || true)"
if [ -z "$INSTANCE_ID" ]; then
  log "no instance in state: stage 1 is already gone"
  [ "$MODE" = preserve ] && die "MODE=preserve has nothing to back up: there is no cluster. Nothing was destroyed"
fi

# NOTHING TO DESTROY is a result with a proof, never a failure to look away
# from. The drill runs this teardown first, on an account that is usually
# clean, and its step used to accept any exit as "nothing to destroy". That
# hid every real failure of the step. So the clean case is decided here: the
# stage 1 state lists nothing, the targets list nothing, and the account
# holds no resource tagged Environment=<env>. Then the teardown exits 0 and
# says so. A state that cannot be read is a failure, not an empty state.
if [ -z "$INSTANCE_ID" ]; then
  STATE_ENTRIES="$(terraform -chdir="$EC2_DIR" state list 2>"$WORK/state-list.err")" \
    || die "could not list the stage 1 state of ${ENV_NAME}, so this teardown cannot tell an empty estate from a broken one: $(tail -1 "$WORK/state-list.err")"
  if [ -z "$STATE_ENTRIES" ]; then
    log "the stage 1 state of ${ENV_NAME} is empty"
    targets_destroy "$ENV_NAME" "$(durable_bucket)" \
      || die "a target under targets/ did not destroy. Read the error above and run the teardown again"
    acme_sweep_env_zone
    "$EC2_DIR/scripts/ec2-post-destroy-verify.sh" "$ENV_NAME" \
      || die "the stage 1 state is empty, and the account still holds resources tagged Environment=${ENV_NAME}, or AWS did not answer. An estate that state does not know is not nothing to destroy"
    printf '\n\033[0;32mteardown ENV=%s MODE=%s: nothing to destroy.\033[0m The state is empty and the account holds no resource tagged Environment=%s.\n' "$ENV_NAME" "$MODE" "$ENV_NAME"
    exit 0
  fi
  log "the stage 1 state still lists $(printf '%s\n' "$STATE_ENTRIES" | grep -c .) entries with no instance: a leftover of a run that died. Destroying it"
fi

# ---------------------------------------------------------------------------
# Reach the cluster, while it still exists.
# ---------------------------------------------------------------------------
# The body is lib/ec2-cluster-access.sh, shared with the recreate and the
# connect verb. This copy had drifted from the recreate's: it inlined the
# send-command poll instead of going through the ssm_run helper.
reach_cluster() { ec2_cluster_connect "$INSTANCE_ID" "$KUBECONFIG_PATH"; }

CLUSTER_REACHED=no
if reach_cluster; then
  CLUSTER_REACHED=yes
  log "the cluster answers through the SSM forward"
else
  [ "$MODE" = preserve ] \
    && die "MODE=preserve cannot reach the cluster, so it cannot prove a backup readable. Nothing was destroyed. Use MODE=wipe only if you accept losing every store"
  log "the cluster does not answer. A wipe destroys the instance either way"
fi

# ---------------------------------------------------------------------------
# preserve — back up and prove it readable, before anything is destroyed.
# ---------------------------------------------------------------------------
BACKUP_NAME=""
if [ "$MODE" = preserve ]; then
  BACKUP_NAME="preserve-${ENV_NAME}-$(date -u +%Y%m%d-%H%M%S)"
  # shellcheck source=lib/preserve-backup.sh
  . "$HERE/lib/preserve-backup.sh"
  preserve_backup "$BACKUP_NAME"
fi

# ---------------------------------------------------------------------------
# The destroy.
#
# The Applications carry the Argo finalizer. While the API still answers, a
# delete blocks on it, and terraform would sit there until the instance died
# under it. Clearing the finalizers first is what makes the destroy finish in
# one pass. This deletes nothing the destroy was not about to delete.
# ---------------------------------------------------------------------------
# The edge certificate, kept for the next bringup (row 9 of the drill path
# audit; scripts/lib/edge-cert.sh). Only a cluster that answers has one to
# read. A preserve teardown stops when it cannot keep it. A wipe goes on: it
# destroys a broken cluster too, and a lost certificate costs only one new
# issuance.
if [ "$CLUSTER_REACHED" = yes ]; then
  # shellcheck source=lib/edge-cert.sh
  . "$HERE/lib/edge-cert.sh"
  EDGE_CERT_SECRET="$(grep -E '^EDGE_CERT_SECRET=' "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true)"
  if [ "$MODE" = preserve ]; then
    edge_cert_store
  elif ! ( edge_cert_store ); then
    log "the edge certificate was not kept (the reason is above). The wipe goes on, and the next bringup asks for a new one"
  fi
fi

if [ "$CLUSTER_REACHED" = yes ]; then
  log "clearing the Argo Application finalizers, so the destroy does not wait on them"
  for app in $(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null || true); do
    kubectl -n argocd patch "$app" --type merge \
      -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  done
fi

# A DEAD CLUSTER MUST STILL BE DESTROYABLE. Argo CD lives inside the instance
# and Terraform orders its destroy before the machine, so a full destroy needs
# a reachable API. The one time that is guaranteed false is the time you most
# want a teardown: the cluster is broken, which is why you are tearing it down.
#
# Measured 2026-09-23: a wipe on an unreachable cluster failed with
# `Kubernetes cluster unreachable: dial tcp 127.0.0.1:6443: connection
# refused` and destroyed NOTHING, leaving the whole estate billing.
#
# So when the cluster does not answer, the in-cluster resources are already
# gone with it. Their state entries are dropped, which is the one case
# ADR-0083's no-retain rule does not cover: these are not AWS resources
# carved out of the blast radius, they are records of objects that no longer
# exist anywhere. The next apply recreates them against the new cluster.
if [ "$CLUSTER_REACHED" != yes ]; then
  log "the cluster is gone, so its own objects are gone with it: dropping their state entries"
  for addr in $(terraform -chdir="$EC2_DIR" state list 2>/dev/null | grep -E '^module\.argocd\.' || true); do
    terraform -chdir="$EC2_DIR" state rm "$addr" >/dev/null 2>&1 || {
      tf_release_own_stale_lock "$EC2_DIR" "$(durable_bucket)" "$TF_STATE_KEY" "$TEARDOWN_STARTED_EPOCH"
      die "could not drop the stale state entry ${addr}. The destroy would fail on an API that no longer exists"
    }
  done
fi

# A target root (targets/<name>/) puts an instance in this VPC and a rule on
# this security group. Stage 1 cannot delete either while the target exists,
# so each target of this environment goes first (lib/targets.sh).
log "destroying the targets that join this network"
targets_destroy "$ENV_NAME" "$(durable_bucket)" \
  || die "a target under targets/ did not destroy. Stage 1 was not touched: its subnet and its security group cannot go while a target is in them. Read the error above and run the teardown again"

log "destroying stage 1: Argo CD, then the instance, its address and its records"
# A destroy that dies keeps its S3 lockfile. The NEXT teardown runs on another
# runner, so the lock is "someone else's" to it and it can never take the
# state. So a failed destroy releases its own lock before it stops.
terraform -chdir="$EC2_DIR" destroy -auto-approve \
  -var-file="envs/${ENV_NAME}.tfvars" \
  -var="kubeconfig_path=${KUBECONFIG_PATH}" || {
  tf_release_own_stale_lock "$EC2_DIR" "$(durable_bucket)" "$TF_STATE_KEY" "$TEARDOWN_STARTED_EPOCH"
  die "terraform destroy failed. Nothing is half-destroyed that a second run will not finish: terraform is idempotent. Read the error above and run the teardown again"
}

# The destroy is the assertion. A state that still holds the instance means
# the destroy reported success having destroyed nothing.
REMAINS="$(terraform -chdir="$EC2_DIR" state list 2>/dev/null | grep -c 'aws_instance.node' || true)"
[ "$REMAINS" = 0 ] \
  || die "terraform destroy returned 0 and the instance is still in state. The estate is NOT gone"

# The ACME challenge records a dead cluster left in the env zone (row 27).
# The post-destroy check below counts them (ZONE_ID).
acme_sweep_env_zone

# State is what terraform knows. The bill is what AWS has. The two part company
# exactly where it costs: an Elastic IP bills MORE unassociated than attached, a
# volume survives a half-destroy, and anything dropped from state with
# `state rm` is invisible here and fully visible on the invoice (ADR-0070). So
# the last word belongs to the account, not the state file.
"$EC2_DIR/scripts/ec2-post-destroy-verify.sh" "$ENV_NAME" \
  || die "the destroy reported success and the account still holds resources tagged Environment=${ENV_NAME}, or AWS did not answer. The teardown is idempotent: run it again"

printf '\n\033[0;32mteardown ENV=%s MODE=%s complete.\033[0m\n' "$ENV_NAME" "$MODE"
if [ "$MODE" = preserve ]; then
  printf '    RESTORE_FROM=%s\n' "$BACKUP_NAME"
else
  printf '    nothing was preserved, and nothing was read from the durable bucket (ADR-0083).\n'
fi
