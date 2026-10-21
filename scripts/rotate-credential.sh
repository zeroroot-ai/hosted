#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rotate-credential.sh — one step of one credential rotation, in the workflow
# .github/workflows/rotate-credentials.yml (ADR-0083, amendment of 2026-10-21;
# ADR-0171, rows keyring-generated-keys and substrate-cloud-credentials).
#
#   rotate-credential.sh <state-dir> <env> <credential> <step>
#
#   credential  platform | smtp | dns | setec-disk-builder
#                 an access key of a stage 0 IAM user. step is "rotate", and
#                 a run that finds an open rotation continues it
#                 (scripts/substrate-rotate.sh, row 12).
#               OPENBAO_SEAL_KEY | VELERO_REPO_PASSWORD | SETEC_DISK_SIGNING_SEED
#                 a keyring member with a <MEMBER>_PREVIOUS member
#                 (scripts/keyring.sh rotate and retire, row 11). step is
#                 "rotate" or "retire".
#
# The keyring of the state directory is the keyring of the environment (the
# workflow wrote it from the environment secret BRINGUP_KEYRING). A rotation
# changes it and substrate.env, and the workflow writes both back, so this
# script never touches GitHub.
#
# For a keyring member, one step is: change the keyring, push it to the cluster
# (keyring-to-cluster.sh), restart the reader, and write substrate.env again
# (substrate.sh), so it holds the new fingerprints.
#
# VELERO_REPO_PASSWORD rotate also needs EXPECT_VELERO_PREFIX. A new password
# starts a new kopia repository at a new prefix, and the overlay must carry that
# prefix before the cluster gets the password. The step refuses unless
# the overlay of the checkout names exactly EXPECT_VELERO_PREFIX, and the
# prefix is not the one of the previous repository.
#
# Env: KUBECONFIG    the kubeconfig of the environment (the workflow writes it)
#      NS            the release namespace (default gibson)
#      OPENBAO_STS   the OpenBao StatefulSet (default gibson-openbao)
#      RESTART_TIMEOUT  seconds for each restart (default 600)
# Exit: the exit code of substrate-rotate.sh for an access key (0 done, 10
#       waits, 3 halted, 2 failed), 0 or 2 for a keyring member.
# ---------------------------------------------------------------------------
set -euo pipefail

STATE="${1:-}"; ENV="${2:-}"; CRED="${3:-}"; STEP="${4:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# Overridable for tests/harness/rotate-credential.bats only (also RESTART_PODS_LIB).
KEYRING="${KEYRING:-$HERE/keyring.sh}"
K2C="${K2C:-$HERE/keyring-to-cluster.sh}"
SUBSTRATE_SH="${SUBSTRATE_SH:-$REPO/substrate/gibson-bootstrap/substrate.sh}"
SUBSTRATE_ROTATE="${SUBSTRATE_ROTATE:-$HERE/substrate-rotate.sh}"
NS="${NS:-gibson}"
OPENBAO_STS="${OPENBAO_STS:-gibson-openbao}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-600}"

die() { printf '! [rotate-credential] %s\n' "$*" >&2; exit 2; }
say() { printf '  ✓ [rotate-credential] %s\n' "$*"; }

[ -n "$STATE" ] && [ -n "$ENV" ] && [ -n "$CRED" ] && [ -n "$STEP" ] \
  || die "usage: rotate-credential.sh <state-dir> <env> <credential> <step>"
case "$ENV" in staging|prod) ;; *) die "ENV=$ENV is not staging or prod. The drill rotates in drill.yml" ;; esac
[ "${GITHUB_ACTIONS:-}" = true ] \
  || die "a credential rotation runs in a GitHub Actions workflow only: .github/workflows/rotate-credentials.yml (ADR-0083)"
[ -s "$STATE/keyring.env" ] && [ -s "$STATE/substrate.env" ] \
  || die "$STATE holds no keyring.env or substrate.env: the workflow reads them from the environment first"

case "$CRED" in
  platform|smtp|dns|setec-disk-builder)
    [ "$STEP" = rotate ] || die "an access key has one step, rotate. A run that finds an open rotation continues it"
    exec "$SUBSTRATE_ROTATE" "$STATE" "$ENV" "$CRED" ;;
  OPENBAO_SEAL_KEY|VELERO_REPO_PASSWORD|SETEC_DISK_SIGNING_SEED) ;;
  *) die "CREDENTIAL=$CRED is not an access key user or a keyring member that rotates in place" ;;
esac
case "$STEP" in rotate|retire) ;; *) die "STEP=$STEP is not rotate or retire" ;; esac

if [ "$CRED" = VELERO_REPO_PASSWORD ] && [ "$STEP" = rotate ]; then
  [ -n "${EXPECT_VELERO_PREFIX:-}" ] \
    || die "VELERO_REPO_PASSWORD rotate needs EXPECT_VELERO_PREFIX: merge the overlay with the new prefix first (scripts/keyring.sh, ROTATION)"
  # shellcheck source=lib/velero-restore.sh
  . "$HERE/lib/velero-restore.sh"
  have="$(velero_overlay_prefix "$REPO/gitops/envs/$ENV/gibson-velero-values.yaml")" \
    || die "the overlay of $ENV has no readable Velero prefix"
  [ "$have" = "${EXPECT_VELERO_PREFIX#/}" ] \
    || die "the overlay of $ENV names the Velero prefix '$have', and this run expects '${EXPECT_VELERO_PREFIX}'. Merge the overlay change first, or fix the input"
  [ "$have" != backups/velero ] \
    || die "the overlay still names the first repository, backups/velero. A new password needs a new prefix"
fi

"$KEYRING" "$STEP" "$STATE/keyring.env" "$CRED" >/dev/null
say "keyring: $STEP of $CRED"
"$K2C" "$STATE/substrate.env" >/dev/null
say "the keyring is in the cluster"

# shellcheck source=lib/restart-pods.sh
. "${RESTART_PODS_LIB:-$HERE/lib/restart-pods.sh}"
case "$CRED" in
  OPENBAO_SEAL_KEY)  readers=("$NS statefulset/$OPENBAO_STS") ;;
  VELERO_REPO_PASSWORD) readers=("velero deployment/velero") ;;
  # The openbao-auto-init sidecar follows the keyring input within five
  # minutes, and the disk builder signs with the new seed (scripts/keyring.sh).
  SETEC_DISK_SIGNING_SEED) readers=() ;;
esac
for r in "${readers[@]}"; do
  read -r rns rw <<<"$r"
  restart_pods "$rns" "$rw" "$RESTART_TIMEOUT" \
    || die "$rns/$rw does not run again after the restart. The keyring is changed in the cluster: read the log above before a new run"
  say "restarted $rns/$rw"
done

# substrate.env records the fingerprints of the keyring.
"$SUBSTRATE_SH" "$STATE" "$ENV" >/dev/null
say "substrate.env holds the new fingerprints"
