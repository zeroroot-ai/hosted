#!/usr/bin/env bash
# eks-sweep-admission-webhooks.sh — remove admission webhook configurations
# before a cluster teardown can strand them (deploy#1592).
#
# THE DEADLOCK THIS PREVENTS
# -------------------------
# `terraform destroy`'s graph is free to remove a webhook's backing workload
# before it removes the custom resources that webhook gates. Observed live on
# staging 2026-08-16:
#
#   Error: aws-secretsmanager failed to delete kubernetes resource: Internal
#   error occurred: failed calling webhook
#   "validate.clustersecretstore.external-secrets.io": ... no endpoints
#   available for service "external-secrets-webhook"
#   Error: context deadline exceeded
#
# The external-secrets Deployment was gone, so Endpoints/external-secrets-webhook
# was empty, but the ValidatingWebhookConfiguration `secretstore-validate` still
# existed and still had a blocking failure policy. The API server therefore
# refused the four ClusterSecretStore deletions terraform was asking for, and
# the destroy blocked until the context deadline. It cannot self-resolve: the
# only thing that could answer the webhook is already destroyed. Two full
# teardown attempts (~40 min each) failed before a human cleared it by hand.
#
# THE RULE
# --------
# The whole cluster is being destroyed. Every admission webhook backed by an
# IN-CLUSTER Service will therefore lose its backend at some unpredictable
# point in the destroy graph, and any such webhook left in place can only ever
# block the teardown — admission control has no value on a cluster that is
# being deleted. So:
#
#   Delete every ValidatingWebhookConfiguration and MutatingWebhookConfiguration
#   that has at least one webhook whose clientConfig names a Service.
#
# This is deliberately NOT a hardcoded list of the webhooks we ship today.
# The platform installs them from two independent sources — the gibson umbrella
# chart (cnpg, tenant-operator, gibson controller-manager, setec) and Terraform
# helm_releases in modules/bootstrap-addons (cert-manager, external-secrets,
# aws-privateca-issuer) — so any name list would silently rot the next time
# either source gains a component. The endpoint state is not consulted either:
# at pre-destroy time the backing pods are usually still RUNNING (that is the
# whole point of running this first), so an "only sweep what already has no
# endpoints" rule would have swept nothing on 2026-08-16 and changed nothing.
#
# DELIBERATELY NOT SWEPT
# ----------------------
#   * ValidatingAdmissionPolicy / ValidatingAdmissionPolicyBinding — a
#     different API group (admissionregistration.k8s.io policies, not webhook
#     configurations). They are evaluated IN the API server via CEL and call
#     nothing over the network, so they cannot deadlock on missing endpoints.
#     setec ships four of these (setec#159 sandbox/node guards) and gibson
#     ships two; deleting them would be pointless churn.
#   * Webhooks whose clientConfig is a `url:` rather than a `service:` — those
#     point outside the cluster and do not depend on cluster endpoints.
#
# SAFETY CONTRACT
# ---------------
# This script runs on the teardown path and must never be the reason a destroy
# aborts. It therefore:
#   * ALWAYS exits 0 — including when kubectl is missing, the cluster is
#     already gone, credentials are expired, or the API server is unreachable;
#   * is idempotent — a second run finds nothing and says so;
#   * never uses `set -e` semantics that could propagate a kubectl failure.
# A cluster we cannot reach is a cluster whose webhooks cannot block anything
# we are about to do, so "unreachable" is a legitimate no-op, not an error.
#
# Usage:
#   bash eks-sweep-admission-webhooks.sh            # sweep
#   DRY_RUN=1 bash eks-sweep-admission-webhooks.sh  # report only, delete nothing
#
# Env:
#   KUBECTL   kubectl binary/command to use (default: kubectl)
#   DRY_RUN   set to 1 to list what would be deleted without deleting
#
# Run standalone by an operator to clear a teardown that is already wedged.

# NOTE: no `set -e`. See SAFETY CONTRACT above — a kubectl failure here must
# degrade to a no-op, not abort the caller's teardown.
set -uo pipefail

KUBECTL="${KUBECTL:-kubectl}"
DRY_RUN="${DRY_RUN:-0}"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

SWEPT_KINDS=(validatingwebhookconfigurations mutatingwebhookconfigurations)

printf "${GREEN}▶${NC} Sweeping service-backed admission webhooks (deploy#1592)...\n"

if ! command -v "${KUBECTL%% *}" >/dev/null 2>&1; then
  printf "  ${YELLOW}!${NC} %s not on PATH — nothing to sweep.\n" "${KUBECTL%% *}"
  exit 0
fi

swept=0
skipped=0
failed=0

for kind in "${SWEPT_KINDS[@]}"; do
  # One line per configuration:
  #   <name><TAB><svcname>,<svcns>;<svcname>,<svcns>;...
  # A webhook with a `url:` clientConfig contributes an empty ",;" pair, so a
  # url-only configuration yields a service field of just ",;" repeated — which
  # contains no alphanumerics and is filtered out below.
  listing="$(
    "$KUBECTL" get "$kind" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .webhooks[*]}{.clientConfig.service.name}{","}{.clientConfig.service.namespace}{";"}{end}{"\n"}{end}' \
      2>/dev/null
  )"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    # Unreachable cluster, expired credentials, or the CRD-less API of an
    # already-destroyed control plane. Not an error on this path.
    printf "  ${YELLOW}!${NC} could not list %s (cluster unreachable or already gone) — skipping.\n" "$kind"
    continue
  fi

  while IFS=$'\t' read -r name services; do
    [ -n "$name" ] || continue

    # Service-backed iff the service field carries an actual name, i.e. at
    # least one character that is not a separator. `,;,;` means every webhook
    # in this configuration is url-backed.
    if ! printf '%s' "$services" | grep -q '[^,;[:space:]]'; then
      printf "  ${YELLOW}·${NC} %s/%s is url-backed (no in-cluster Service) — left in place.\n" "$kind" "$name"
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      printf "  would delete %s/%s (backed by %s)\n" "$kind" "$name" "$services"
      swept=$((swept + 1))
      continue
    fi

    if "$KUBECTL" delete "$kind" "$name" --ignore-not-found --timeout=30s >/dev/null 2>&1; then
      printf "  deleted %s/%s (backed by %s)\n" "$kind" "$name" "$services"
      swept=$((swept + 1))
    else
      # Best-effort by contract. A webhook we could not delete is reported so
      # the operator can clear it by hand, but it does not fail the teardown.
      printf "  ${YELLOW}!${NC} could not delete %s/%s — clear it by hand if the destroy wedges:\n" "$kind" "$name"
      printf "      kubectl delete %s %s\n" "$kind" "$name"
      failed=$((failed + 1))
    fi
  done <<< "$listing"
done

if [ "$swept" -eq 0 ] && [ "$failed" -eq 0 ]; then
  printf "  no service-backed admission webhooks present (already swept, or cluster gone).\n"
else
  printf "  swept %d, left %d url-backed, %d could not be deleted.\n" "$swept" "$skipped" "$failed"
fi

printf "  ValidatingAdmissionPolicy/Binding deliberately untouched (CEL, no endpoints).\n"

exit 0
