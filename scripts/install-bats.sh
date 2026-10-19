#!/usr/bin/env bash
# install-bats.sh: install bats-core at one pinned commit, with a time bound.
#
# CI installed bats with `apt-get update && apt-get install bats`. On
# 2026-10-07 the Ubuntu mirror gave no answer three times, and each run of
# ci-required hit its 15-minute timeout inside apt-get before any gate ran
# (hosted#518, hosted#519). This fetches the bats release from GitHub, checks
# the commit, and fails in 2 minutes at most.
#
# Usage: scripts/install-bats.sh <prefix>   (bats lands in <prefix>/bin)
set -euo pipefail

BATS_TAG="v1.13.0"
BATS_COMMIT="3bca150ec86275d6d9d5a4fd7d48ab8b6c6f3d87"
prefix="${1:?usage: install-bats.sh <prefix>}"

src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT
timeout 120 git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$BATS_TAG" https://github.com/bats-core/bats-core.git "$src/bats-core"
got="$(git -C "$src/bats-core" rev-parse HEAD)"
[ "$got" = "$BATS_COMMIT" ] || { echo "::error::bats ${BATS_TAG} is commit ${got}, not the pinned ${BATS_COMMIT}" >&2; exit 1; }
"$src/bats-core/install.sh" "$prefix" >/dev/null
"$prefix/bin/bats" --version
