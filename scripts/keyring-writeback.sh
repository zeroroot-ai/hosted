#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# keyring-writeback.sh — write the keyring and substrate.env of a state
# directory to the keyring secret of <env> in Secrets Manager
# (ADR-0083, amendment of 2026-10-22).
#
#   keyring-writeback.sh <state-dir> <env>
#
# This is the one write-back code. The workflow rotate-credentials.yml calls it
# under its OIDC role, which can write that one secret. The files are read from
# disk and never echoed. The caller decides whether to write: the workflow calls
# it only when the marker .cluster-keyring-pushed exists.
# ---------------------------------------------------------------------------
set -euo pipefail

STATE="${1:-}"; ENV="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf '! [keyring-writeback] %s\n' "$*" >&2; exit 2; }
[ -n "$STATE" ] && [ -n "$ENV" ] || die "usage: keyring-writeback.sh <state-dir> <env>"
# shellcheck source=stage0-store.sh
. "$HERE/stage0-store.sh"
stage0_push_keyring "$ENV" "$STATE"
echo "The keyring secret zeroroot-ai/${ENV}/keyring holds the new keyring and substrate.env."
