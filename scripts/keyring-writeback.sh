#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# keyring-writeback.sh — write the keyring and substrate.env of a state
# directory to the GitHub environment of <env>: the environment secret
# BRINGUP_KEYRING and the environment variable SUBSTRATE_ENV_FILE
# (ADR-0083, amendment of 2026-10-21).
#
#   keyring-writeback.sh <state-dir> <env>
#
# This is the one write-back code. The workflow rotate-credentials.yml calls it
# with the GitHub App token, and scripts/recover-keyring.sh calls it with the
# gh login of the person. The files are read from disk and never echoed.
#
# A file is written only when it differs from the copy that the run read:
# <state-dir>/.read-keyring.sha256 and .read-substrate.sha256. With no such
# file, the file is written.
#
# Env: GITHUB_REPOSITORY (default zeroroot-ai/hosted), GH (the gh binary).
# ---------------------------------------------------------------------------
set -euo pipefail

STATE="${1:-}"; ENV="${2:-}"
GH="${GH:-gh}"
REPO_SLUG="${GITHUB_REPOSITORY:-zeroroot-ai/hosted}"
[ -n "$STATE" ] && [ -n "$ENV" ] || { echo "usage: keyring-writeback.sh <state-dir> <env>" >&2; exit 2; }
[ -s "$STATE/keyring.env" ] && [ -s "$STATE/substrate.env" ] \
  || { echo "! [keyring-writeback] $STATE holds no keyring.env or substrate.env" >&2; exit 2; }

changed() {  # <file> <read-hash-file>: true when the file is not the one that was read
  [ -s "$2" ] || return 0
  [ "$(sha256sum < "$1" | cut -d' ' -f1)" != "$(cat "$2")" ]
}

if changed "$STATE/keyring.env" "$STATE/.read-keyring.sha256"; then
  "$GH" secret set BRINGUP_KEYRING --env "$ENV" --repo "$REPO_SLUG" < "$STATE/keyring.env"
  echo "BRINGUP_KEYRING of ${ENV} holds the new keyring."
else
  echo "The keyring did not change."
fi
if changed "$STATE/substrate.env" "$STATE/.read-substrate.sha256"; then
  "$GH" variable set SUBSTRATE_ENV_FILE --env "$ENV" --repo "$REPO_SLUG" < "$STATE/substrate.env"
  echo "SUBSTRATE_ENV_FILE of ${ENV} holds the new substrate.env."
else
  echo "substrate.env did not change."
fi
