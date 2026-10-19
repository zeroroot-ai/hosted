#!/usr/bin/env bash
# install.sh: install the pinned helm, kubectl and session-manager-plugin.
#
# Each file is downloaded with retries, checked against the sha256 of
# pins.env, and installed. Then each binary must report the pinned version.
# A miss at any point is a refusal, never a fallback to the runner's own copy.
#
# Inputs (environment):
#   CLUSTER_TOOLS_DIR   where helm and kubectl land (default $RUNNER_TEMP/cluster-tools)
#   CLUSTER_TOOLS_PINS  the pin file (default pins.env next to this script)
#   HELM_URL KUBECTL_URL SSM_PLUGIN_URL   the download bases; the offline
#                       suite points them at a file:// tree
#   DPKG                the deb installer (default `sudo dpkg`)
#
# On success the tool dir is put first on $GITHUB_PATH when that file exists.
#
# Offline suite: tests/harness/install-cluster-tools.bats
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINS="${CLUSTER_TOOLS_PINS:-$HERE/pins.env}"

fail() { echo "::error::install-cluster-tools: $*" >&2; exit 1; }

[ -s "$PINS" ] || fail "$PINS is missing or empty"
# shellcheck disable=SC1090
. "$PINS"
for v in HELM_VERSION HELM_SHA256 KUBECTL_VERSION KUBECTL_SHA256 SSM_PLUGIN_VERSION SSM_PLUGIN_SHA256; do
  [ -n "${!v:-}" ] || fail "$PINS sets no $v"
done
for v in HELM_SHA256 KUBECTL_SHA256 SSM_PLUGIN_SHA256; do
  [[ "${!v}" =~ ^[0-9a-f]{64}$ ]] || fail "$v in $PINS is not a sha256"
done

helm_base="${HELM_URL:-https://get.helm.sh}"
kubectl_base="${KUBECTL_URL:-https://dl.k8s.io/release}"
ssm_base="${SSM_PLUGIN_URL:-https://s3.amazonaws.com/session-manager-downloads/plugin}"
dir="${CLUSTER_TOOLS_DIR:-${RUNNER_TEMP:-}/cluster-tools}"
[ "$dir" != "/cluster-tools" ] || fail "set CLUSTER_TOOLS_DIR or RUNNER_TEMP"
read -r -a dpkg <<< "${DPKG:-sudo dpkg}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# fetch URL FILE SHA256: download with retries, then check the sha256.
fetch() {
  curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 3 \
    --output "$work/$2" "$1" \
    || fail "could not download $1 after 5 retries"
  printf '%s  %s\n' "$3" "$work/$2" | sha256sum --check --strict --status \
    || fail "$1 does not match its pinned sha256"
}

rm -rf "$dir"; mkdir -p "$dir"

fetch "${helm_base}/helm-${HELM_VERSION}-linux-amd64.tar.gz" helm.tgz "$HELM_SHA256"
tar -xzf "$work/helm.tgz" -C "$work" linux-amd64/helm || fail "the helm archive holds no linux-amd64/helm"
install -m 0755 "$work/linux-amd64/helm" "$dir/helm"

fetch "${kubectl_base}/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" kubectl "$KUBECTL_SHA256"
install -m 0755 "$work/kubectl" "$dir/kubectl"

fetch "${ssm_base}/${SSM_PLUGIN_VERSION}/ubuntu_64bit/session-manager-plugin.deb" ssm.deb "$SSM_PLUGIN_SHA256"
"${dpkg[@]}" -i "$work/ssm.deb" >/dev/null || fail "the session-manager-plugin deb did not install"

# Each binary must say its pin. A file that verifies but holds another build
# is still a miss.
out="$("$dir/helm" version --template '{{.Version}}' 2>&1)" || fail "the installed helm does not run"
[ "$out" = "$HELM_VERSION" ] || fail "helm reports '$out', the pin is $HELM_VERSION"
out="$("$dir/kubectl" version --client -o json 2>&1)" || fail "the installed kubectl does not run"
case "$out" in *"\"gitVersion\": \"${KUBECTL_VERSION}\""*) ;; *) fail "kubectl does not report ${KUBECTL_VERSION}" ;; esac
command -v session-manager-plugin >/dev/null || fail "session-manager-plugin is not on PATH after the install"
out="$(session-manager-plugin --version 2>&1)" || fail "the installed session-manager-plugin does not run"
[ "$out" = "$SSM_PLUGIN_VERSION" ] || fail "session-manager-plugin reports '$out', the pin is $SSM_PLUGIN_VERSION"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$dir" >> "$GITHUB_PATH"
fi
echo "install-cluster-tools: helm ${HELM_VERSION}, kubectl ${KUBECTL_VERSION}, session-manager-plugin ${SSM_PLUGIN_VERSION}, each checked against its sha256"
