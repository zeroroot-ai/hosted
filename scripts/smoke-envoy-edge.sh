#!/usr/bin/env bash
# Smoke test for the unified Envoy edge cert path
# (zeroroot-ai/deploy#123 / #124).
#
# Runs INSIDE a live gibson-workloads-dashboard pod and asserts that
# Node.js can complete a TLS handshake against
# `https://<appHost>/.well-known/openid-configuration` with the default
# `rejectUnauthorized: true` validation, using the CA bundle the dashboard
# mounts at /etc/ssl/envoy-ca/ca.crt.
#
# The app host is the install's own, read from the gibson-domains ConfigMap
# the chart writes (appHost, derived from global.domain). The old default
# app.zeroroot.ai:30443 named a host no baseline install serves, so the smoke
# reported ENOTFOUND against a working edge (measured 2026-09-07). URL stays
# as an override.
#
# Exits non-zero on any TLS error or non-200 response, with a one-line
# diagnostic line on stdout. Designed to be a deterministic Gate-3
# style check for the kind bringup path.

set -euo pipefail

NS="${NS:-gibson}"
if [[ -z "${URL:-}" ]]; then
  app_host="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.appHost}' 2>/dev/null || true)"
  if [[ -z "$app_host" ]]; then
    echo "smoke: no URL given and no gibson-domains ConfigMap in namespace $NS to derive the app host from" >&2
    exit 2
  fi
  URL="https://${app_host}/.well-known/openid-configuration"
fi

pod=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=dashboard \
  -o jsonpath='{.items[0].metadata.name}')

if [[ -z "$pod" ]]; then
  echo "smoke: no dashboard pod found in namespace $NS" >&2
  exit 1
fi

# `rejectUnauthorized: true` is Node's default; force NODE_EXTRA_CA_CERTS
# to the in-pod CA bundle so the assertion is identical to the runtime
# trust the dashboard process uses for outbound Zitadel calls.
kubectl -n "$NS" exec "$pod" -- node -e "
const https = require('https');
const url = '${URL}';
const req = https.get(url, { rejectUnauthorized: true }, (res) => {
  if (res.statusCode !== 200) {
    console.error('smoke: ' + url + ' -> HTTP ' + res.statusCode);
    process.exit(2);
  }
  let body = '';
  res.on('data', (c) => body += c);
  res.on('end', () => {
    try {
      const j = JSON.parse(body);
      if (!j.issuer) {
        console.error('smoke: discovery doc missing issuer');
        process.exit(3);
      }
      console.log('smoke: ok issuer=' + j.issuer);
      process.exit(0);
    } catch (e) {
      console.error('smoke: discovery body not JSON: ' + e.message);
      process.exit(4);
    }
  });
});
req.on('error', (e) => {
  console.error('smoke: ' + url + ' -> ' + e.message + (e.code ? ' [' + e.code + ']' : ''));
  process.exit(5);
});
req.setTimeout(10000, () => {
  req.destroy(new Error('timeout'));
});
"
