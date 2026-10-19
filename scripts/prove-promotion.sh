#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# prove-promotion.sh — the three assertions promote-staging makes against an
# environment that is ALREADY UP (ADR-0095). Run it inside with-cluster.sh, so
# KUBECONFIG names the SSM forward:
#
#   make with-cluster ENV=staging CMD='scripts/prove-promotion.sh staging'
#
# It is a script and not a block of shell inside the workflow YAML for two
# reasons: a quoted multi-line command in YAML cannot be shellchecked (actionlint
# reports SC2016 on it, correctly, because the expansions are meant for the inner
# shell), and this way the sequence can be read and tested on its own.
#
#   0. lands    first, the proof waits until the operation of the app
#               Succeeded at the pinned revision and the app is Healthy, so
#               the smoke runs on the version it proves, not during its
#               rollout. Then 1 to 3, then the landed check once more.
#   1. Ready    every Argo Application Synced+Healthy. On a permanent staging
#               this is a PRECONDITION, not a wait for a bringup: red here means
#               the estate was already broken before this version was pinned.
#   2. landed   `.status.sync.revision` is an EMPTY STRING on every multi-source
#               Application, so a jsonpath equality on it can never match, and
#               `Synced` alone is not proof (gitops#363): a sync can report
#               success having skipped the resources the new version changed. A
#               hard refresh re-renders and re-compares every resource, then
#               check-promotion-landed.sh asserts the operation Succeeded at the
#               spec's own revision, Healthy, and nothing OutOfSync except what
#               the prune allowlist names. Then prune-orphans.sh audit fails on
#               an allowlist entry that matches nothing live (hosted#748).
#   3. smoke    signup -> tenant Ready -> data-plane secrets -> api-edge auth
#               chain, against the public host.
# ---------------------------------------------------------------------------
set -euo pipefail

ENV_NAME="${1:-}"
[ -n "$ENV_NAME" ] || { echo "usage: prove-promotion.sh <env>" >&2; exit 2; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP:-gibson}"
NAMESPACE="${NAMESPACE:-gibson}"
ENV_DOMAIN="${ENV_DOMAIN:-${ENV_NAME}.zeroroot.ai}"

# The test seams of tests/harness/prove-promotion-order.bats. In a real run
# each is the script of this repo.
PROVE_BRINGUP="${PROVE_BRINGUP:-$REPO/scripts/prove-bringup.sh}"
LANDED_CHECK="${LANDED_CHECK:-$REPO/gitops/scripts/check-promotion-landed.sh}"
# How long the promotion may take to land before the smoke: the app-of-apps
# copies the new pin into the live spec (its git poll, about 3 minutes), Argo
# syncs the new chart, and each workload rolls out (about 3 minutes on
# staging). The real bound is LAND_WAIT plus one hard refresh (300 s) plus
# LAND_POLL.
LAND_WAIT="${LAND_WAIT:-1200}"
# The chart version that this proof is for. promote-staging.yml sets it. The
# landed check reads its wanted revision from the live spec, which shows the
# old pin until the app-of-apps copies the new one, so the wait also demands
# that the live spec pins this version.
# A manual run with no CHART_VERSION proves the version that the env pins in
# this checkout.
# shellcheck source=../gitops/scripts/lib/chart-version.sh
. "$REPO/gitops/scripts/lib/chart-version.sh"
CHART_VERSION="${CHART_VERSION:-$(env_chart_version "$ENV_NAME" || true)}"
[[ "$CHART_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "prove-promotion: no chart version to prove: set CHART_VERSION, or pin one in gitops/envs/${ENV_NAME}/gibson.yaml (got '${CHART_VERSION}')" >&2; exit 2; }
LAND_POLL="${LAND_POLL:-20}"

# shellcheck source=lib/smoke-probe.sh
source "$REPO/scripts/lib/smoke-probe.sh"

# refresh_and_read: a hard refresh, then the app document in
# /tmp/${APP}-app.json. Argo removes the annotation when the refresh is done.
# A failed read is not "done": it writes its error to the landed log and
# returns 1, so the wait polls again and the deadline ends it.
refresh_and_read() {
  local refreshed=0 pending
  kubectl -n argocd annotate "application/${APP}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null \
    || { echo "cannot annotate application/${APP} for a hard refresh" > "/tmp/${APP}-landed.log"; return 1; }
  for _ in $(seq 1 60); do
    pending=""
    capture pending kubectl -n argocd get "application/${APP}" \
      -o 'jsonpath={.metadata.annotations.argocd\.argoproj\.io/refresh}' \
      || { echo "cannot read application/${APP}: ${PROBE_ERR}" > "/tmp/${APP}-landed.log"; return 1; }
    [ -n "$pending" ] || { refreshed=1; break; }
    sleep 5
  done
  [ "$refreshed" = 1 ] || { echo "the hard refresh of application/${APP} did not finish in 300s" > "/tmp/${APP}-landed.log"; return 1; }
  kubectl -n argocd get "application/${APP}" -o json > "/tmp/${APP}-app.json" \
    || { echo "cannot read application/${APP} as JSON" > "/tmp/${APP}-landed.log"; return 1; }
}

# pins_chart_version: true when the live spec of the app pins CHART_VERSION
# (the OCI chart source, the one with a chart name).
pins_chart_version() {
  local have
  # The same source as check-promotion-landed.sh reads: sources[0].
  have="$(jq -r '(.spec.sources[0] // .spec.source).targetRevision // empty' "/tmp/${APP}-app.json")"
  [ "$have" = "$CHART_VERSION" ] && return 0
  echo "the live spec of application/${APP} pins '${have:-nothing}', not ${CHART_VERSION} yet" > "/tmp/${APP}-landed.log"
  return 1
}

# THE PROMOTION LANDS BEFORE THE SMOKE. promote-staging starts a minute
# after the pin merges, while Argo still rolls the new chart out. Run
# 39137283280 signed up during that rollout: the daemon and the dashboard
# restarted under the signup, and the smoke failed on a promotion that was
# fine (setup_failed). So the proof first waits until the operation of the
# app Succeeded at the pinned revision and the app is Healthy, then runs the
# smoke on the version it proves.
echo "▶ [prove] wait until the promotion of ${CHART_VERSION} lands (up to ${LAND_WAIT}s)"
land_deadline=$(( $(date +%s) + LAND_WAIT ))
: > "/tmp/${APP}-landed.log"
# A failed read inside the wait is one more poll, not the end of the proof:
# an SSM forward can drop once during a rollout. The deadline ends it.
until refresh_and_read && pins_chart_version && bash "$LANDED_CHECK" "/tmp/${APP}-app.json" \
        "$REPO/gitops/envs/${ENV_NAME}/prune-allowlist.yaml" > "/tmp/${APP}-landed.log" 2>&1; do
  printf '  not landed yet: %s\n' "$(tail -n1 "/tmp/${APP}-landed.log")"
  if [ "$(date +%s)" -ge "$land_deadline" ]; then
    cat "/tmp/${APP}-landed.log" >&2
    echo "prove-promotion: the promotion did not land within ${LAND_WAIT}s" >&2
    exit 1
  fi
  sleep "$LAND_POLL"
done
echo "  the promotion landed: $(tail -n1 "/tmp/${APP}-landed.log")"

# Ready and the smoke are not promotion-specific, so they live in
# prove-bringup.sh and the drill uses the same code (ADR-0027). This script is
# that, plus the one assertion a promotion adds.
echo "▶ [prove] the platform is up and a tenant can be created"
ENV_DOMAIN="$ENV_DOMAIN" NAMESPACE="$NAMESPACE" "$PROVE_BRINGUP" "$ENV_NAME"

# The smoke changed nothing the chart owns: the promotion still holds.
echo "▶ [prove] the promotion still landed after the smoke"
refresh_and_read || { cat "/tmp/${APP}-landed.log" >&2; exit 1; }
pins_chart_version || { cat "/tmp/${APP}-landed.log" >&2; exit 1; }
bash "$LANDED_CHECK" \
  "/tmp/${APP}-app.json" "$REPO/gitops/envs/${ENV_NAME}/prune-allowlist.yaml"

# A prune allowlist entry that matches no live object is stale: the prune
# ran, and the entry must go (hosted#748). check-promotion-landed.sh above
# fails only on residue nobody reviewed. The audit also fails on a stale
# entry. An env with no allowlist has nothing to audit.
if [ -f "$REPO/gitops/envs/${ENV_NAME}/prune-allowlist.yaml" ]; then
  echo "▶ [prove] each prune allowlist entry still names a live object"
  bash "$REPO/gitops/scripts/prune-orphans.sh" audit "$ENV_NAME" "/tmp/${APP}-app.json"
fi

echo "✓ [prove] Ready, the promotion landed, and the smoke passed"
