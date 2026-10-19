#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-instance-type.sh — refuse an instance type that an environment does not
# permit (hosted#448).
#
#   scripts/check-instance-type.sh <env> <instance-type>
#
# An environment permits an override only when it has a list at
# bootstrap/ec2/gibson/envs/<env>.instance-types. The list has one type per
# line. A permanent environment has no list, so it accepts no override.
#
# The recreate verb and the drill workflow both call this script before
# Terraform starts.
#
# Exit 0: the type is on the list. Exit 2: it is not, or the environment has
# no list.
# ---------------------------------------------------------------------------
set -euo pipefail

ENV_NAME="${1:-}"
INSTANCE_TYPE="${2:-}"
[ -n "$ENV_NAME" ] && [ -n "$INSTANCE_TYPE" ] \
  || { echo "usage: check-instance-type.sh <env> <instance-type>" >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVS_DIR="${INSTANCE_TYPES_DIR:-$REPO/bootstrap/ec2/gibson/envs}"
LIST="$ENVS_DIR/${ENV_NAME}.instance-types"

if [ ! -f "$LIST" ]; then
  echo "FATAL: ENV=${ENV_NAME} accepts no INSTANCE_TYPE. Only an environment with a list at ${LIST#"$REPO"/} accepts one." >&2
  exit 2
fi

permitted="$(grep -vE '^[[:space:]]*(#|$)' "$LIST" | tr -d '[:blank:]' || true)"
[ -n "$permitted" ] || { echo "FATAL: ${LIST#"$REPO"/} lists no instance type." >&2; exit 2; }

if ! printf '%s\n' "$permitted" | grep -qxF -- "$INSTANCE_TYPE"; then
  echo "FATAL: INSTANCE_TYPE=${INSTANCE_TYPE} is not permitted for ENV=${ENV_NAME}. Permitted: $(printf '%s' "$permitted" | tr '\n' ' ')" >&2
  exit 2
fi
echo "INSTANCE_TYPE=${INSTANCE_TYPE} is permitted for ENV=${ENV_NAME}"
