#!/usr/bin/env bats
#
# apex-zone-id.bats — the live apex zone id is read, never stored.
#
# substrate/apex-zone requires apex_zone_id with no default (#111). The
# exit test and `make apex-zone-plan` both get it from
# scripts/apex-zone-id.sh, which asks Route53. The stub below is an aws CLI
# that answers what the account holds.
#
# Run:
#   bats tests/harness/apex-zone-id.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR" "$STATE"
  PATH="$STUB_DIR:$PATH"
  export STATE
  cat > "$STUB_DIR/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"list-hosted-zones-by-name"*) cat "$STATE/answer"; exit 0 ;;
  *"get-caller-identity"*) echo "arn:aws:sts::000000000000:assumed-role/eks-plan-readonly/test"; exit 0 ;;
  *) echo "unexpected aws call: $*" >&2; exit 99 ;;
esac
SH
  chmod +x "$STUB_DIR/aws"
}

@test "prints the bare zone id when the account holds the zone" {
  echo "/hostedzone/Z0TESTZONE12345" > "$STATE/answer"
  run "$REPO_ROOT/scripts/apex-zone-id.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "Z0TESTZONE12345" ]
}

@test "fails and names the caller when no zone by that name is visible" {
  echo "None" > "$STATE/answer"
  run "$REPO_ROOT/scripts/apex-zone-id.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no hosted zone named zeroroot.ai. is visible to arn:aws:sts::000000000000:assumed-role/eks-plan-readonly/test"* ]]
}

@test "fails on an empty answer too" {
  : > "$STATE/answer"
  run "$REPO_ROOT/scripts/apex-zone-id.sh"
  [ "$status" -eq 1 ]
}
