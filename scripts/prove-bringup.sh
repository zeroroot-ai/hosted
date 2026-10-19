#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# prove-bringup.sh — the platform is up and a tenant can be created, for ANY
# environment (ADR-0095). Run it inside with-cluster.sh, so KUBECONFIG names the
# SSM forward:
#
#   make with-cluster ENV=drill CMD='scripts/prove-bringup.sh drill'
#
# Two assertions, and nothing about a chart version:
#
#   Ready   every Argo Application Synced+Healthy. For a drill this is the
#           bringup under test. For a permanent environment it is a
#           precondition.
#   smoke   signup -> tenant Ready -> data-plane secrets -> api-edge auth chain,
#           against the public host.
#
# scripts/prove-promotion.sh is this plus the promotion assertion, and calls it
# rather than repeating it: a drill promotes nothing, so asserting a pin landed
# would be asserting against a mechanism that did not run (ADR-0094 rule 6).
# ---------------------------------------------------------------------------
set -euo pipefail

ENV_NAME="${1:-}"
[ -n "$ENV_NAME" ] || { echo "usage: prove-bringup.sh <env>" >&2; exit 2; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-gibson}"
ENV_DOMAIN="${ENV_DOMAIN:-${ENV_NAME}.zeroroot.ai}"

echo "▶ [prove] every Application Synced+Healthy"
"$REPO/scripts/bringup-status.sh" "$ENV_NAME"

# The signup smoke signs up through the edge with the one signup driver
# (hosted#647). Per env only the target inputs differ: the mail lands in the
# test inbox of stage 0 (substrate.env INBOX_BUCKET, INBOX_DOMAIN), and the
# SaaS profile pays the signup step with the Stripe TEST card.
case "$ENV_NAME" in
  prod)
    # Prod holds a live Stripe key. The smoke never pays on a live key, and a
    # card-first signup cannot finish without paying, so prod proves the
    # bringup above and stops here, and says so.
    echo "▶ [prove] signup smoke: NOT RUN on prod. Prod holds a live Stripe key, and the smoke never pays on one (hosted#647)"
    echo "✓ [prove] the platform is up (no signup smoke on prod)"
    exit 0 ;;
esac
# The test inbox of the env, read from its live SES rule (stage 0 inbox.tf):
# the rule zeroroot-ai-<env>-inbox in the one active rule set names the
# recipient domain and the bucket. The rule is what SES acts on, so the smoke
# reads the same fact SES uses, and no second copy of it.
region="${AWS_REGION:-us-east-1}"
# shellcheck source=lib/smoke-probe.sh
source "$REPO/scripts/lib/smoke-probe.sh"
# An AWS error (no credentials, AccessDenied) stops the run with its text. It
# never reads as "no rule set" (scripts/lib/smoke-probe.sh, THE RULE).
rule_set=""
capture rule_set aws ses describe-active-receipt-rule-set --region "$region" --query 'Metadata.Name' --output text \
  || { echo "prove-bringup: cannot read the active SES receipt rule set: ${PROBE_ERR}" >&2; exit 2; }
case "$rule_set" in ''|None) echo "prove-bringup: the account has no active SES receipt rule set. Apply substrate/apex-zone, then make substrate ENV=${ENV_NAME} (hosted#647)" >&2; exit 2 ;; esac
rule="zeroroot-ai-${ENV_NAME}-inbox"
INBOX_DOMAIN=""
INBOX_BUCKET=""
capture INBOX_DOMAIN aws ses describe-receipt-rule --region "$region" --rule-set-name "$rule_set" --rule-name "$rule" \
  --query 'Rule.Recipients[0]' --output text \
  || { echo "prove-bringup: cannot read the SES rule ${rule} in ${rule_set}: ${PROBE_ERR}. Run make substrate ENV=${ENV_NAME} if it is absent (hosted#647)" >&2; exit 2; }
capture INBOX_BUCKET aws ses describe-receipt-rule --region "$region" --rule-set-name "$rule_set" --rule-name "$rule" \
  --query 'Rule.Actions[0].S3Action.BucketName' --output text \
  || { echo "prove-bringup: cannot read the SES rule ${rule} in ${rule_set}: ${PROBE_ERR}" >&2; exit 2; }
case "${INBOX_DOMAIN}${INBOX_BUCKET}" in
  ''|*None*) echo "prove-bringup: no inbox rule ${rule} in ${rule_set}. Run make substrate ENV=${ENV_NAME} (hosted#647)" >&2; exit 2 ;;
esac

echo "▶ [prove] signup -> tenant Ready -> data-plane secrets -> api-edge auth"
CLUSTER_URL="https://app.${ENV_DOMAIN}" NAMESPACE="$NAMESPACE" \
  MAIL_SOURCE=s3 INBOX_BUCKET="$INBOX_BUCKET" INBOX_DOMAIN="$INBOX_DOMAIN" SIGNUP_PROFILE=saas \
  "$REPO/scripts/smoke-signup.sh"

echo "✓ [prove] the platform is up and a tenant can be created"
