#!/usr/bin/env bats
# keyring-rotation.bats — the seal key rotates in place (ADR-0171, row
# keyring-generated-keys): rotate keeps the old key as the previous member,
# a second rotate is refused until retire, and retire clears it.
#
# Run:
#   bats tests/harness/keyring-rotation.bats

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  export GITHUB_ACTIONS=true
  K="$BATS_TEST_TMPDIR/keyring.env"
  "$ROOT/scripts/keyring.sh" generate "$K" >/dev/null
}

get() { "$ROOT/scripts/keyring.sh" get "$K" "$1"; }

@test "a new keyring has an empty previous seal key and passes its shape" {
  [ -z "$(get OPENBAO_SEAL_KEY_PREVIOUS)" ]
  run "$ROOT/scripts/keyring.sh" fingerprints "$K"
  [ "$status" -eq 0 ]
  [[ "$output" == *KEYRING_FINGERPRINT_OPENBAO_SEAL_KEY_PREVIOUS=* ]]
}

@test "rotate keeps the old seal key as the previous one and writes a new key" {
  old="$(get OPENBAO_SEAL_KEY)"
  run "$ROOT/scripts/keyring.sh" rotate "$K" OPENBAO_SEAL_KEY
  [ "$status" -eq 0 ]
  [ "$(get OPENBAO_SEAL_KEY_PREVIOUS)" = "$old" ]
  new="$(get OPENBAO_SEAL_KEY)"
  [ "$new" != "$old" ]
  [ "$(printf '%s' "$new" | base64 -d | wc -c)" -eq 32 ]
  [ "$(stat -c %a "$K")" = 600 ]
  run "$ROOT/scripts/keyring.sh" fingerprints "$K"
  [ "$status" -eq 0 ]
}

@test "FAILING FIXTURE: a second rotate before retire is refused, and the keyring does not change" {
  "$ROOT/scripts/keyring.sh" rotate "$K" OPENBAO_SEAL_KEY >/dev/null
  before="$(sha256sum < "$K")"
  run "$ROOT/scripts/keyring.sh" rotate "$K" OPENBAO_SEAL_KEY
  [ "$status" -eq 2 ]
  [[ "$output" == *"retire first"* ]]
  [ "$(sha256sum < "$K")" = "$before" ]
}

@test "retire clears the previous seal key, and then a rotate runs again" {
  "$ROOT/scripts/keyring.sh" rotate "$K" OPENBAO_SEAL_KEY >/dev/null
  cur="$(get OPENBAO_SEAL_KEY)"
  run "$ROOT/scripts/keyring.sh" retire "$K" OPENBAO_SEAL_KEY
  [ "$status" -eq 0 ]
  [ -z "$(get OPENBAO_SEAL_KEY_PREVIOUS)" ]
  [ "$(get OPENBAO_SEAL_KEY)" = "$cur" ]
  run "$ROOT/scripts/keyring.sh" rotate "$K" OPENBAO_SEAL_KEY
  [ "$status" -eq 0 ]
}

@test "FAILING FIXTURE: a member with no previous member does not rotate in place" {
  run "$ROOT/scripts/keyring.sh" rotate "$K" BUCKET_ACCESS_KEY
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not rotate in place"* ]]
}

@test "the Velero repository password rotates and keeps the old password for the old repository" {
  old="$(get VELERO_REPO_PASSWORD)"
  run "$ROOT/scripts/keyring.sh" rotate "$K" VELERO_REPO_PASSWORD
  [ "$status" -eq 0 ]
  [ "$(get VELERO_REPO_PASSWORD_PREVIOUS)" = "$old" ]
  [ "$(get VELERO_REPO_PASSWORD)" != "$old" ]
  [ -z "$(get OPENBAO_SEAL_KEY_PREVIOUS)" ]
}

# The setec disk signing seed rotates in place (ADR-0171, row
# setec-disk-signing-seed, hosted#555). disk-public-keys prints the keys each
# launcher must accept: the seed, then the previous seed while one is kept.
@test "the disk seed rotates, and disk-public-keys prints the new key and then the previous key" {
  old_key="$("$ROOT/scripts/keyring.sh" disk-public-key "$K")"
  run "$ROOT/scripts/keyring.sh" disk-public-keys "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "$old_key" ]
  run "$ROOT/scripts/keyring.sh" rotate "$K" SETEC_DISK_SIGNING_SEED
  [ "$status" -eq 0 ]
  new_key="$("$ROOT/scripts/keyring.sh" disk-public-key "$K")"
  [ "$new_key" != "$old_key" ]
  run "$ROOT/scripts/keyring.sh" disk-public-keys "$K"
  [ "$status" -eq 0 ]
  [ "$output" = "$new_key"$'\n'"$old_key" ]
  run "$ROOT/scripts/keyring.sh" fingerprints "$K"
  [ "$status" -eq 0 ]
  [[ "$output" == *KEYRING_FINGERPRINT_SETEC_DISK_SIGNING_SEED_PREVIOUS=* ]]
}

@test "FAILING FIXTURE: a second disk seed rotate before retire is refused, and retire leaves the new key alone" {
  "$ROOT/scripts/keyring.sh" rotate "$K" SETEC_DISK_SIGNING_SEED >/dev/null
  run "$ROOT/scripts/keyring.sh" rotate "$K" SETEC_DISK_SIGNING_SEED
  [ "$status" -eq 2 ]
  [[ "$output" == *"retire first"* ]]
  new_key="$("$ROOT/scripts/keyring.sh" disk-public-key "$K")"
  run "$ROOT/scripts/keyring.sh" retire "$K" SETEC_DISK_SIGNING_SEED
  [ "$status" -eq 0 ]
  run "$ROOT/scripts/keyring.sh" disk-public-keys "$K"
  [ "$output" = "$new_key" ]
}

@test "FAILING FIXTURE: rotate and retire refuse to run outside a workflow, and change nothing" {
  before="$(sha256sum < "$K")"
  GITHUB_ACTIONS="" run "$ROOT/scripts/keyring.sh" rotate "$K" OPENBAO_SEAL_KEY
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs in a GitHub Actions workflow only"* ]]
  GITHUB_ACTIONS="" run "$ROOT/scripts/keyring.sh" retire "$K" OPENBAO_SEAL_KEY
  [ "$status" -ne 0 ]
  [[ "$output" == *"runs in a GitHub Actions workflow only"* ]]
  [ "$(sha256sum < "$K")" = "$before" ]
}
