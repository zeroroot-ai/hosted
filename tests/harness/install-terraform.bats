#!/usr/bin/env bats
#
# install-terraform.bats — the one Terraform installer fails closed.
#
# .github/actions/install-terraform/install.sh downloads the pinned release
# and its SHA256SUMS, verifies the zip against the SHA256SUMS line, and proves
# the binary reports the pin. Blocker 1 went red on one ECONNRESET from
# hashicorp/setup-terraform (run 35563392735), so the installer retries. A
# retry that then accepts a truncated or swapped zip would be worse than the
# reset, so this suite plants each miss and proves the installer refuses it.
#
# The release server is a file:// tree under $BATS_TEST_TMPDIR. No network.
#
# Run:
#   bats tests/harness/install-terraform.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
load assert

setup() {
  INSTALL="$REPO_ROOT/.github/actions/install-terraform/install.sh"
  VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/.terraform-version")"
  RELEASES="$BATS_TEST_TMPDIR/releases"
  DIR="$RELEASES/terraform/$VERSION"
  ZIP="terraform_${VERSION}_linux_amd64.zip"
  SUMS="terraform_${VERSION}_SHA256SUMS"
  mkdir -p "$DIR"
  export TERRAFORM_RELEASES_URL="file://$RELEASES"
  export TERRAFORM_INSTALL_DIR="$BATS_TEST_TMPDIR/bin"
  export GITHUB_PATH="$BATS_TEST_TMPDIR/github-path"
  : > "$GITHUB_PATH"
  make_release "$VERSION"
}

# make_release <reported version>: a zip whose `terraform` prints that
# version, and a SHA256SUMS that names the zip, the way the server does.
make_release() {
  local build="$BATS_TEST_TMPDIR/build"
  rm -rf "$build"; mkdir -p "$build"
  printf '#!/usr/bin/env bash\necho "Terraform v%s"\necho "on linux_amd64"\n' "$1" > "$build/terraform"
  chmod +x "$build/terraform"
  ( cd "$build" && zip -q "$DIR/$ZIP" terraform )
  ( cd "$DIR" && sha256sum "$ZIP" > "$SUMS" )
}

@test "installs the pinned version from a verified zip and puts it on GITHUB_PATH" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  assert_output_has "install-terraform: Terraform v${VERSION}, verified against ${SUMS}"
  [ -x "$TERRAFORM_INSTALL_DIR/terraform" ]
  [ "$(cat "$GITHUB_PATH")" = "$TERRAFORM_INSTALL_DIR" ]
}

@test "refuses a corrupted zip: the checksum does not match" {
  printf '\xff\xff\xff\xff' | dd of="$DIR/$ZIP" bs=1 seek=40 conv=notrunc status=none
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "${ZIP} does not match its SHA256SUMS line"
  [ ! -e "$TERRAFORM_INSTALL_DIR/terraform" ]
  [ ! -s "$GITHUB_PATH" ]
}

@test "refuses when SHA256SUMS has no line for the zip" {
  ( cd "$DIR" && sha256sum "$ZIP" | sed "s/$ZIP/terraform_${VERSION}_linux_arm64.zip/" > "$SUMS" )
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "${SUMS} has no line for ${ZIP}"
  [ ! -e "$TERRAFORM_INSTALL_DIR/terraform" ]
}

@test "refuses an empty SHA256SUMS" {
  : > "$DIR/$SUMS"
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "${SUMS} has no line for ${ZIP}"
}

@test "refuses a verified zip whose binary reports another version" {
  make_release "0.0.1"
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "installed binary reports 'Terraform v0.0.1', pin is v${VERSION}"
  [ ! -s "$GITHUB_PATH" ]
}

@test "refuses a verified zip that holds no terraform binary" {
  local build="$BATS_TEST_TMPDIR/build2"
  mkdir -p "$build"; echo hi > "$build/README"
  rm -f "$DIR/$ZIP"
  ( cd "$build" && zip -q "$DIR/$ZIP" README )
  ( cd "$DIR" && sha256sum "$ZIP" > "$SUMS" )
  run "$INSTALL"
  [ "$status" -eq 1 ]
  assert_output_has "${ZIP} holds no terraform binary"
}

# FAILING FIXTURE for run 36380539803. A binary that pauses before its second
# line of `version` output is still a correct binary. Read through
# `| head -n1` under pipefail, head exits first and the binary dies of
# SIGPIPE on that second write, so the installer called it "does not run".
@test "accepts a correct binary that writes more output after its first line" {
  local build="$BATS_TEST_TMPDIR/build"
  rm -rf "$build" "$DIR/$ZIP"; mkdir -p "$build"
  printf '#!/usr/bin/env bash\necho "Terraform v%s"\nsleep 0.3\nfor i in $(seq 1 2000); do echo "line $i of a long update notice"; done\n' "$VERSION" > "$build/terraform"
  chmod +x "$build/terraform"
  ( cd "$build" && zip -q "$DIR/$ZIP" terraform )
  ( cd "$DIR" && sha256sum "$ZIP" > "$SUMS" )
  run "$INSTALL"
  [ "$status" -eq 0 ]
  assert_output_has "install-terraform: Terraform v${VERSION}, verified against ${SUMS}"
}
