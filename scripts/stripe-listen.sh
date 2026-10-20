#!/usr/bin/env bash
# stripe-listen.sh — kind's Stripe webhook tunnel, with secret reconciliation.
#
# WHY THIS EXISTS
#
# kind has no public ingress, so Stripe cannot POST to the Envoy edge. The
# SaaS profile the dev cluster runs (deploy#1132, gitops#353) needs those
# deliveries: the receiver projects each tenant's subscription_status into
# tenant_quotas, which is where the entitlements provider reads it to
# payment-gate plan limits. Without a tunnel, signup completes and the tenant's
# billing state simply never converges.
#
# THE TRAP THIS CLOSES (deploy#1135)
#
# `stripe listen` signs with the secret it derives for the API key. That is NOT
# the signing secret of a webhook endpoint registered in the Stripe Dashboard.
# `make kind-up` seeds gibson-stripe-credentials from ~/.stripe-webhook.tok, and
# that Terraform resource carries `lifecycle { ignore_changes = all }` — so
# correcting the file is not enough, the seeded value only moves via a
# `terraform apply -replace`, an ESO force-sync, and a restart of every consumer
# holding it in env.
#
# When the two disagree, EVERY delivery fails signature verification and the
# only signal is one WARN line in the receiver. Signup still succeeds. Billing
# state silently never lands. That failure was hit by hand during the dev SaaS
# flip; this script makes it impossible to start a listener in that state.
#
# Usage:
#   scripts/stripe-listen.sh              # reconcile, then run the tunnel
#   scripts/stripe-listen.sh --check      # reconcile/verify only, no listener
#   FORWARD_TO=<url> scripts/stripe-listen.sh
#
# Env:
#   NAMESPACE      k8s namespace                (default: gibson)
#   STRIPE_KEY_FILE  API key file               (default: ~/.stripe.tok)
#   WHSEC_FILE     webhook secret file          (default: ~/.stripe-webhook.tok)
#   FORWARD_TO     delivery target              (default: the Envoy edge)
#   AUTO_RECONCILE set 0 to refuse to mutate the cluster and just report
set -euo pipefail

NAMESPACE="${NAMESPACE:-gibson}"
STRIPE_KEY_FILE="${STRIPE_KEY_FILE:-$HOME/.stripe.tok}"
WHSEC_FILE="${WHSEC_FILE:-$HOME/.stripe-webhook.tok}"
# The edge path, not a port-forward: deploy#1132 gave Envoy the prefix_rewrite
# that maps /api/billing/webhook onto the receiver's /webhook, so kind can
# exercise the same hop staging and prod do. --skip-verify covers the
# self-signed kind edge certificate.
FORWARD_TO="${FORWARD_TO:-https://app.zeroroot.ai:30443/api/billing/webhook}"
AUTO_RECONCILE="${AUTO_RECONCILE:-1}"
SECRET_NAME="gibson-stripe-credentials"
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kind/gibson"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
info() { printf '%s▶%s [stripe-listen] %s\n' "$GREEN" "$NC" "$1"; }
ok()   { printf '%s  ✓%s [stripe-listen] %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '%s  ~%s [stripe-listen] %s\n' "$YELLOW" "$NC" "$1"; }
die()  { printf '%s!%s [stripe-listen] %s\n' "$RED" "$NC" "$1" >&2; exit 1; }

command -v stripe  >/dev/null || die "stripe CLI not found — https://docs.stripe.com/stripe-cli"
command -v kubectl >/dev/null || die "kubectl not found"
[ -f "$STRIPE_KEY_FILE" ] || die "no Stripe API key at $STRIPE_KEY_FILE"

API_KEY="$(tr -d '\r\n' < "$STRIPE_KEY_FILE")"
case "$API_KEY" in
  sk_test_*) ;;
  sk_live_*) die "$STRIPE_KEY_FILE holds a LIVE key — refusing to point live Stripe at a kind cluster" ;;
  *) die "$STRIPE_KEY_FILE does not look like a Stripe secret key" ;;
esac

# ---------------------------------------------------------------------------
# What the CLI will actually sign with, versus what the cluster will verify
# against.
# ---------------------------------------------------------------------------
info "resolving the signing secret for this API key..."
CLI_SECRET="$(STRIPE_API_KEY="$API_KEY" stripe listen --print-secret 2>/dev/null | tr -d '\r\n')"
[ -n "$CLI_SECRET" ] || die "stripe listen --print-secret returned nothing (is the key valid?)"

cluster_secret() {
  kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o jsonpath='{.data.STRIPE_WEBHOOK_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true
}
CLUSTER_SECRET="$(cluster_secret)"
[ -n "$CLUSTER_SECRET" ] || die "$NAMESPACE/$SECRET_NAME has no STRIPE_WEBHOOK_SECRET — is the cluster up?"

if [ "$CLI_SECRET" = "$CLUSTER_SECRET" ]; then
  ok "signing secret matches the cluster (${CLI_SECRET:0:14}...)"
else
  warn "signing secret MISMATCH — every delivery would fail verification"
  printf '      stripe listen : %s...\n' "${CLI_SECRET:0:14}"
  printf '      cluster       : %s...\n' "${CLUSTER_SECRET:0:14}"

  if [ "$AUTO_RECONCILE" != "1" ]; then
    die "AUTO_RECONCILE=0 — refusing to mutate the cluster. Reconcile manually:
      printf '%s' '$CLI_SECRET' > $WHSEC_FILE
      TF_VAR_stripe_webhook_secret=\"\$(cat $WHSEC_FILE)\" \\
        terraform -chdir=$TF_DIR apply -auto-approve -replace=kubernetes_secret_v1.stripe_credentials
      kubectl -n $NAMESPACE annotate externalsecret $SECRET_NAME force-sync=\$(date +%s) --overwrite
      # Reloader rolls the consumers from their reload annotation — do not restart by hand."
  fi

  info "reconciling: file → Terraform → ESO → consumers"

  # 1. The file the kind terraform seeds from. Keep a backup: the previous value
  #    may be a Dashboard endpoint secret someone still needs.
  if [ -f "$WHSEC_FILE" ] && [ "$(tr -d '\r\n' < "$WHSEC_FILE")" != "$CLI_SECRET" ]; then
    cp "$WHSEC_FILE" "${WHSEC_FILE}.bak-$(date +%Y%m%d%H%M%S)"
    warn "previous $WHSEC_FILE backed up alongside it"
  fi
  printf '%s' "$CLI_SECRET" > "$WHSEC_FILE"
  chmod 600 "$WHSEC_FILE"

  # 2. Terraform owns the backend Secret and ignores in-place changes
  #    (lifecycle ignore_changes = all), so -replace is the only lever.
  command -v terraform >/dev/null || die "terraform not found — needed to reseed $SECRET_NAME"
  info "terraform -replace on the stripe credentials secret..."
  TF_VAR_stripe_secret_key="$API_KEY" \
  TF_VAR_stripe_webhook_secret="$CLI_SECRET" \
  TF_VAR_stripe_publishable_key="$( [ -f "$HOME/.stripe-pk.tok" ] && tr -d '\r\n' < "$HOME/.stripe-pk.tok" || echo "" )" \
  TF_VAR_github_token="${TF_VAR_github_token:-$(gh auth token 2>/dev/null || echo "")}" \
    terraform -chdir="$TF_DIR" apply -auto-approve -input=false \
      -replace=kubernetes_secret_v1.stripe_credentials >/dev/null \
    || die "terraform apply failed — reconcile manually and rerun"

  # 3. ESO projects the backend Secret into the workload namespace on its own
  #    refresh interval; force it so the restart below picks up the new value.
  kubectl -n "$NAMESPACE" annotate externalsecret "$SECRET_NAME" \
    "force-sync=$(date +%s)" --overwrite >/dev/null
  info "waiting for ESO to project the new secret..."
  for _ in $(seq 1 30); do
    [ "$(cluster_secret)" = "$CLI_SECRET" ] && break
    sleep 2
  done
  [ "$(cluster_secret)" = "$CLI_SECRET" ] || die "ESO did not project the new secret within 60s"

  # 4. Consumers hold it in env, captured at pod start — a synced Secret alone
  #    changes nothing until they roll. That roll is DECLARATIVE: the dashboard,
  #    tenant-operator and billing-webhook all carry a
  #    secret.reloader.stakater.com/reload annotation naming this Secret
  #    (deploy#1144), so Reloader rolls them when it changes. This script must
  #    not restart anything itself — mutating a live cluster by hand is exactly
  #    what the annotation exists to avoid.
  info "waiting for Reloader to roll the consumers..."
  for d in gibson-billing-webhook gibson-dashboard; do
    kubectl -n "$NAMESPACE" rollout status "deploy/$d" --timeout=180s >/dev/null 2>&1 || \
      warn "$d did not report a completed rollout within 180s — check its Reloader annotation"
  done
  ok "reconciled — cluster now verifies against ${CLI_SECRET:0:14}..."
fi

if [ "${1:-}" = "--check" ]; then
  ok "check only — not starting a listener"
  exit 0
fi

# ---------------------------------------------------------------------------
# Supervised tunnel. `stripe listen` drops its websocket on network blips and on
# laptop sleep; an unsupervised listener dies quietly and takes billing
# convergence with it, which is the failure this whole script exists to prevent.
# ---------------------------------------------------------------------------
info "forwarding Stripe events → $FORWARD_TO"
info "press Ctrl+C to stop"
while true; do
  STRIPE_API_KEY="$API_KEY" stripe listen --forward-to "$FORWARD_TO" --skip-verify || true
  warn "listener exited — restarting in 3s"
  sleep 3
done
