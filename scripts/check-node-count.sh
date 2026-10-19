#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-node-count.sh — refuse a node count that an environment does not
# permit (hosted#453).
#
#   scripts/check-node-count.sh <env> <count>
#
# An environment permits a count only when it has a list at
# bootstrap/ec2/gibson/envs/<env>.node-counts. The list has one count per
# line. A permanent environment has no list, so it accepts no count.
#
# The recreate verb and the drill workflow both call this script before
# Terraform starts. The Terraform variable has its own validation, and this
# script fires first, before a credential is involved.
#
# Exit 0: the count is on the list. Exit 2: it is not, or the environment has
# no list.
# ---------------------------------------------------------------------------
set -euo pipefail

ENV_NAME="${1:-}"
NODE_COUNT="${2:-}"
[ -n "$ENV_NAME" ] && [ -n "$NODE_COUNT" ] \
  || { echo "usage: check-node-count.sh <env> <count>" >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVS_DIR="${NODE_COUNTS_DIR:-$REPO/bootstrap/ec2/gibson/envs}"
LIST="$ENVS_DIR/${ENV_NAME}.node-counts"

if [ ! -f "$LIST" ]; then
  echo "FATAL: ENV=${ENV_NAME} accepts no NODE_COUNT. Only an environment with a list at ${LIST#"$REPO"/} accepts one." >&2
  exit 2
fi

permitted="$(grep -vE '^[[:space:]]*(#|$)' "$LIST" | tr -d '[:blank:]' || true)"
[ -n "$permitted" ] || { echo "FATAL: ${LIST#"$REPO"/} lists no node count." >&2; exit 2; }

if ! printf '%s\n' "$permitted" | grep -qxF -- "$NODE_COUNT"; then
  echo "FATAL: NODE_COUNT=${NODE_COUNT} is not permitted for ENV=${ENV_NAME}. Permitted: $(printf '%s' "$permitted" | tr '\n' ' ')" >&2
  exit 2
fi
echo "NODE_COUNT=${NODE_COUNT} is permitted for ENV=${ENV_NAME}"
