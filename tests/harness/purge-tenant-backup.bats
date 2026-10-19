#!/usr/bin/env bats
#
# purge-tenant-backup.bats: the purge verb fails closed, and it passes the
# tenant to the charts script unchanged (ADR-0075, hosted#439).
#
# The refusals about the backup itself live in the charts script
# (charts#419) and in its own bats test. This file proves only what the verb
# adds: ENV, the tenant, and the cluster access of the environment.
#
# Offline. A stub charts root records the arguments of the script. Each
# assertion uses `run` and `$status`.
#
# Run:
#   bats tests/harness/purge-tenant-backup.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  FAKE_CHARTS="$BATS_TEST_TMPDIR/charts"
  RECORD="$BATS_TEST_TMPDIR/record"
  mkdir -p "$FAKE_CHARTS/helm/gibson" "$FAKE_CHARTS/scripts"
  cat > "$FAKE_CHARTS/scripts/purge-tenant-backup.sh" <<SH
#!/usr/bin/env bash
{
  printf 'argc=%s\n' "\$#"
  for a in "\$@"; do printf 'arg=%s\n' "\$a"; done
  printf 'uid=%s\n' "\${TENANT_UID:-}"
  printf 'kubectl=%s\n' "\${KUBECTL:-}"
} > "$RECORD"
SH
  chmod +x "$FAKE_CHARTS/scripts/purge-tenant-backup.sh"
}

purge() { make -s -C "$REPO_ROOT" --no-print-directory purge-tenant-backup CHARTS_ROOT="$FAKE_CHARTS" "$@"; }

@test "FAILING FIXTURE: a run with no ENV is refused, and the script never runs" {
  run purge TENANT=acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENV is required"* ]]
  [ ! -e "$RECORD" ]
}

@test "a run with no TENANT is refused, and the script never runs" {
  run purge ENV=kind
  [ "$status" -ne 0 ]
  [[ "$output" == *"TENANT is required"* ]]
  [ ! -e "$RECORD" ]
}

@test "an empty TENANT is refused, and the script never runs" {
  run purge ENV=kind TENANT=
  [ "$status" -ne 0 ]
  [[ "$output" == *"TENANT is required"* ]]
  [ ! -e "$RECORD" ]
}

@test "an ENV with no row is refused, and the script never runs" {
  run purge ENV=nowhere TENANT=acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENV=nowhere has no cluster access"* ]]
  [ ! -e "$RECORD" ]
}

@test "the tenant and TENANT_UID reach the script unchanged, as one argument" {
  run purge ENV=kind TENANT=acme-prod TENANT_UID=0b1c-uid
  [ "$status" -eq 0 ]
  run cat "$RECORD"
  [ "${lines[0]}" = "argc=1" ]
  [ "${lines[1]}" = "arg=acme-prod" ]
  [ "${lines[2]}" = "uid=0b1c-uid" ]
}

@test "a tenant with a space or a quote is passed as is, so the script refuses it" {
  run purge ENV=kind "TENANT=a b'c"
  [ "$status" -eq 0 ]
  run cat "$RECORD"
  [ "${lines[0]}" = "argc=1" ]
  [ "${lines[1]}" = "arg=a b'c" ]
}

@test "kind uses the kube context of the local cluster" {
  run purge ENV=kind TENANT=acme CLUSTER=gibson
  [ "$status" -eq 0 ]
  run grep -x 'kubectl=kubectl --context kind-gibson' "$RECORD"
  [ "$status" -eq 0 ]
}

@test "staging and drill reach the cluster through with-cluster.sh, and prod through the EKS kubeconfig" {
  run make -s -C "$REPO_ROOT" --no-print-directory -n purge-tenant-backup \
    CHARTS_ROOT="$FAKE_CHARTS" ENV=staging TENANT=acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/with-cluster.sh staging \"$FAKE_CHARTS/scripts/purge-tenant-backup.sh\" \"\$TENANT\""* ]]
  run make -s -C "$REPO_ROOT" --no-print-directory -n purge-tenant-backup \
    CHARTS_ROOT="$FAKE_CHARTS" ENV=drill TENANT=acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/with-cluster.sh drill \"$FAKE_CHARTS/scripts/purge-tenant-backup.sh\" \"\$TENANT\""* ]]
  run make -s -C "$REPO_ROOT" --no-print-directory -n purge-tenant-backup \
    CHARTS_ROOT="$FAKE_CHARTS" ENV=prod TENANT=acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"eks-kubeconfig ENV=prod"* ]]
  [[ "$output" == *"env KUBECONFIG=/tmp/eks-prod.kubeconfig \"$FAKE_CHARTS/scripts/purge-tenant-backup.sh\" \"\$TENANT\""* ]]
}

@test "the verb holds no delete logic of its own" {
  run sed -n '/^purge-tenant-backup:/,/^$/p' "$REPO_ROOT/Makefile"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DeleteBackupRequest"* ]]
  [[ "$output" != *"velero"* ]]
}
