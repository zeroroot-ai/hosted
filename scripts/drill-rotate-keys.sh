#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# drill-rotate-keys.sh — the access key rotation of the drill IAM users, in
# the drill (ADR-0083 amendment of 2026-10-13, drill sweep row 24).
#
#   drill-rotate-keys.sh start      start a rotation of each user (a
#                                   rotation dispatch of drill)
#   drill-rotate-keys.sh continue   continue each open rotation (each run)
#
# Each user is one `make substrate-rotate ENV=drill CREDENTIAL=<user>`
# (scripts/substrate-rotate.sh): a new key, the keyring and the cluster move
# to it, each reader restarts, and the old key is deleted only after AWS
# reports it unused since the switch. One rotation takes longer than one run:
# the new key must be seen in use (WAIT_SECS), and the old key must then stay
# unused for QUIET_SECS. So substrate-rotate.sh stops with exit 10 when it must
# wait, and a later run continues. The stage 0 files of drill live in AWS
# (scripts/stage0-store.sh), so each run sees the state the last one left.
#
# A user with one key slot has no open rotation, and `continue` skips it.
#
# Env: SUBSTRATE_DIR (the runner's stage 0 directory, from drill-setup),
#      WAIT_SECS (default 900 here: a run does not wait hours for a key to be
#      used, the next run looks again), QUIET_SECS (the script's default).
# Exit: 0 every user rotated, waits (exit 10 only), or has nothing open · 1 a
#       rotation failed, halted (substrate-rotate.sh exit 3: a person must
#       act), or did not run (with-cluster.sh exit 1)
# ---------------------------------------------------------------------------
set -uo pipefail

MODE="${1:-}"
ENV=drill
USERS="platform smtp dns setec-disk-builder"
case "$MODE" in start|continue) ;; *) echo "usage: drill-rotate-keys.sh start|continue" >&2; exit 2 ;; esac
[ -n "${SUBSTRATE_DIR:-}" ] || { echo "SUBSTRATE_DIR is not set (drill-setup sets it)" >&2; exit 2; }
STATE="${SUBSTRATE_DIR}/${ENV}"
SLOTS="${STATE}/key-slots.tfvars.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable for tests/harness/drill-rotate-keys.bats only.
WITH_CLUSTER="${WITH_CLUSTER:-$HERE/with-cluster.sh}"
STAGE0_STORE="${STAGE0_STORE:-$HERE/stage0-store.sh}"

# Stage 0 needs the public ids of the Argo CD GitHub App, which substrate.env
# holds (substrate.sh writes them there).
substrate_get() { grep -E "^$1=" "${STATE}/substrate.env" | head -n1 | cut -d= -f2- || true; }
TF_VAR_argocd_github_app_id="$(substrate_get GITHUB_APP_ID)"
TF_VAR_argocd_github_app_installation_id="$(substrate_get GITHUB_APP_INSTALLATION_ID)"
export TF_VAR_argocd_github_app_id TF_VAR_argocd_github_app_installation_id
export WAIT_SECS="${WAIT_SECS:-900}"
# The poll of each wait. The script default of 300 s fits a workstation run
# that waits hours. A drill run waits minutes, and a poll of 300 s used the
# whole wait in one sleep (review of hosted#749).
export SLEEP_SECS="${SLEEP_SECS:-30}"
# The smtp rotation waits for the OpenBao input pass (every 5 minutes) and
# the kubelet update of the keyring volume before ESO can write the derived
# Secret. 600 s covers one pass with margin.
export SECRET_WAIT_SECS="${SECRET_WAIT_SECS:-600}"

open_rotation() {  # <user>: true when the user has two key slots
  [ -s "$SLOTS" ] || return 1
  [ "$(jq -r --arg u "$1" '.key_slots[$u].keep | length' "$SLOTS")" -ge 2 ]
}

failed=""
for user in $USERS; do
  if [ "$MODE" = continue ] && ! open_rotation "$user"; then
    printf '  %s: no open rotation\n' "$user"
    continue
  fi
  printf '▶ %s: %s the rotation\n' "$user" "$MODE"
  # The same call as `make substrate-rotate`, without make, which turns
  # every exit code into 2: substrate-rotate.sh exits 10 when it must wait.
  "$WITH_CLUSTER" "$ENV" "$HERE/substrate-rotate.sh" "$STATE" "$ENV" "$user"
  # Only exit 10 of substrate-rotate.sh is a wait. Exit 1 is also the exit of
  # with-cluster.sh when nothing ran (no instance, two instances, no session
  # plugin, an API that does not answer), so it is a failure here.
  case $? in
    0) printf '  ✓ %s: rotated, the old key is deleted\n' "$user" ;;
    10) printf '  %s: the rotation waits; a later drill run continues it\n' "$user" ;;
    *) failed="${failed} ${user}" ;;
  esac
  # Each run of substrate-rotate.sh reads the stage 0 files from AWS and
  # keeps its changes there, so the next user starts from them.
  "$STAGE0_STORE" pull "$ENV" "$STATE" >/dev/null
done

if [ -n "$failed" ]; then
  echo "::error::the access key rotation failed for:${failed}. Read the log of each above" >&2
  exit 1
fi
