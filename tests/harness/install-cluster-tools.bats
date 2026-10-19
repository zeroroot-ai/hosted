#!/usr/bin/env bats
#
# install-cluster-tools.bats: the cluster tool installer fails closed.
#
# .github/actions/install-cluster-tools/install.sh downloads the pinned helm,
# kubectl and session-manager-plugin, checks each file against the sha256 of
# a pin file, and proves that each binary reports its pin. This suite plants
# each miss and proves that the installer refuses it.
#
# The download servers are a file:// tree under $BATS_TEST_TMPDIR, and a stub
# dpkg stands in for the deb install. No network, no root.
#
# Run:
#   bats tests/harness/install-cluster-tools.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
load assert

setup() {
  INSTALL="$REPO_ROOT/.github/actions/install-cluster-tools/install.sh"
  SRV="$BATS_TEST_TMPDIR/srv"
  SBIN="$BATS_TEST_TMPDIR/sbin"
  mkdir -p "$SRV/helm" "$SRV/k8s/v1.0.0/bin/linux/amd64" "$SRV/ssm/9.9.9/ubuntu_64bit" "$SBIN"
  export HELM_URL="file://$SRV/helm" KUBECTL_URL="file://$SRV/k8s" SSM_PLUGIN_URL="file://$SRV/ssm"
  export CLUSTER_TOOLS_DIR="$BATS_TEST_TMPDIR/tools"
  export CLUSTER_TOOLS_PINS="$BATS_TEST_TMPDIR/pins.env"
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github-path"
  : > "$GITHUB_PATH"
  # The stub dpkg "installs" the deb: the deb file is the plugin script.
  printf '#!/usr/bin/env bash\ninstall -m 0755 "$2" "%s/session-manager-plugin"\n' "$SBIN" > "$BATS_TEST_TMPDIR/dpkg"
  chmod +x "$BATS_TEST_TMPDIR/dpkg"
  export DPKG="$BATS_TEST_TMPDIR/dpkg"
  export PATH="$SBIN:$PATH"
  make_tools v1.2.3 v1.0.0 9.9.9
  write_pins
}

# make_tools HELM KUBECTL SSM: files whose binaries report these versions.
make_tools() {
  local b="$BATS_TEST_TMPDIR/build"
  rm -rf "$b"; mkdir -p "$b/linux-amd64"
  printf '#!/usr/bin/env bash\nprintf "%%s" "%s"\n' "$1" > "$b/linux-amd64/helm"
  chmod +x "$b/linux-amd64/helm"
  tar -czf "$SRV/helm/helm-v1.2.3-linux-amd64.tar.gz" -C "$b" linux-amd64/helm
  printf '#!/usr/bin/env bash\nprintf "{\\n  \\"clientVersion\\": {\\n    \\"gitVersion\\": \\"%s\\"\\n  }\\n}\\n"\n' "$2" \
    > "$SRV/k8s/v1.0.0/bin/linux/amd64/kubectl"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$3" > "$SRV/ssm/9.9.9/ubuntu_64bit/session-manager-plugin.deb"
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

write_pins() {
  cat > "$CLUSTER_TOOLS_PINS" <<PINS
HELM_VERSION=v1.2.3
HELM_SHA256=$(sha "$SRV/helm/helm-v1.2.3-linux-amd64.tar.gz")
KUBECTL_VERSION=v1.0.0
KUBECTL_SHA256=$(sha "$SRV/k8s/v1.0.0/bin/linux/amd64/kubectl")
SSM_PLUGIN_VERSION=9.9.9
SSM_PLUGIN_SHA256=$(sha "$SRV/ssm/9.9.9/ubuntu_64bit/session-manager-plugin.deb")
PINS
}

@test "installs each pinned tool, checked, and puts the dir on GITHUB_PATH" {
  run "$INSTALL"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_has "helm v1.2.3, kubectl v1.0.0, session-manager-plugin 9.9.9"
  [ -x "$CLUSTER_TOOLS_DIR/helm" ]
  [ -x "$CLUSTER_TOOLS_DIR/kubectl" ]
  [ "$(cat "$GITHUB_PATH")" = "$CLUSTER_TOOLS_DIR" ]
}

@test "FAILING FIXTURE: refuses a kubectl that does not match its pinned sha256" {
  echo "# changed" >> "$SRV/k8s/v1.0.0/bin/linux/amd64/kubectl"
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "kubectl does not match its pinned sha256"
  [ ! -s "$GITHUB_PATH" ]
}

@test "refuses a helm archive that does not match its pinned sha256" {
  printf 'x' >> "$SRV/helm/helm-v1.2.3-linux-amd64.tar.gz"
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "helm-v1.2.3-linux-amd64.tar.gz does not match its pinned sha256"
}

@test "refuses a plugin deb that does not match its pinned sha256" {
  echo "# changed" >> "$SRV/ssm/9.9.9/ubuntu_64bit/session-manager-plugin.deb"
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "session-manager-plugin.deb does not match its pinned sha256"
}

@test "refuses a verified helm that reports another version" {
  make_tools v0.0.1 v1.0.0 9.9.9
  write_pins
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "helm reports 'v0.0.1', the pin is v1.2.3"
}

@test "refuses a verified kubectl that reports another version" {
  make_tools v1.2.3 v0.9.0 9.9.9
  write_pins
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "kubectl does not report v1.0.0"
}

@test "refuses a verified plugin that reports another version" {
  make_tools v1.2.3 v1.0.0 1.0.0
  write_pins
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "session-manager-plugin reports '1.0.0', the pin is 9.9.9"
}

@test "refuses a pin file with a value that is not a sha256" {
  sed -i 's/^KUBECTL_SHA256=.*/KUBECTL_SHA256=latest/' "$CLUSTER_TOOLS_PINS"
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "KUBECTL_SHA256 in"
}

@test "refuses a pin file with a missing pin" {
  sed -i '/^HELM_VERSION=/d' "$CLUSTER_TOOLS_PINS"
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "sets no HELM_VERSION"
}

@test "the committed pins are full: each tool has a version and a sha256" {
  export CLUSTER_TOOLS_PINS="$REPO_ROOT/.github/actions/install-cluster-tools/pins.env"
  run bash -c '. "$CLUSTER_TOOLS_PINS"; for v in HELM KUBECTL SSM_PLUGIN; do
    n="${v}_VERSION"; s="${v}_SHA256"; [ -n "${!n}" ] || exit 1; [[ "${!s}" =~ ^[0-9a-f]{64}$ ]] || exit 1; done'
  [ "$status" -eq 0 ]
}
