#!/usr/bin/env bash
# teardown-kind.sh — the teardown verb for ENV=kind (ADR-0083,
# deploy#1738). `make teardown ENV=kind MODE=wipe|preserve` runs preflight and
# then this script. The deleted `kind-down` target did the wipe half by hand.
#
# MODE has no default, here and in make. A teardown that picks a mode by
# omission is how a preserve teardown silently becomes a wipe, so this script
# refuses an unset or unknown MODE even though make already did: no other
# caller may slip one past.
#
#   MODE=wipe      Destroy stage 1 and keep nothing. It deletes NOTHING from
#                  the durable bucket and never reads it: retention is the
#                  bucket's lifecycle rule and nothing else, and the next
#                  recreate does not consult the bucket (ADR-0083). The
#                  keyring is not read either.
#
#   MODE=preserve  Back up, PROVE the backup readable, then destroy, then
#                  print the backup name (docs/bringup.md § A preserve
#                  teardown, step by step):
#
#     0-3. scripts/lib/preserve-backup.sh: the canary record, the CNPG base
#        backup, the Velero backup built from the shipped Schedule, and the
#        backup-verify canary decrypt. Those four steps speak only kubectl,
#        the bucket and the keyring, so ENV=staging and ENV=prod run the SAME
#        code (scripts/teardown-aws.sh). Any failure aborts, names the check,
#        leaves the cluster standing, and never falls back to a wipe. A
#        backup that is not Completed prints the errors Velero recorded,
#        grouped and counted, read from the backup's own log in the bucket
#        (explain_bad_backup, deploy#1740): the count alone names nothing.
#     4. Destroy stage 1.
#     5. Print `RESTORE_FROM=<name>` as the last line. That name is the only
#        thing a later recreate accepts (ADR-0083, deploy#1739).
#
# Stage 1 on kind is the kind cluster itself and the local Terraform state
# that describes what lives inside it. Stage 0 (the durable bucket, the MinIO
# and CoreDNS containers, the keyring under SUBSTRATE_DIR) is NOT stage 1 and
# is never touched by either mode.
#
# Usage: teardown-kind.sh <substrate.env>    (make teardown ENV=kind calls it)
# Env:
#   MODE       wipe|preserve, REQUIRED, no default
#   CLUSTER    kind cluster name              (default: gibson)
#   NS         release namespace              (default: gibson)
#   VELERO_NS SCHEDULE CNPG_CLUSTER BACKUP_TIMEOUT VERIFY_TIMEOUT
#              the preserve inputs. Their defaults are in lib/preserve-backup.sh
set -uo pipefail

SUBSTRATE_ENV="${1:-}"
[ -n "$SUBSTRATE_ENV" ] || { echo "usage: teardown-kind.sh <substrate.env>" >&2; exit 2; }
[ -s "$SUBSTRATE_ENV" ] || { echo "FATAL: no substrate.env at ${SUBSTRATE_ENV}. Run make substrate ENV=kind first (ADR-0083)." >&2; exit 2; }

MODE="${MODE:-}"
case "$MODE" in
  wipe|preserve) ;;
  *) echo "FATAL: MODE is required and has no default: MODE=wipe or MODE=preserve (ADR-0083)." >&2; exit 2 ;;
esac

CLUSTER="${CLUSTER:-gibson}"
NS="${NS:-gibson}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

umask 077
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n\033[1;32m▶\033[0m [teardown %s] %s\n' "$MODE" "$*"; }
die() { printf '\033[1;31m✗ [teardown %s] %s\033[0m\n' "$MODE" "$*" >&2; exit 1; }

for tool in kind kubectl docker python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done

# destroy_stage1 — the kind cluster and the Terraform state that described
# what lived in it. `kind delete cluster` is idempotent, so a wipe of a
# cluster that is already gone still succeeds. The local state file must go
# with the cluster: a later apply against a fresh cluster is the truth, and a
# refresh against the ghosts of a deleted one is not (the same reason
# scripts/recreate-kind.sh removes it before it creates).
destroy_stage1() {
  log "destroying stage 1: kind cluster '${CLUSTER}'"
  kind delete cluster --name "$CLUSTER" || die "could not delete the kind cluster '${CLUSTER}'"
  # The LoadBalancer implementation is a HOST container tied to this cluster
  # (ADR-0083 stage 1, deploy#1737): cloud-provider-kind watches the Docker
  # socket rather than running as a workload, so `kind delete cluster` does not
  # touch it. The deleted kind-down target removed it, and this verb replaces
  # kind-down, so it removes it here. Left behind it watches a cluster that no
  # longer exists, and the next recreate finds the name taken.
  docker rm -f "cloud-provider-${CLUSTER}" >/dev/null 2>&1 || true
  rm -f "$REPO/bootstrap/kind/gibson/terraform.tfstate" "$REPO/bootstrap/kind/gibson/terraform.tfstate.backup"
  printf '  ✓ cluster deleted, its LoadBalancer container removed, and its local Terraform state with it\n'
  printf '  ✓ stage 0 untouched: the durable bucket, the relay, the zone and the keyring outlive this\n'
}

if [ "$MODE" = wipe ]; then
  # Nothing is read from the bucket and nothing is written to it. The next
  # recreate bootstraps every store empty, even when the bucket holds a
  # hundred backups (ADR-0083).
  destroy_stage1
  printf '\n\033[0;32mteardown ENV=kind MODE=wipe complete.\033[0m Nothing was kept, and nothing was deleted from the durable bucket.\n'
  printf 'A recreate from here comes up EMPTY (ADR-0083). There is no backup name to carry.\n'
  exit 0
fi

# ===========================================================================
# MODE=preserve
# ===========================================================================
kubectl cluster-info >/dev/null 2>&1 \
  || die "no reachable cluster for the current kubeconfig context. A preserve teardown has nothing to back up; if the cluster is already gone, MODE=wipe is the mode that says so"

# The backup is taken through the CURRENT kubeconfig context and the destroy
# names CLUSTER. If those two are different clusters, a preserve teardown
# backs one up and destroys another, and reports success. Refuse instead.
CONTEXT="$(kubectl config current-context 2>/dev/null)"
[ "$CONTEXT" = "kind-${CLUSTER}" ] \
  || die "the current kubeconfig context is '${CONTEXT:-<none>}' but CLUSTER is '${CLUSTER}'. A preserve teardown would back up one cluster and destroy another. Run: kubectl config use-context kind-${CLUSTER}"

# One name for one teardown: the CNPG Backup CR, the Velero Backup and the
# canary record in the bucket all carry it, so deploy#1739 can find every
# piece of a restore from the single name this script prints. Lower case and
# dashes only: a Velero backup name is a DNS-1123 label.
BACKUP_NAME="preserve-kind-$(date -u +%Y%m%d-%H%M%S)"

log "backup name for this teardown: ${BACKUP_NAME}"

# Steps 0 through 3 are the substrate-agnostic preserve half
# (scripts/lib/preserve-backup.sh): record the canary, the CNPG base backup,
# the Velero backup from the shipped Schedule, and backup-verify. Any failure
# in there calls die() and leaves the cluster standing.
# shellcheck source=lib/preserve-backup.sh
. "$HERE/lib/preserve-backup.sh"
preserve_backup "$BACKUP_NAME"

# --- 4. destroy -----------------------------------------------------------
log "4/4 the backup is proven readable, so the destroy may proceed"
destroy_stage1

# The last line is the backup name, in the form a later recreate takes.
# An agent told to preserve ends its report with it (docs/bringup.md).
printf '\n\033[0;32mteardown ENV=kind MODE=preserve complete.\033[0m Carry this name to the restore (ADR-0083, deploy#1739):\n\n'
printf 'RESTORE_FROM=%s\n' "$BACKUP_NAME"
