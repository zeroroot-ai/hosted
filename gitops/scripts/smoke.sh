#!/usr/bin/env bash
# Post-promotion smoke for an env (ADR-0072 / gitops#251).
#
# Baseline edge smoke: the public app + api hosts must answer over TLS after a
# chartVersion promotion has synced Healthy. The env domain is read from the
# overlay (envs/<env>/values.yaml :: global.domain) so there is one source of
# truth. Extend this with deeper checks (signup round-trip, an authenticated
# daemon RPC) — the deploy repo's signup-smoke is the richer follow-on hook.
#
# Exit non-zero => the promotion did not land, and the caller must fail.
#
# Usage: scripts/smoke.sh <staging|prod>
set -euo pipefail

env="${1:?usage: smoke.sh <staging|prod>}"
values="envs/${env}/values.yaml"
[ -f "$values" ] || { echo "::error::missing $values"; exit 1; }

# global.domain is the last top-level `domain:` under the `global:` block.
domain="$(awk '/^global:/{g=1;next} g&&/^[^[:space:]]/{g=0} g&&/^[[:space:]]+domain:/{print $2; exit}' "$values" | tr -d '"')"
[ -n "$domain" ] || { echo "::error::could not read global.domain from $values"; exit 1; }
echo "env=$env domain=$domain"

fail=0
check() {
  local url="$1"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --retry 3 --retry-delay 5 "$url" || echo 000)"
  # 2xx/3xx = up (login redirects are expected on the app host).
  if [[ "$code" =~ ^[23] ]]; then
    echo "✓ $url -> $code"
  else
    echo "✗ $url -> $code"; fail=1
  fi
}

check "https://app.${domain}/"
check "https://api.${domain}/"

[ "$fail" -eq 0 ] || { echo "::error::smoke FAILED for ${env}"; exit 1; }
echo "✓ smoke passed for ${env}"
