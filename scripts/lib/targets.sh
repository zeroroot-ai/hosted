#!/usr/bin/env bash
# targets.sh — the roots under targets/ go before the stage 1 network they join.
#
# A target (targets/<name>/, for example kubernetes-goat) is one instance in the
# VPC and the subnet of an EC2 stage 1 root, and its security group references
# the platform node's security group. Stage 1 cannot destroy its subnet, its
# internet gateway or its security group while a target instance is in them.
#
# Measured 2026-10-06 on the staging rebuild: the teardown destroyed the
# platform instance, then waited 20 minutes on the subnet and the gateway and
# stopped on `DependencyViolation` for the node security group. The goat target
# was still running in that subnet, and no verb knew that it existed.
#
# So the EC2 teardown calls targets_destroy first. Each target root that has an
# envs/<env>.tfvars is destroyed from its own state, which lives in the
# environment's durable bucket at tfstate/targets/<name>/terraform.tfstate.
# A root with an empty state is skipped, so a second teardown run is quiet.
#
# The caller supplies:
#   REPO        the repository root
#   AWS_REGION  the region of the durable bucket
#   log()       prints one progress line

# targets_state_key <name> — the state key of one target root.
targets_state_key() { printf 'tfstate/targets/%s/terraform.tfstate' "$1"; }

# targets_destroy <env> <bucket> — destroy each target root of <env>.
# Returns non-zero on the first root that does not destroy.
targets_destroy() {
  local env="$1" bucket="$2" dir name live
  for dir in "$REPO"/targets/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    [ -f "${dir}envs/${env}.tfvars" ] || continue
    terraform -chdir="$dir" init -reconfigure -input=false \
      -backend-config="key=$(targets_state_key "$name")" \
      -backend-config="bucket=${bucket}" \
      -backend-config="region=${AWS_REGION}" \
      -backend-config="use_lockfile=true" >/dev/null \
      || { echo "target ${name}: terraform init failed against s3://${bucket}" >&2; return 1; }
    live="$(terraform -chdir="$dir" state list 2>/dev/null | grep -vc '^data\.' || true)"
    if [ "${live:-0}" = 0 ]; then
      log "target ${name}: nothing in state for ${env}"
      continue
    fi
    log "target ${name}: destroying ${live} resources, before the network it joins"
    terraform -chdir="$dir" destroy -auto-approve -input=false \
      -var-file="envs/${env}.tfvars" \
      || { echo "target ${name}: terraform destroy failed" >&2; return 1; }
  done
}
