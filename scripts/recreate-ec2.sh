#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# recreate-ec2.sh — the recreate verb for an environment whose stage 1 is one
# EC2 instance running k3s (ADR-0083, hosted#159). Staging runs here.
#
# `make recreate ENV=staging [RESTORE_FROM=<name>]` runs preflight and then
# this script. It is the plain-cluster twin of scripts/recreate-aws.sh, and
# the two share everything that is not the cluster itself:
#
#   lib/bringup-before-cluster.sh   stage 0 readers, the archive gate, the
#                                   named-backup check
#   lib/bringup-after-cluster.sh    ToolHive, the keyring, the restore order,
#                                   stage 2, the WAL assertion
#
#   Stage 1  the cluster: bootstrap/ec2/gibson. Phase 1 builds the network,
#            the instance and the DNS records. The instance's own cloud-init
#            installs k3s, with no network plugin. This script
#            then installs Cilium (hosted#436). Phase 2 installs Argo CD,
#            from the shared module every substrate uses.
#
#   Stage 2  the platform: Argo CD syncs the umbrella from the gitops overlay
#            this env names, and the recreate waits for Synced+Healthy.
#
# THE KUBECONFIG NEVER CROSSES THE INTERNET ON A PORT. The API server is not
# published: the security group opens 80 and 443 only. This script reads the
# kubeconfig off the instance through SSM, and reaches the API through an SSM
# port forward. An operator with no AWS credential reaches nothing.
#
# RESTORE_FROM=<name> restores exactly the backup named and nothing else, the
# same contract as every other substrate (ADR-0083).
#
# Environment:
#   RESTORE_FROM     the backup name to restore            (default: none)
#   INSTANCE_TYPE    an instance type from envs/<env>.instance-types
#                    (default: the type of envs/<env>.tfvars)
#   NODE_COUNT       1 or 2, from envs/<env>.node-counts (default: 1).
#                    2 adds an agent node of the same type (hosted#453)
#   NS               the platform namespace                (default: gibson)
#   KUBECONFIG_PATH  where the kubeconfig is written       (default: /tmp/<env>-k3s.kubeconfig)
#   API_LOCAL_PORT   the local end of the SSM port forward (default: 6443)
#   NODE_READY_TIMEOUT  how long cloud-init may take       (default: 900)
#   RESTORE_TIMEOUT  optional: one bound for every restore wait, instead
#                    of the per-step bounds of lib/velero-restore.sh
#   GITOPS_REF       the hosted ref that Argo CD tracks   (default: main)
#   WAIT_APPS_TIMEOUT / WAIT_APPS_STALL  seconds           (defaults 3600 / 1200)
# ---------------------------------------------------------------------------
set -euo pipefail

SUBSTRATE_ENV="${1:-}"
ENV_NAME="${2:-}"
[ -n "$SUBSTRATE_ENV" ] && [ -n "$ENV_NAME" ] || { echo "usage: recreate-ec2.sh <substrate.env> <env>" >&2; exit 2; }
[ -s "$SUBSTRATE_ENV" ] || { echo "FATAL: no substrate.env at ${SUBSTRATE_ENV}. Run make substrate ENV=${ENV_NAME} first (ADR-0083)." >&2; exit 2; }

RESTORE_FROM="${RESTORE_FROM:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-}"
NODE_COUNT="${NODE_COUNT:-}"
NS="${NS:-gibson}"
VELERO_NS="${VELERO_NS:-velero}"
TOOLHIVE_VERSION="${TOOLHIVE_VERSION:-0.12.1}"
GITOPS_REF="${GITOPS_REF:-main}"
GITOPS_PATH="${GITOPS_PATH:-gitops/envs/${ENV_NAME}}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-zeroroot-ai-${ENV_NAME}}"
WAIT_APPS_TIMEOUT="${WAIT_APPS_TIMEOUT:-3600}"
WAIT_APPS_STALL="${WAIT_APPS_STALL:-1200}"
API_LOCAL_PORT="${API_LOCAL_PORT:-6443}"
NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-900}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
EC2_DIR="$REPO/bootstrap/ec2/gibson"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/${ENV_NAME}-k3s.kubeconfig}"

log() { printf '\n\033[1;32m▶\033[0m [recreate %s] %s\n' "$ENV_NAME" "$*"; }
die() { printf '\033[1;31m✗ [recreate %s] %s\033[0m\n' "$ENV_NAME" "$*" >&2; exit 1; }

# An instance type that the environment does not permit fails here, before
# Terraform starts (hosted#448). A permanent environment has no list, so it
# accepts no type.
if [ -n "$INSTANCE_TYPE" ]; then
  "$HERE/check-instance-type.sh" "$ENV_NAME" "$INSTANCE_TYPE" || exit 2
fi
# A node count that the environment does not permit fails here too
# (hosted#453). Only the drill environment has a list.
if [ -n "$NODE_COUNT" ]; then
  "$HERE/check-node-count.sh" "$ENV_NAME" "$NODE_COUNT" || exit 2
fi

for tool in kubectl helm terraform aws curl python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done
# The belief trainer copy needs skopeo copy --all. Check it here, before
# any apply, not at the copy (hosted#602).
# shellcheck source=lib/skopeo.sh
. "$HERE/lib/skopeo.sh"
skopeo_reason="$(skopeo_missing_all)" || die "$skopeo_reason"
aws ssm help >/dev/null 2>&1 \
  || die "the AWS CLI has no ssm command. This recreate reaches the instance only through SSM"

# A cluster of this env that is already up: a recreate that stopped in
# stage 2 left it running. The archive gate accepts its own WAL (hosted#624).
LIVE_CLUSTER_SINCE="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=pending,running" \
    --query 'min(Reservations[].Instances[].LaunchTime)' --output text 2>/dev/null || true)"
case "$LIVE_CLUSTER_SINCE" in None|null) LIVE_CLUSTER_SINCE="" ;; esac

# The stage 0 readers and the refusals that need no cluster. Shared with the
# EKS recreate (scripts/recreate-aws.sh).
# shellcheck source=lib/bringup-before-cluster.sh
. "$HERE/lib/bringup-before-cluster.sh"
# shellcheck source=lib/ssm-forward.sh
. "$HERE/lib/ssm-forward.sh"
# shellcheck source=lib/coredns-platform-hosts.sh
. "$HERE/lib/coredns-platform-hosts.sh"
# shellcheck source=lib/ec2-cluster-access.sh
. "$HERE/lib/ec2-cluster-access.sh"
# shellcheck source=lib/cilium.sh
. "$HERE/lib/cilium.sh"
# shellcheck source=lib/targets.sh
. "$HERE/lib/targets.sh"

# ---------------------------------------------------------------------------
# Stage 1 — the cluster.
# ---------------------------------------------------------------------------
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "no AWS identity. Stage 1 needs a credential for this environment's account"

# The belief trainer image that the overlay pins, copied into the ECR
# repository of the env (gibson#31). The trainer CronJob of a tenant has no
# pull secret, so the node pulls this copy with its instance role.
GITOPS_PATH="$GITOPS_PATH" "$HERE/belief-trainer-image.sh" "$SUBSTRATE_ENV" "$ENV_NAME" \
  || die "the belief trainer image is not in the ECR repository of ${ENV_NAME}"

log "stage 1: terraform init against s3://zeroroot-ai-${ENV_NAME}-durable-${ACCOUNT}/tfstate/ec2-gibson"
terraform -chdir="$EC2_DIR" init -reconfigure -input=false \
  -backend-config="key=tfstate/ec2-gibson/terraform.tfstate" \
  -backend-config="bucket=zeroroot-ai-${ENV_NAME}-durable-${ACCOUNT}" \
  -backend-config="region=${AWS_REGION}" >/dev/null \
  || die "terraform init failed against the ${ENV_NAME} durable bucket"

TF_ARGS=( -var-file="envs/${ENV_NAME}.tfvars" )
# The ref that Argo CD tracks (GITOPS_REF). The drill passes the commit of
# its run, so the app-of-apps reads the tree the run started from (drill
# sweep row 21).
TF_ARGS+=( -var="git_revision=${GITOPS_REF}" )
# The type is in TF_ARGS, so each apply of this run uses the same type.
if [ -n "$INSTANCE_TYPE" ]; then
  TF_ARGS+=( -var="instance_type=${INSTANCE_TYPE}" )
  log "stage 1: the instance type is ${INSTANCE_TYPE}"
fi
if [ -n "$NODE_COUNT" ]; then
  TF_ARGS+=( -var="node_count=${NODE_COUNT}" )
  log "stage 1: the cluster has ${NODE_COUNT} node(s)"
fi
# A restore holds the app-of-apps back until the secret store is home
# (ADR-0083). With no RESTORE_FROM the platform is created straight away.
TF_APP_OF_APPS=()
if [ -n "$RESTORE_FROM" ]; then
  TF_APP_OF_APPS=( -var=bootstrap_app_of_apps=false )
  log "stage 1: the app-of-apps is held back until the secret store is restored (ADR-0083)"
fi

# Phase 1 is every AWS resource. The Kubernetes providers read a kubeconfig
# that does not exist yet, so nothing of theirs may be in this plan.
#
# THE TARGET NAMES THE PROVIDER'S WORK, NEVER THE INSTANCE'S. Terraform
# creates a target and its dependencies, and an instance depends on a
# security group but not on its RULES, on a subnet but not on its ROUTE, and
# on an instance profile but not on its POLICY. Targeting the instance built
# a machine sealed inside a network with no egress and no credentials, three
# times, and reported success each time (2026-09-22). So phase 1 targets
# every AWS resource this root declares, read from the configuration rather
# than typed out here: a resource added later is covered without anyone
# remembering to add it.
log "stage 1: phase 1 — the network, the instance, its address and its records"
mapfile -t AWS_TARGETS < <(
  terraform -chdir="$EC2_DIR" graph -type=plan 2>/dev/null \
    | grep -oE '"\[root\] (aws_[a-z0-9_]+\.[a-z0-9_]+)' \
    | sed 's/.*\[root\] //' | sort -u
)
[ "${#AWS_TARGETS[@]}" -gt 0 ] \
  || die "stage 1 phase 1: the configuration declares no aws_ resource, which cannot be right. Refusing to apply a plan that would include the Kubernetes providers against a cluster that does not exist"
TF_TARGETS=()
for t in "${AWS_TARGETS[@]}"; do TF_TARGETS+=( "-target=$t" ); done
log "stage 1: phase 1 applies ${#AWS_TARGETS[@]} AWS resources"
terraform -chdir="$EC2_DIR" apply -auto-approve "${TF_ARGS[@]}" "${TF_TARGETS[@]}" \
  || die "stage 1 phase 1 failed. Nothing was destroyed; fix the error above and run the recreate again — terraform is idempotent and skips what already converged"

INSTANCE_ID="$(terraform -chdir="$EC2_DIR" output -raw instance_id)" \
  || die "stage 1 applied but reported no instance id"
NODE_IP="$(terraform -chdir="$EC2_DIR" output -raw node_public_ip)" \
  || die "stage 1 applied but reported no address"
log "stage 1: instance ${INSTANCE_ID} at ${NODE_IP}"

# The targets of this environment (targets/<name>/, for example the
# kubernetes-goat node of the demo, gibson#496) join the network that phase 1
# just made, so they come up here, beside the platform node, from the same
# durable bucket. The teardown destroys them first (lib/targets.sh).
log "stage 1: the targets that join this network"
targets_apply "$ENV_NAME" "zeroroot-ai-${ENV_NAME}-durable-${ACCOUNT}" \
  || die "a target under targets/ did not come up. The platform node is up. Read the error above and run the recreate again: terraform is idempotent"

# ---------------------------------------------------------------------------
# The node finishes its own bringup. The marker is written LAST by
# cloud-init, so its presence means k3s is installed.
#
# A bringup that reads the kubeconfig too early gets a file k3s has not
# finished writing, and the failure lands much later as an unreadable
# certificate.
# ---------------------------------------------------------------------------
# The instance id is this script's, so the wrapper supplies it. The body is
# lib/ec2-cluster-access.sh, shared with the teardown and the connect verb.
ssm_run() { ec2_ssm_run "$INSTANCE_ID" "$1"; }

log "stage 1: waiting for the node to finish its own bringup (k3s with no network plugin)"
deadline=$(( $(date +%s) + NODE_READY_TIMEOUT ))
until ssm_run 'test -f /var/lib/rancher/k3s/server/node-init.done && echo ready' 2>/dev/null | grep -q ready; do
  [ "$(date +%s)" -lt "$deadline" ] || {
    ssm_run 'tail -40 /var/log/node-init.log' >&2 2>/dev/null || true
    die "the node did not finish cloud-init within ${NODE_READY_TIMEOUT}s. The log above is /var/log/node-init.log on ${INSTANCE_ID}"
  }
  printf '  waiting for node-init on %s          \r' "$INSTANCE_ID"
  sleep 15
done
log "stage 1: the node reports k3s installed"

# A type with nested virtualization must give the node /dev/kvm (hosted#448).
# The output reads the instance's own cpu_options, so this check and the
# instance agree. An output that cannot be read stops the bringup: on
# 2026-10-06 a missing output skipped the check in silence.
NESTED_VIRT="$(terraform -chdir="$EC2_DIR" output -raw nested_virtualization)" \
  || die "stage 1 applied but reported no nested_virtualization output, so the /dev/kvm check cannot decide"
case "$NESTED_VIRT" in
  true|false) ;;
  *) die "the nested_virtualization output is '${NESTED_VIRT}', not true or false" ;;
esac
if [ "$NESTED_VIRT" = "true" ]; then
  ssm_run 'test -c /dev/kvm && echo kvm-present' 2>/dev/null | grep -q kvm-present \
    || die "the instance type supports nested virtualization, but ${INSTANCE_ID} has no /dev/kvm"
  log "stage 1: the node has /dev/kvm"
fi

# ---------------------------------------------------------------------------
# The kubeconfig, and the way this run reaches the API.
#
# The instance publishes no API port, so the kubeconfig names a local port
# that an SSM session forwards. The forward is this run's own, and it is torn
# down with the run.
# ---------------------------------------------------------------------------
log "stage 1: reading the kubeconfig from ${INSTANCE_ID} and forwarding the API over SSM"
trap 'ssm_forward_stop; rm -rf "$WORK"' EXIT
ec2_cluster_connect "$INSTANCE_ID" "$KUBECONFIG_PATH" \
  || die "could not reach the API of ${INSTANCE_ID} through SSM on 127.0.0.1:${API_LOCAL_PORT}. The session-manager-plugin must be installed for start-session to work, the instance profile must allow ssm, and k3s must be up"
log "stage 1: the API answers through the forward"

# The network plugin (ADR-0083, hosted#436). k3s started with flannel off, so
# the node is NotReady and no pod runs until Cilium is in. It goes in before
# CoreDNS gets its record and before Argo CD, because both need a pod network.
# The bringup stops here when the CRD is absent, when an agent is not ready,
# or when a policy with a host name does not permit one host and refuse
# another.
log "stage 1: Cilium $(cilium_version) is the network plugin"
cilium_install k3s \
  || die "Cilium did not install on ${INSTANCE_ID}. The node has no network plugin, so no pod can start"
# Every node the root declares is in the cluster before the wait below reads
# "all" (hosted#453). The agent joins on its own clock: it boots beside the
# server and retries the join until the server answers. A wait on "all" that
# ran before the join would pass on the server alone.
WANT_NODES="$(terraform -chdir="$EC2_DIR" output -raw node_count)" \
  || die "stage 1 applied but reported no node_count output"
log "stage 1: waiting for ${WANT_NODES} node(s) to join"
deadline=$(( $(date +%s) + NODE_READY_TIMEOUT ))
until [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge "$WANT_NODES" ]; do
  [ "$(date +%s)" -lt "$deadline" ] || {
    kubectl get nodes >&2 2>/dev/null || true
    die "only $(kubectl get nodes --no-headers 2>/dev/null | wc -l) of ${WANT_NODES} node(s) joined within ${NODE_READY_TIMEOUT}s. The agent log is /var/log/node-init.log on each agent instance (terraform output agent_instance_ids)"
  }
  sleep 15
done
[ "$(kubectl get nodes --no-headers | wc -l)" -eq "$WANT_NODES" ] \
  || die "the cluster has $(kubectl get nodes --no-headers | wc -l) nodes and the root declares ${WANT_NODES}"
kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null \
  || die "a node did not get Ready after the Cilium install"
log "stage 1: ${WANT_NODES} node(s) Ready"
cilium_verify \
  || die "Cilium is not ready on ${INSTANCE_ID}"
cilium_prove_fqdn_policy \
  || die "Cilium does not enforce a policy with a host name on ${INSTANCE_ID}"

# CoreDNS maps the platform's public hosts to the Envoy Service (hosted#397).
# Public DNS answers for api.<domain> here too, but that answer is the
# instance's Elastic IP: an in-cluster caller would leave the node and come
# back through the edge, and every such caller would share one source address
# for rate limits. k3s imports kube-system/coredns-custom into its server
# block, so the record is one key in that ConfigMap. It is applied before
# Argo CD, so the first workload that asks already gets the Service. The
# domain comes from the overlay this environment installs.
PLATFORM_DOMAIN="$(values_domain "$REPO/gitops/envs/${ENV_NAME}/values.yaml")" \
  || die "gitops/envs/${ENV_NAME}/values.yaml names no global.domain; CoreDNS cannot be given a record for the platform's hosts"
ENVOY_SERVICE_FQDN="gibson-envoy.${NS:-gibson}.svc.cluster.local"
log "stage 1: CoreDNS maps api.${PLATFORM_DOMAIN} and app.${PLATFORM_DOMAIN} to ${ENVOY_SERVICE_FQDN}"
coredns_publish_platform_hosts custom "$ENVOY_SERVICE_FQDN" "api.${PLATFORM_DOMAIN}" "app.${PLATFORM_DOMAIN}" \
  || die "CoreDNS did not take the record for ${PLATFORM_DOMAIN} (kube-system/coredns-custom)"

# Phase 2 is Argo CD, which needs the kubeconfig phase 1 could not have.
log "stage 1: phase 2 — Argo CD"
terraform -chdir="$EC2_DIR" apply -auto-approve "${TF_ARGS[@]}" "${TF_APP_OF_APPS[@]}" \
  -var="kubeconfig_path=${KUBECONFIG_PATH}" \
  || die "stage 1 phase 2 failed. The cluster is up; fix the error above and run the recreate again"

# ---------------------------------------------------------------------------
# The substrate-specific step the shared tail calls back into.
# ---------------------------------------------------------------------------

stage1_enable_app_of_apps() {
  terraform -chdir="$EC2_DIR" apply -auto-approve "${TF_ARGS[@]}" \
    -var="kubeconfig_path=${KUBECONFIG_PATH}"
}

# Everything from here is substrate-neutral and shared with the EKS recreate.
# shellcheck source=lib/bringup-after-cluster.sh
. "$HERE/lib/bringup-after-cluster.sh"
