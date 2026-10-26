#!/usr/bin/env bash
# argo-diag.sh <dir> — keep the state of Argo CD after a failed step whose own
# script keeps none (the settle probe of the drill, hosted#94). Run it inside
# with-cluster.sh, so KUBECTL reaches the cluster:
#
#   make with-cluster ENV=drill CMD="scripts/argo-diag.sh <dir>"
set -uo pipefail
[ -n "${1:-}" ] || { echo "usage: argo-diag.sh <dir>" >&2; exit 2; }
# shellcheck source=lib/argo-diag.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/argo-diag.sh"
argo_diag_save "$1"
