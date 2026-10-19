#!/usr/bin/env bats
#
# velero-prefix.bats — the EC2 and EKS recreate read the Velero prefix from
# the env overlay, the file Argo renders the Velero release from (hosted#593).
#
# A new VELERO_REPO_PASSWORD starts a new kopia repository at a new prefix
# (scripts/keyring.sh, ROTATION). When the recreate held its own constant, a
# restore looked in the old prefix after that change and found no backup.
#
# Offline. Run:
#   bats tests/harness/velero-prefix.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/velero-restore.sh"

setup() {
  # shellcheck source=../../scripts/lib/velero-restore.sh
  . "$LIB"
  F="$BATS_TEST_TMPDIR/gibson-velero-values.yaml"
}

@test "an overlay with no bucket.prefix gets the chart default" {
  printf 'bucket:\n  name: "fx-durable"\n' > "$F"
  run velero_overlay_prefix "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "backups/velero" ]
}

@test "an overlay prefix under backups/velero/ is the prefix" {
  printf 'bucket:\n  name: "fx-durable"\n  prefix: "backups/velero/repo-20261011/"\n' > "$F"
  run velero_overlay_prefix "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "backups/velero/repo-20261011" ]
}

@test "a prefix outside backups/velero/ fails, because the platform credential cannot delete there" {
  printf 'bucket:\n  name: "fx-durable"\n  prefix: "backups/velero2"\n' > "$F"
  run velero_overlay_prefix "$F"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be backups/velero or a path under it"* ]]
}

@test "a missing overlay fails" {
  run velero_overlay_prefix "$BATS_TEST_TMPDIR/absent.yaml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no overlay"* ]]
}

@test "the chart default here is helm/gibson-velero's own bucket.prefix in the kind recreate" {
  script="$(grep -oE 'VELERO_BUCKET_PREFIX:-[^}]+' "$REPO_ROOT/scripts/recreate-kind.sh" | head -n1 | cut -d: -f2- | tr -d '-')"
  [ "$VELERO_CHART_PREFIX" = "$script" ]
}

@test "every cloud overlay gives a prefix the recreate accepts" {
  for f in "$REPO_ROOT"/gitops/envs/*/gibson-velero-values.yaml; do
    run velero_overlay_prefix "$f"
    [ "$status" -eq 0 ] || { echo "$f: $output"; false; }
  done
}

@test "neither cloud recreate holds its own Velero prefix" {
  run grep -n 'VELERO_BUCKET_PREFIX=' "$REPO_ROOT/scripts/recreate-ec2.sh" "$REPO_ROOT/scripts/recreate-aws.sh"
  [ "$status" -eq 1 ]
}
