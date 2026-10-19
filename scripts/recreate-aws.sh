#!/usr/bin/env bash
# recreate-aws.sh — the recreate verb for ENV=staging and ENV=prod
# (ADR-0083, deploy#1746). `make recreate ENV=<env> [RESTORE_FROM=<name>]`
# runs preflight and then this script. The deleted `eks-up` / `eks-bringup`
# targets did the bringup half.
#
# A recreate stands the environment up from nothing (docs/bringup.md § A
# recreate, step by step).
#
#   Stage 1  the cluster: bootstrap/eks/gibson, the thin stage 1 (deploy#1744) — the
#            VPC, the EKS cluster, the gp3 default StorageClass, the AWS load
#            balancer controller, Karpenter, metrics-server and Argo CD
#            (ADR-0083). Applied in three phases, because
#            the kubernetes/helm/kubectl providers read module.cluster
#            outputs and cannot plan against an API server that does not
#            exist yet. This stage also writes the bringup keyring into the
#            cluster (scripts/keyring-to-cluster.sh), the same one script
#            ENV=kind uses.
#   Stage 2  the platform: Argo CD syncs the umbrella from the gitops repo
#            overlay this env names (app_of_apps_path). The recreate waits
#            for every Application to reach Synced+Healthy.
#
# RESTORE_FROM=<name> restores exactly the backup named on the command line
# and nothing else. With NO name every store bootstraps empty, always, even
# when the bucket holds a hundred backups (ADR-0083). There is no `latest`,
# no auto-detect and no default that turns the restore on. The restore steps
# are scripts/lib/velero-restore.sh — the SAME code ENV=kind runs.
#
# THE ONE ORDERING RULE. The secret store comes back BEFORE the platform
# Application exists. Velero moves volume data back through a pod, so a store
# whose pod Argo has already created keeps the empty volume it was given
# (measured on kind, deploy#1739). On kind the recreate owns that order
# directly: the two CRD releases, then velero, then the restore, then the
# umbrella. On
# an AWS environment stage 2 is the gitops overlay and the app-of-apps brings
# all three, so the recreate holds the app-of-apps back instead
# (bootstrap_app_of_apps=false), creates the two Applications the restore
# needs straight from the overlay, restores, and only then applies the root
# again so the app-of-apps — and with it the platform Application — appears.
# The order is identical; only who applies the first two Applications differs.
#
# THE API ENDPOINT. bootstrap/eks/gibson gives the cluster a public API endpoint only
# when operator_cidrs is non-empty (modules/cluster/main.tf). A recreate has
# to reach the API server to write the keyring, to converge Argo and to
# restore, so the verb pins operator_cidrs to the CALLER's own public /32,
# discovered at apply time. A GitHub-hosted runner has no fixed egress
# address, which is exactly why this is discovered and not configured.
#
# Usage: recreate-aws.sh <substrate.env> <env>   (make recreate ENV=<env> calls it)
# Env:
#   RESTORE_FROM     refused here, see above. Absent means every store
#                    bootstraps empty (ADR-0083)
#   NS               release namespace                  (default: gibson)
#   AWS_REGION       the cluster region                 (default: us-east-1)
#   EKS_KUBECONFIG   where the kubeconfig is written    (default: /tmp/eks-<env>.kubeconfig)
#   OPERATOR_CIDRS   override the discovered /32, comma separated
#   RESTORE_TIMEOUT  optional: one bound for every restore wait, instead
#                    of the per-step bounds of lib/velero-restore.sh
#   WAIT_APPS_TIMEOUT / WAIT_APPS_STALL   seconds       (defaults 3600 / 1200)
set -euo pipefail

SUBSTRATE_ENV="${1:-}"
ENV_NAME="${2:-}"
[ -n "$SUBSTRATE_ENV" ] && [ -n "$ENV_NAME" ] || { echo "usage: recreate-aws.sh <substrate.env> <env>" >&2; exit 2; }
[ -s "$SUBSTRATE_ENV" ] || { echo "FATAL: no substrate.env at ${SUBSTRATE_ENV}. Run make substrate ENV=${ENV_NAME} first (ADR-0083)." >&2; exit 2; }

RESTORE_FROM="${RESTORE_FROM:-}"
NS="${NS:-gibson}"
VELERO_NS="${VELERO_NS:-velero}"
TOOLHIVE_VERSION="${TOOLHIVE_VERSION:-0.12.1}"
# The repo and the overlay path this env's stage 2 comes from. The Argo tree
# lives in this repo under gitops/ since ADR-0086. A
# restore reads two Application manifests straight out of it, so it needs the
# same three values the terraform root passes to Argo.
GITOPS_PATH="${GITOPS_PATH:-gitops/envs/${ENV_NAME}}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-zeroroot-ai-${ENV_NAME}}"
WAIT_APPS_TIMEOUT="${WAIT_APPS_TIMEOUT:-3600}"
WAIT_APPS_STALL="${WAIT_APPS_STALL:-1200}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
EKS_DIR="$REPO/bootstrap/eks/gibson"
EKS_KUBECONFIG="${EKS_KUBECONFIG:-/tmp/eks-${ENV_NAME}.kubeconfig}"

log() { printf '\n\033[1;32m▶\033[0m [recreate %s] %s\n' "$ENV_NAME" "$*"; }
die() { printf '\033[1;31m✗ [recreate %s] %s\033[0m\n' "$ENV_NAME" "$*" >&2; exit 1; }

for tool in kubectl helm terraform aws curl python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done
# The belief trainer copy needs skopeo copy --all. Check it here, before
# any apply, not at the copy (hosted#602).
# shellcheck source=lib/skopeo.sh
. "$HERE/lib/skopeo.sh"
skopeo_reason="$(skopeo_missing_all)" || die "$skopeo_reason"

# A cluster of this env that is already up: a recreate that stopped in
# stage 2 left it running. The archive gate accepts its own WAL (hosted#624).
LIVE_CLUSTER_SINCE="$(aws eks describe-cluster --region "$AWS_REGION" --name "$CLUSTER_NAME" \
    --query 'cluster.createdAt' --output text 2>/dev/null || true)"
case "$LIVE_CLUSTER_SINCE" in None|null) LIVE_CLUSTER_SINCE="" ;; esac

# The stage 0 readers and the refusals that need no cluster. Shared with the
# plain-cluster recreate (scripts/recreate-ec2.sh).
# shellcheck source=lib/bringup-before-cluster.sh
. "$HERE/lib/bringup-before-cluster.sh"
# shellcheck source=lib/cilium.sh
. "$HERE/lib/cilium.sh"


# ---------------------------------------------------------------------------
# Stage 1 — the cluster.
# ---------------------------------------------------------------------------
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "no usable AWS credentials: aws sts get-caller-identity failed"

# The belief trainer image that the overlay pins, copied into the ECR
# repository of the env (gibson#31). The trainer CronJob of a tenant has no
# pull secret, so the node pulls this copy with its instance role.
GITOPS_PATH="$GITOPS_PATH" "$HERE/belief-trainer-image.sh" "$SUBSTRATE_ENV" "$ENV_NAME" \
  || die "the belief trainer image is not in the ECR repository of ${ENV_NAME}"

log "stage 1: terraform init against s3://zeroroot-ai-${ENV_NAME}-durable-${ACCOUNT}/tfstate/eks-gibson"
terraform -chdir="$EKS_DIR" init -reconfigure -input=false \
  -backend-config="key=tfstate/eks-gibson/terraform.tfstate" \
  -backend-config="bucket=zeroroot-ai-${ENV_NAME}-durable-${ACCOUNT}" \
  -backend-config="use_lockfile=true" >/dev/null \
  || die "terraform init failed against the ${ENV_NAME} durable bucket"

# The caller's own public address, so the API endpoint answers this run. A
# recreate that cannot reach its own cluster cannot write the keyring, cannot
# converge Argo and cannot restore, and would report a green stage 1 over an
# environment nobody can use.
if [ -n "${OPERATOR_CIDRS:-}" ]; then
  CIDRS="$OPERATOR_CIDRS"
else
  MYIP="$(curl -fsS --max-time 15 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
  case "$MYIP" in
    *[!0-9.]*|'') die "could not discover this runner's public address (checkip.amazonaws.com answered '${MYIP:-<nothing>}'). Pass OPERATOR_CIDRS=<a.b.c.d/32> to say which address the API endpoint must answer" ;;
  esac
  CIDRS="${MYIP}/32"
fi
log "stage 1: the API endpoint answers ${CIDRS} (operator_cidrs)"

# ArgoCD's credential for cloning the private gitops repo is no longer a
# Terraform input (ADR-0083). keyring-to-cluster.sh seeds the zeroroot-ai-creds
# repo-creds Secret from the org GitHub App after this apply installs ArgoCD,
# and ArgoCD retries the app-of-apps sync until that Secret appears. The
# umbrella chart's OCI package is public, so the repo-server pulls it anonymously.

TF_ARGS=( -var-file="envs/${ENV_NAME}.tfvars" -var "operator_cidrs=[\"${CIDRS}\"]" -input=false )

# On a restore the app-of-apps is held back until the secret store is home.
# Everything else in stage 1 applies exactly as it does on an empty bringup.
TF_APP_OF_APPS=( )
if [ -n "$RESTORE_FROM" ]; then
  TF_APP_OF_APPS=( -var "bootstrap_app_of_apps=false" )
  log "stage 1: the app-of-apps is held back until the secret store is restored (ADR-0083)"
fi

# The three phases break the provider chicken-and-egg: the kubernetes, helm
# and kubectl providers read module.cluster outputs, so the cluster must exist
# before anything that uses them plans against a real API server. There is no
# import step between them: nothing outlives a teardown in this workspace
# (ADR-0083), so a cold apply creates every resource and there is nothing
# live-in-AWS-but-absent-from-state to re-attach.
apply_phase() {
  local num="$1" name="$2"; shift 2
  local targets=()
  local t
  for t in "$@"; do targets+=( "-target=$t" ); done
  log "stage 1: phase ${num} — ${name}"
  if [ "${#targets[@]}" -eq 0 ]; then
    terraform -chdir="$EKS_DIR" apply -auto-approve "${TF_ARGS[@]}" "${TF_APP_OF_APPS[@]}" \
      || die "stage 1 phase ${num} (${name}) failed. Nothing was destroyed; fix the error above and run the recreate again — terraform is idempotent and skips what already converged"
  else
    terraform -chdir="$EKS_DIR" apply -auto-approve "${TF_ARGS[@]}" "${TF_APP_OF_APPS[@]}" "${targets[@]}" \
      || die "stage 1 phase ${num} (${name}) failed. Nothing was destroyed; fix the error above and run the recreate again — terraform is idempotent and skips what already converged"
  fi
}

apply_phase 1 Network    module.network
apply_phase 2 Cluster    module.cluster module.iam_irsa
apply_phase 3 "Full apply"

log "stage 1: kubeconfig for ${CLUSTER_NAME} → ${EKS_KUBECONFIG}"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --kubeconfig "$EKS_KUBECONFIG" >/dev/null \
  || die "could not write a kubeconfig for ${CLUSTER_NAME}"
export KUBECONFIG="$EKS_KUBECONFIG"
kubectl cluster-info >/dev/null 2>&1 \
  || die "the cluster is up but its API server does not answer this runner. operator_cidrs was ${CIDRS}; if this runner's egress address changed mid-apply, run the recreate again"

# The network plugin (ADR-0083, hosted#436). Stage 1 installed Cilium in ENI
# mode before the node groups (bootstrap/eks/gibson/modules/cluster). The
# bringup stops here when the CRD is absent, when an agent is not ready, or
# when a policy with a host name does not permit one host and refuse another.
log "stage 1: Cilium $(cilium_version) is the network plugin"
cilium_verify \
  || die "Cilium is not ready on ${CLUSTER_NAME}"
cilium_prove_fqdn_policy \
  || die "Cilium does not enforce a policy with a host name on ${CLUSTER_NAME}"

# Each node of the sandbox fleet exposes /dev/kvm (hosted#446). A fleet node
# without it runs no sandbox, and nothing else would say so.
log "stage 1: each sandbox fleet node exposes /dev/kvm"
bash "$EKS_DIR/scripts/verify-kvm-nodes.sh" \
  || die "a sandbox fleet node of ${CLUSTER_NAME} has no /dev/kvm"

# ---------------------------------------------------------------------------
# The substrate-specific step the shared tail calls back into.
# ---------------------------------------------------------------------------

# The app-of-apps, created after a restore has put the secret store home.
stage1_enable_app_of_apps() {
  terraform -chdir="$EKS_DIR" apply -auto-approve "${TF_ARGS[@]}"
}

# shellcheck disable=SC2034  # read by lib/bringup-after-cluster.sh
KUBECONFIG_PATH="$EKS_KUBECONFIG"

# Everything from here is substrate-neutral and shared with the plain-cluster
# recreate (scripts/recreate-ec2.sh).
# shellcheck source=lib/bringup-after-cluster.sh
. "$HERE/lib/bringup-after-cluster.sh"
