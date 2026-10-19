#!/usr/bin/env bash
# install.sh — install the pinned Terraform with retries and a checksum.
#
# WHY THIS EXISTS
#
# Blocker 1 (exit-test-terraform.yml, run 35563392735, 2026-09-21) went red
# before the plan ran. The `Install Terraform` step, hashicorp/setup-terraform,
# failed with `read ECONNRESET` on one download and did not retry. Every
# workflow that ran Terraform installed it the same way, so every one of them
# carried the same single point of failure. The verbs (recreate, teardown,
# promote-staging) took whatever Terraform the runner image shipped, so they
# did not even run the pinned version.
#
# This script is the one installer. It reads the pin from .terraform-version
# at the repo root, downloads the release zip and its SHA256SUMS with retries,
# verifies the zip against the SHA256SUMS line, unzips into one tool dir, and
# proves the binary reports the pinned version. It refuses on any miss.
#
# Inputs (environment):
#   TERRAFORM_INSTALL_DIR   where the binary lands (default $RUNNER_TEMP/terraform-bin)
#   TERRAFORM_RELEASES_URL  release server (default https://releases.hashicorp.com,
#                           the offline suite points it at a file:// tree)
#
# On success the install dir is appended to $GITHUB_PATH when that file exists.
#
# Offline suite: tests/harness/install-terraform.bats
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PIN_FILE="$ROOT/.terraform-version"

fail() { echo "::error::install-terraform: $*" >&2; exit 1; }

[ -s "$PIN_FILE" ] || fail "$PIN_FILE is missing or empty. The pin lives there and nowhere else."
version="$(tr -d '[:space:]' < "$PIN_FILE")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "'$version' in $PIN_FILE is not a release version (X.Y.Z)"

releases="${TERRAFORM_RELEASES_URL:-https://releases.hashicorp.com}"
install_dir="${TERRAFORM_INSTALL_DIR:-${RUNNER_TEMP:-}/terraform-bin}"
[ "$install_dir" != "/terraform-bin" ] || fail "set TERRAFORM_INSTALL_DIR or RUNNER_TEMP"

zip="terraform_${version}_linux_amd64.zip"
sums="terraform_${version}_SHA256SUMS"
base="${releases}/terraform/${version}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# One transient reset must not fail a run. --retry-all-errors covers a reset
# mid-body, which a plain --retry does not.
fetch() {
  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 3 \
    --output "$work/$1" "$base/$1" \
    || fail "could not download $base/$1 after 5 retries"
}
fetch "$zip"
fetch "$sums"

# Exactly one SHA256SUMS line names this zip. Zero lines means the release
# server answered with the wrong file, and that is a refusal, not a pass.
line="$(grep -E "^[0-9a-f]{64}  ${zip}$" "$work/$sums" || true)"
[ -n "$line" ] || fail "$sums has no line for $zip"
[ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ] || fail "$sums names $zip more than once"
( cd "$work" && printf '%s\n' "$line" | sha256sum --check --strict --status ) \
  || fail "$zip does not match its SHA256SUMS line"

rm -rf "$install_dir"; mkdir -p "$install_dir"
unzip -q -o "$work/$zip" terraform -d "$install_dir" || fail "$zip holds no terraform binary"
chmod +x "$install_dir/terraform"

# The binary must say the pinned version. A zip that verifies but holds a
# different build is still a miss.
#
# Capture the WHOLE output, then take the first line. Piping into `head -n1`
# under pipefail killed a correct binary: head exits after line one, the
# binary gets SIGPIPE writing its next line ("on linux_amd64", an update
# notice), and the pipeline fails as "does not run". That timing race turned
# blocker 1 red with a checksum-verified binary (run 36380539803).
# CHECKPOINT_DISABLE stops the update check, a network call, from running at
# all.
out="$(CHECKPOINT_DISABLE=1 "$install_dir/terraform" version 2>&1)" || fail "the installed binary does not run"
# First line by parameter expansion, not another pipe into head: that pipe
# has the same SIGPIPE race on long output.
reported="${out%%$'\n'*}"
[ "$reported" = "Terraform v${version}" ] || fail "installed binary reports '$reported', pin is v${version}"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$install_dir" >> "$GITHUB_PATH"
fi
echo "install-terraform: $reported, verified against $sums, at $install_dir/terraform"
