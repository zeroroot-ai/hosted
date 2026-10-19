# shellcheck shell=bash
# ---------------------------------------------------------------------------
# bringup-after-cluster.sh — everything a recreate does once the cluster
# answers, for every substrate (hosted#159).
#
# It is SOURCED, not called, so the code runs with the caller's variables in
# scope exactly where it used to run inside scripts/recreate-aws.sh. That is
# deliberate: the extraction moved no logic, and a diff of this file against
# the old tail of recreate-aws.sh shows three changed lines, listed below.
#
# The caller sets up the cluster and then sources this file. It must have:
#
#   KUBECONFIG           exported, and the API answering
#   KUBECONFIG_PATH      the file, for the closing message
#   HERE REPO WORK       the script directory, the repo root, a scratch dir
#   SUBSTRATE_ENV        the stage 0 file
#   ENV_NAME NS VELERO_NS
#   RESTORE_FROM
#   GITOPS_PATH          the env overlay, relative to REPO
#   TOOLHIVE_VERSION
#   log() die()          the caller's own reporters
#
# and it must define one function, which is the only substrate-specific
# step left in the whole tail:
#
#   stage1_enable_app_of_apps   create the app-of-apps after a restore
#
# A caller that does not define it is refused here rather than half way
# through a bringup.
# ---------------------------------------------------------------------------

for _hook in stage1_enable_app_of_apps; do
  declare -F "$_hook" >/dev/null \
    || die "bringup-after-cluster.sh needs the $_hook hook. The caller defines it before sourcing this file"
done
unset _hook

# ---------------------------------------------------------------------------
# Cluster prerequisite: ToolHive (ADR-0114, connector runtime), the same
# pinned install scripts/recreate-kind.sh does. The connector-operator
# watches toolhive.stacklok.dev/v1alpha1 MCPServer and exits when the CRD
# is absent ("failed to wait for connectorinstance caches to sync ...
# MCPServer: timed out"), which is how the first staging recreate from
# fresh (2026-09-10) had it crashlooping: nothing on the AWS path
# installed ToolHive. Third-party, so it is a stage 1 prerequisite here and
# not a chart in the umbrella; the ConnectorInstance wrapper absorbs a
# ToolHive upgrade.
# ---------------------------------------------------------------------------
log "prerequisite: toolhive ${TOOLHIVE_VERSION}"
helm upgrade --install toolhive-operator-crds \
  oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds \
  --namespace toolhive-system --create-namespace --version "$TOOLHIVE_VERSION" \
  --wait --timeout 10m \
  || die "the ToolHive CRDs did not install (version ${TOOLHIVE_VERSION})"
# The values make each proxy pod meet restricted (hosted#454).
helm upgrade --install toolhive-operator \
  oci://ghcr.io/stacklok/toolhive/toolhive-operator \
  --namespace toolhive-system --version "$TOOLHIVE_VERSION" \
  --values "$REPO/bootstrap/toolhive/values.yaml" \
  --wait --timeout 10m \
  || die "the ToolHive operator did not install (version ${TOOLHIVE_VERSION})"

# ---------------------------------------------------------------------------
# The bringup keyring, into the cluster. The ONE producer (ADR-0083), the
# same script ENV=kind runs.
# ---------------------------------------------------------------------------
log "writing the bringup keyring into the cluster"
NS="$NS" "$HERE/keyring-to-cluster.sh" "$SUBSTRATE_ENV" \
  || die "the bringup keyring did not reach the cluster. Nothing that reads a Secret can start"

# ---------------------------------------------------------------------------
# BEFORE THE PLATFORM APPLICATION EXISTS. A step that must be in the cluster
# before the gibson Application syncs goes here, after the keyring and before
# the restore. In restore mode the app-of-apps does not exist yet at this
# line. In fresh mode stage 1 phase 2 already created it, so this line is as
# early as the keyring itself, which the platform also needs.
# ---------------------------------------------------------------------------

# The edge certificate of the last teardown, when it is still good (row 9 of
# the drill path audit). cert-manager keeps a Secret that is valid and names
# what its Certificate asks for, so the recreate asks Let's Encrypt for
# nothing. Fresh and restore mode alike.
# shellcheck source=edge-cert.sh
. "$HERE/lib/edge-cert.sh"
EDGE_CERT_SECRET="$(grep -E '^EDGE_CERT_SECRET=' "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true)"
[ -n "$EDGE_CERT_SECRET" ] \
  || die "${SUBSTRATE_ENV} names no EDGE_CERT_SECRET. Run make substrate ENV=${ENV_NAME} (edge-cert.tf)"
EDGE_CERT_WANT_NAMES="$(edge_cert_overlay_names "$REPO/${GITOPS_PATH}/values.yaml")"
EDGE_CERT_SECRET="$EDGE_CERT_SECRET" EDGE_CERT_WANT_NAMES="$EDGE_CERT_WANT_NAMES" edge_cert_restore

# ---------------------------------------------------------------------------
# The restore, when a backup was named (ADR-0083).
#
# The order is the one docs/bringup.md states and scripts/recreate-kind.sh
# runs:
#
#   1. the CRDs and the backup plane, and nothing else. They are the two
#      Applications the app-of-apps would have brought first anyway — the
#      overlay annotates them sync-wave -10 and -5 against the platform's 0
#      (gitops#564) — so creating them here is bringing that same wave
#      forward, not inventing an order. They come STRAIGHT out of the
#      overlay, so what runs is what the app-of-apps would have applied.
#   2. the secret store, restored while no platform Application exists.
#   3. the gibson Application with the three Postgres recovery values
#      (lib/restore-recovery.sh, D91), then the app-of-apps, which adopts it.
#   4. External Secrets, then the built-ins, then the tenant records. This
#      runs BEFORE the wait for every Application. The data restore needs
#      Argo to be short of wave 0, where each store with a volume syncs: a
#      store that Argo created first keeps its empty volume, and Velero
#      (existingResourcePolicy: none) skips its claim and its pod.
# ---------------------------------------------------------------------------

# apply_overlay_app <name> — one Application, verbatim from the gitops
# overlay in this checkout. The stage 0 gates read the same tree
# (lib/bringup-before-cluster.sh reads values.yaml and
# gibson-velero-values.yaml from it), so the restore applies what those gates
# proved. It used to read the file from the GitHub API with GH_PAT. The
# GitHub App (#41) removed the PAT, so nothing set it, and under set -u a
# restore stopped at its first Application.
apply_overlay_app() {
  local name="$1" file="$REPO/${GITOPS_PATH}/${1}.yaml"
  [ -s "$file" ] \
    || die "there is no ${GITOPS_PATH}/${name}.yaml in this checkout. A restore needs the CRDs and the backup
    plane before the platform Application exists, and it takes both from the overlay rather than
    inventing them"
  kubectl apply -f "$file" >/dev/null \
    || die "could not create Application ${name} from the overlay"
  printf '  ✓ Application %s created from %s/%s.yaml\n' "$name" "$GITOPS_PATH" "$name"
}

# shellcheck source=lib/restore-recovery.sh
. "$HERE/lib/restore-recovery.sh"

# wait_app_healthy <name> — one Application to Synced+Healthy. The bound is
# RESTORE_APP_TIMEOUT of lib/velero-restore.sh (measured: under two minutes).
wait_app_healthy() {
  local name="$1" bound deadline sync health
  bound="$(restore_bound "$RESTORE_APP_TIMEOUT")"
  deadline=$(( $(date +%s) + bound ))
  while :; do
    sync="$(kubectl -n argocd get "application/$name" -o jsonpath='{.status.sync.status}' 2>/dev/null)"
    health="$(kubectl -n argocd get "application/$name" -o jsonpath='{.status.health.status}' 2>/dev/null)"
    if [ "$sync" = Synced ] && [ "$health" = Healthy ]; then
      printf '  ✓ Application %s Synced+Healthy\n' "$name"; return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || {
      kubectl -n argocd get "application/$name" \
        -o jsonpath='{range .status.conditions[*]}    {.type}: {.message}{"\n"}{end}' >&2 2>/dev/null || true
      die "Application ${name} did not reach Synced+Healthy within ${bound}s (sync=${sync:-<none>} health=${health:-<none>}). The restore cannot start without it"
    }
    printf '  %s: sync=%s health=%s          \r' "$name" "${sync:-<none>}" "${health:-<none>}"
    sleep 10
  done
}

if [ -n "$RESTORE_FROM" ]; then
  log "restore 0/3: the CRDs and the backup plane, ahead of the platform"
  # The CRDs are TWO Applications since charts#82 split them, and the operator
  # half carries the ones this restore itself needs: ExternalSecret, and
  # Certificate for the webhooks. Create it first, then the platform CRDs.
  apply_overlay_app gibson-operator-crds
  wait_app_healthy gibson-operator-crds
  apply_overlay_app gibson-crds
  wait_app_healthy gibson-crds
  apply_overlay_app gibson-velero
  wait_app_healthy gibson-velero
  kubectl -n "$VELERO_NS" rollout status deployment/velero --timeout=300s >/dev/null 2>&1 \
    || die "the Velero server never became ready, so nothing can read backup '${RESTORE_FROM}'"

  restore_secret_store

  log "restore: the secret store is home, so the platform may now be created"
  # The gibson Application FIRST, with the recovery values, so no sync of
  # the chart runs with bootstrap.initdb. The app-of-apps then adopts it and
  # keeps the parameters (the one path it ignores, D91).
  apply_gibson_with_recovery
  stage1_enable_app_of_apps \
    || die "the app-of-apps could not be created after the restore. The secret store IS restored; run the recreate again with the same RESTORE_FROM"

  wait_eso
  restore_data
fi

# ---------------------------------------------------------------------------
# Stage 2 — Argo CD syncs the umbrella from the gitops overlay.
# ---------------------------------------------------------------------------
# wait_apps is scripts/lib/wait-apps.sh — the SAME code ENV=kind runs
# (scripts/recreate-kind.sh). Its progress fingerprint is the Synced+Healthy
# Application count PLUS the cluster's pod phase tally, so a bringup where
# pods are still moving is slow rather than stuck. The count alone nearly
# failed a converging three-instance CNPG here at 16 of its 20 minutes
# (deploy#1746).
# shellcheck source=lib/wait-apps.sh
. "$HERE/lib/wait-apps.sh"

log "stage 2: waiting for every Argo Application to reach Synced+Healthy"
wait_apps

log "stage 2: every ExternalSecret is Ready (hosted#174)"
wait_externalsecrets

# The platform Postgres actually archives its WAL (blocker 3, ADR-0083).
#
# stage 0a proved the archive directory was EMPTY. That is a gate on the
# input, not proof of the outcome: the credential, the endpoint and the
# operator all still have to work. CNPG reports the Cluster Ready and Argo
# reports the Application Healthy whether or not one segment ever reaches the
# bucket, so an environment with no backups looks identical to one with
# backups until somebody needs a restore.
#
# Runs AFTER stage 2, because the Cluster does not exist until the umbrella
# syncs it. scripts/lib/wait-archiving.sh is the SAME code ENV=kind runs.
# shellcheck source=lib/wait-archiving.sh
. "$HERE/lib/wait-archiving.sh"
log "the platform Postgres archives its WAL (ADR-0083, blocker 3)"
wait_archiving

printf '\n\033[0;32mrecreate ENV=%s complete.\033[0m\n' "$ENV_NAME"
printf '    kubeconfig  %s\n' "$KUBECONFIG_PATH"
if [ -n "$RESTORE_FROM" ]; then
  # Git learns the new archive name by a PR (D91), after the restore is
  # healthy and archiving.
  RESTORE_GIT_STATUS=""
  restore_catch_up
  printf '    restored from backup %s (ADR-0083).\n' "$RESTORE_FROM"
  printf '    postgres  recovered from base backup %s in archive %s, and archives to %s\n' \
    "$RECOVERY_BACKUP_ID" "$RECOVERY_ARCHIVE_NAME" "$RESTORE_ARCHIVE_NAME"
  printf '    %s\n' "$RESTORE_GIT_STATUS"
else
  printf '    every store bootstrapped EMPTY. No backup was read (ADR-0083).\n'
fi
