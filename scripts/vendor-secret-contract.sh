#!/usr/bin/env bash
# vendor-secret-contract.sh: copy the secret contract out of a published chart.
#
# The secret contract describes the chart, so it lives in zeroroot-ai/charts
# (helm/gibson/secret-contract.yaml, charts#433). Each release of the umbrella
# chart ships it at gibson/secret-contract.yaml. hosted vendors that file at the
# staging pin (hosted#422): vendor/charts/secret-contract.yaml holds the bytes
# and vendor/charts/secret-contract.version names the release.
# scripts/check-secret-contract.py fails when the copy differs from the chart.
#
# promote-bump.yml runs this on each staging promotion, so the copy moves with
# the pin in the same pull request.
#
# Usage: scripts/vendor-secret-contract.sh <chart version>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OCI="oci://ghcr.io/zeroroot-ai/charts/gibson"
version="${1:?usage: vendor-secret-contract.sh <chart version>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::'${version}' is not a bare chart version" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
helm pull "$OCI" --version "$version" --destination "$tmp" >/dev/null
tar -xzOf "$tmp/gibson-${version}.tgz" gibson/secret-contract.yaml >"$tmp/contract.yaml" 2>/dev/null \
  || { echo "::error::chart ${version} ships no gibson/secret-contract.yaml (the first release with it is 0.138.0)" >&2; exit 1; }
[ -s "$tmp/contract.yaml" ] || { echo "::error::chart ${version} ships an empty secret contract" >&2; exit 1; }

mkdir -p "$ROOT/vendor/charts"
cp "$tmp/contract.yaml" "$ROOT/vendor/charts/secret-contract.yaml"
printf '%s\n' "$version" >"$ROOT/vendor/charts/secret-contract.version"
echo "vendored the secret contract of chart ${version}"
