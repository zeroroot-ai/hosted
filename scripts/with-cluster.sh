#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# with-cluster.sh — run a command against a cluster that is ALREADY UP
# (ADR-0095). `make with-cluster ENV=<env> CMD='<command>'` calls it.
#
#   with-cluster.sh <env> <command> [args...]
#
# Staging is permanent (ADR-0095), so most things that need to talk to it must
# not recreate it to get a path to the API. Before this script the only path
# was a side effect of `make recreate`: the recreate read the kubeconfig over
# SSM and opened the forward, and anything that wanted to run kubectl had to
# run a bringup first. `promote-staging.yml` did exactly that, and it also
# called `make eks-kubeconfig`, which asks EKS for a cluster named
# zeroroot-ai-staging that has not existed since ADR-0095.
#
# THE FORWARD LIVES EXACTLY AS LONG AS THE COMMAND. The API is not published
# (`api_allow_cidrs = []`), so the only path is an SSM port forward, and a
# forward that outlives its one consumer is a port left bound to a cluster the
# next caller does not expect: lib/ssm-forward.sh refuses to start when the
# port is already held, precisely because that is the failure it saw. So this
# script takes the WHOLE command, not a `connect` the caller follows with
# other steps. In a workflow that means one step, not four.
#
# It never creates, never destroys and never applies. It needs read-only EC2
# and SSM, and the session-manager-plugin on PATH for the forward.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { printf "${GREEN}▶${NC} [with-cluster] %s\n" "$*" >&2; }
die() { printf "${RED}✗${NC} [with-cluster] %s\n" "$*" >&2; exit 1; }

# shellcheck source=lib/ssm-forward.sh
. "$HERE/lib/ssm-forward.sh"
# shellcheck source=lib/ec2-cluster-access.sh
. "$HERE/lib/ec2-cluster-access.sh"

ENV_NAME="${1:-}"; shift || true
if [ -z "$ENV_NAME" ] || [ "$#" -eq 0 ]; then
  die "usage: with-cluster.sh <env> <command> [args...]"
fi
case "$ENV_NAME" in
  staging|drill) ;;
  *) die "ENV=$ENV_NAME has no EC2 cluster in this repo (staging, drill). ENV=prod is EKS and reaches its API with aws eks update-kubeconfig; ENV=kind needs no forward" ;;
esac

AWS_REGION="${AWS_REGION:-us-east-1}"
API_LOCAL_PORT="${API_LOCAL_PORT:-6443}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/${ENV_NAME}-k3s.kubeconfig}"
CLUSTER_NAME="${CLUSTER_NAME:-zeroroot-ai-${ENV_NAME}}"

command -v session-manager-plugin >/dev/null \
  || die "session-manager-plugin is not on PATH, so no port forward can open. The aws CLI shells out to it: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"

# The instance is found by tag, not by terraform output: an output read needs
# `terraform init` against the durable bucket and takes the state lock, and a
# read-only consumer must not queue behind a bringup for a path to the API.
log "looking for the running instance tagged Name=${CLUSTER_NAME} in ${AWS_REGION}"
mapfile -t IDS < <(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$')

case "${#IDS[@]}" in
  0) die "no RUNNING instance tagged Name=${CLUSTER_NAME} in ${AWS_REGION}. ENV=${ENV_NAME} is not up. Stand it up with the recreate verb, which is a billable apply" ;;
  1) ;;
  *) die "${#IDS[@]} running instances carry Name=${CLUSTER_NAME} (${IDS[*]}). One of them is a leftover, and forwarding to the wrong one reads the wrong cluster. Resolve it before running anything against ${ENV_NAME}" ;;
esac
INSTANCE_ID="${IDS[0]}"

trap 'ssm_forward_stop' EXIT
log "reaching ${INSTANCE_ID} over SSM, API on 127.0.0.1:${API_LOCAL_PORT}"
ec2_cluster_connect "$INSTANCE_ID" "$KUBECONFIG_PATH" \
  || die "could not reach the API of ${INSTANCE_ID}. The instance is running: check the SSM agent, the instance profile, and that k3s is up"
log "the API answers; running: $*"

"$@"
status=$?
log "command exited ${status}; the forward closes with this process"
exit "$status"
