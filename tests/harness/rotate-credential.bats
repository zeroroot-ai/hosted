#!/usr/bin/env bats
# rotate-credential.bats — one step of one credential rotation, as the
# workflow .github/workflows/rotate-credentials.yml runs it
# (scripts/rotate-credential.sh, ADR-0083 amendment of 2026-10-21).
#
# Offline. The keyring is the real scripts/keyring.sh. The push to the cluster,
# stage 0, the restart and the access key rotation are stubs that log.
#
# Run:
#   bats tests/harness/rotate-credential.bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  D="$BATS_TEST_TMPDIR"; export D
  STATE="$D/state"; mkdir -p "$STATE"
  "$REPO/scripts/keyring.sh" generate "$STATE/keyring.env" >/dev/null
  printf 'KEYRING_FILE=%s\n' "$STATE/keyring.env" > "$STATE/substrate.env"
  : > "$D/log"
  for n in k2c substrate rotate; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/log"\n' "$n" "$D" > "$D/$n"
    chmod +x "$D/$n"
  done
  printf '#!/bin/sh\necho "substrate-rotate $*" >> "%s/log"\nexit "${ROTATE_RC:-0}"\n' "$D" > "$D/rotate"
  printf 'restart_pods() { echo "restart $1 $2" >> "%s/log"; [ -z "${RESTART_FAIL:-}" ] || return 1; RESTART_PODS_RESULT=restarted; }\n' "$D" > "$D/restart-lib.sh"
  export K2C="$D/k2c" SUBSTRATE_SH="$D/substrate" SUBSTRATE_ROTATE="$D/rotate" RESTART_PODS_LIB="$D/restart-lib.sh"
}

step() { run "$REPO/scripts/rotate-credential.sh" "$STATE" "$@"; }
get() { "$REPO/scripts/keyring.sh" get "$STATE/keyring.env" "$1"; }

@test "an access key goes to substrate-rotate.sh, and its exit code is the exit code of the step" {
  ROTATE_RC=10 step staging platform rotate
  [ "$status" -eq 10 ]
  grep -q "substrate-rotate $STATE staging platform" "$D/log"
}

@test "the seal key rotates, goes to the cluster, restarts OpenBao and refreshes substrate.env, in that order" {
  old="$(get OPENBAO_SEAL_KEY)"
  step prod OPENBAO_SEAL_KEY rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(get OPENBAO_SEAL_KEY_PREVIOUS)" = "$old" ]
  [ "$(awk '{print $1}' "$D/log" | tr '\n' ' ')" = "k2c restart substrate " ]
  grep -q "restart gibson statefulset/gibson-openbao" "$D/log"
}

@test "retire clears the previous seal key" {
  step prod OPENBAO_SEAL_KEY rotate
  step prod OPENBAO_SEAL_KEY retire
  [ "$status" -eq 0 ]
  [ -z "$(get OPENBAO_SEAL_KEY_PREVIOUS)" ]
}

@test "the disk signing seed has no reader to restart" {
  step staging SETEC_DISK_SIGNING_SEED rotate
  [ "$status" -eq 0 ]
  run grep -q restart "$D/log"
  [ "$status" -ne 0 ]
}

@test "FAILING FIXTURE: drill is not rotated by this workflow" {
  step drill OPENBAO_SEAL_KEY rotate
  [ "$status" -eq 2 ]
  [[ "$output" == *"The drill rotates in drill.yml"* ]]
}

@test "FAILING FIXTURE: an access key has no retire step" {
  step staging dns retire
  [ "$status" -eq 2 ]
  [[ "$output" == *"has one step, rotate"* ]]
}

@test "FAILING FIXTURE: a credential that does not rotate in place is refused" {
  step staging BUCKET_ACCESS_KEY rotate
  [ "$status" -eq 2 ]
  [ ! -s "$D/log" ]
}

@test "FAILING FIXTURE: a Velero password rotation with no expected prefix is refused before the keyring changes" {
  before="$(sha256sum < "$STATE/keyring.env")"
  step staging VELERO_REPO_PASSWORD rotate
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs EXPECT_VELERO_PREFIX"* ]]
  [ "$(sha256sum < "$STATE/keyring.env")" = "$before" ]
}

@test "FAILING FIXTURE: a Velero password rotation whose overlay names another prefix is refused" {
  EXPECT_VELERO_PREFIX=backups/velero/repo-nothing step staging VELERO_REPO_PASSWORD rotate
  [ "$status" -eq 2 ]
  [[ "$output" == *"Merge the overlay change first"* ]]
  [ ! -s "$D/log" ]
}

@test "a Velero password rotation whose overlay names the expected prefix goes on" {
  p="$(python3 -c 'import yaml;print(yaml.safe_load(open("'"$REPO"'/gitops/envs/staging/gibson-velero-values.yaml"))["bucket"]["prefix"])')"
  EXPECT_VELERO_PREFIX="$p" step staging VELERO_REPO_PASSWORD rotate
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q "restart velero deployment/velero" "$D/log"
}

@test "the workflow reaches the cluster as the other workflows do, with no kubeconfig secret" {
  wf="$REPO/.github/workflows/rotate-credentials.yml"
  run grep -E '^[^#]*secrets\.KUBECONFIG' "$wf"
  [ "$status" -eq 1 ]
  grep -qE '^[^#]*scripts/with-cluster\.sh staging' "$wf"
  grep -qE '^[^#]*make eks-kubeconfig ENV=prod' "$wf"
}

@test "the marker exists after a failure that comes after the push to the cluster, and the keyring holds the new key" {
  old="$(get OPENBAO_SEAL_KEY)"
  RESTART_FAIL=1 step prod OPENBAO_SEAL_KEY rotate
  [ "$status" -eq 2 ]
  [ -e "$STATE/.cluster-keyring-pushed" ]
  [ "$(get OPENBAO_SEAL_KEY_PREVIOUS)" = "$old" ]
  [ "$(get OPENBAO_SEAL_KEY)" != "$old" ]
}

@test "FAILING FIXTURE: a failure before the push leaves no marker" {
  step staging VELERO_REPO_PASSWORD rotate
  [ "$status" -eq 2 ]
  [ ! -e "$STATE/.cluster-keyring-pushed" ]
}

@test "FAILING FIXTURE: a failed push to the cluster still leaves the marker, because the push may have changed the cluster" {
  printf '#!/bin/sh\nexit 1\n' > "$D/k2c"
  step prod OPENBAO_SEAL_KEY rotate
  [ "$status" -ne 0 ]
  [ -e "$STATE/.cluster-keyring-pushed" ]
}

@test "a marker from an earlier run in the same state directory is removed at the start" {
  : > "$STATE/.cluster-keyring-pushed"
  step staging OPENBAO_SEAL_KEY retire
  [ "$status" -eq 2 ]
  [ ! -e "$STATE/.cluster-keyring-pushed" ]
}
