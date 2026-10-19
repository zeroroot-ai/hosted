#!/usr/bin/env bash
# terraform-init-retry.sh — `terraform init -backend=false` with three attempts.
#
# Provider downloads come from releases.hashicorp.com, and the runner's
# connection to it resets intermittently mid-download (observed on
# deploy#1664: "read: connection reset by peer" installing hashicorp/aws
# v6.61.0, in a root the PR did not touch). One reset turned a validate job
# red for a change that could not have caused it. Same shape as
# scripts/helm-dep-update.sh (deploy#1633) for the chart CDNs.
#
# Usage: scripts/terraform-init-retry.sh <root-dir>
set -euo pipefail
root="${1:?usage: terraform-init-retry.sh <root-dir>}"
for attempt in 1 2 3; do
  if terraform -chdir="$root" init -backend=false -input=false -no-color; then
    exit 0
  fi
  echo "  ⚠ terraform init $root failed (attempt $attempt/3); retrying..." >&2
  sleep $((attempt * 5))
done
echo "ERROR: terraform init $root failed after 3 attempts" >&2
exit 1
