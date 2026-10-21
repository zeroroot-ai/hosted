#!/usr/bin/env bats
# recover-keyring.bats — scripts/recover-keyring.sh rebuilds the keyring of an
# environment from the cluster Secrets, in the rotate-credentials workflow
# (step recover). It takes the old keyring and substrate.env from the state
# directory, checks each member fingerprint, and leaves the new files and the
# marker for the write-back (ADR-0083 amendment of 2026-10-21).
#
# Offline. The keyring tool is the real scripts/keyring.sh. kubectl and
# with-cluster.sh are stubs on PATH. The "cluster" is the directory
# $D/cluster: one JSON file for each Secret.
#
# Run:
#   bats tests/harness/recover-keyring.bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  D="$BATS_TEST_TMPDIR"; export D
  mkdir -p "$D/bin" "$D/cluster"
  S="$D/state"; mkdir -p "$S"
  K="$D/keyring.env"
  "$REPO/scripts/keyring.sh" generate "$K" >/dev/null
  "$REPO/scripts/keyring.sh" set "$K" GITHUB_APP_PRIVATE_KEY "$(printf -- '-----BEGIN KEY-----\nabc\n-----END KEY-----' | base64 -w0)" >/dev/null
  # substrate.env of the environment: the fingerprints of this keyring.
  { printf 'SUBSTRATE_ENV=staging\nKEYRING_FILE=/old/path/keyring.env\nBUCKET_NAME=b\n'; "$REPO/scripts/keyring.sh" fingerprints "$K"; } > "$S/substrate.env"
  cp "$K" "$S/keyring.env"
  g() { "$REPO/scripts/keyring.sh" get "$K" "$1"; }
  b64() { printf '%s' "$1" | base64 -w0; }
  secret() { # <ns> <name> <annotations-json> then key=value pairs
    local ns="$1" name="$2" ann="$3"; shift 3
    local data="{}" kv
    for kv in "$@"; do data="$(jq -c --arg k "${kv%%=*}" --arg v "$(b64 "${kv#*=}")" '. + {($k): $v}' <<<"$data")"; done
    jq -n --argjson d "$data" --argjson a "$ann" '{data: $d, metadata: {annotations: $a}}' > "$D/cluster/$ns.$name.json"
  }
  secret gibson bringup-keyring '{"keyring.zeroroot.ai/set-at.ghcr-pull-token":"1700000000"}' \
    "openbao-seal-key=$(g OPENBAO_SEAL_KEY)" "openbao-seal-previous-key=" \
    "bucket-access-key=$(g BUCKET_ACCESS_KEY)" "bucket-secret-key=$(g BUCKET_SECRET_KEY)" \
    "smtp-password=$(g SMTP_PASSWORD)" "setec-disk-signing-seed=$(g SETEC_DISK_SIGNING_SEED)" \
    "ghcr-pull-token=" "stripe-secret-key=" "stripe-publishable-key=" "stripe-webhook-secret="
  secret velero velero-repo-credentials '{}' "repository-password=$(g VELERO_REPO_PASSWORD)"
  secret gibson route53-credential '{}' "access-key-id=" "secret-access-key="
  secret gibson setec-disk-push-credential '{}' "access-key-id=" "secret-access-key="
  secret argocd zeroroot-ai-creds '{}' "githubAppPrivateKey=$(printf -- '-----BEGIN KEY-----\nabc\n-----END KEY-----')"

  cat > "$D/bin/kubectl" <<'SH'
#!/usr/bin/env bash
# Answers only: kubectl -n <ns> get secret <name> -o json
case "$*" in
  "-n "*" get secret "*" -o json")
    f="$D/cluster/$2.$5.json"
    [ -f "$f" ] || { echo "Error from server (NotFound)" >&2; exit 1; }
    cat "$f" ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$D/bin/with-cluster"
  chmod +x "$D/bin/"*
  export PATH="$D/bin:$PATH" WITH_CLUSTER="$D/bin/with-cluster"
}

recover() { run "$REPO/scripts/recover-keyring.sh" "$1" "$S" "${@:2}"; }
sget() { "$REPO/scripts/keyring.sh" get "$S/keyring.env" "$1"; }

@test "the keyring is rebuilt from the cluster and the old keyring, the marker is set, and the new files verify" {
  recover staging
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -e "$S/.cluster-keyring-pushed" ]
  for m in OPENBAO_SEAL_KEY VELERO_REPO_PASSWORD BUCKET_SECRET_KEY SETEC_DISK_SIGNING_SEED GITHUB_APP_PRIVATE_KEY; do
    [ "$(sget "$m")" = "$(g "$m")" ] || { echo "$m differs"; false; }
  done
  run "$REPO/scripts/keyring.sh" verify "$S/keyring.env" "$S/substrate.env"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the set time of a vendor value comes back from the annotation" {
  recover staging
  [ "$status" -eq 0 ]
  [ "$(sget KEYRING_SET_AT_GHCR_PULL_TOKEN)" = 1700000000 ]
}

@test "OPEN ROTATION: the previous Velero password is the old current value, and the change of the current value is accepted once" {
  old="$(g VELERO_REPO_PASSWORD)"; new="$(head -c 32 /dev/urandom | base64 -w0)"
  secret velero velero-repo-credentials '{}' "repository-password=$new"
  recover staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"VELERO_REPO_PASSWORD"* ]]
  # The previous member follows its current member: no rerun with it, and the
  # text says that --accept-changed on it erases the old value.
  [[ "$output" == *"--accept-changed VELERO_REPO_PASSWORD"* ]]
  [[ "$output" != *"--accept-changed VELERO_REPO_PASSWORD_PREVIOUS"* ]]
  [[ "$output" == *"erases the old value"* ]]
  [ "$(sget VELERO_REPO_PASSWORD)" = "$old" ]
  recover staging --accept-changed VELERO_REPO_PASSWORD
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sget VELERO_REPO_PASSWORD)" = "$new" ]
  [ "$(sget VELERO_REPO_PASSWORD_PREVIOUS)" = "$old" ]
  run "$REPO/scripts/keyring.sh" verify "$S/keyring.env" "$S/substrate.env"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: --accept-changed on a previous member is refused, because it would erase the old value" {
  new="$(head -c 32 /dev/urandom | base64 -w0)"
  secret velero velero-repo-credentials '{}' "repository-password=$new"
  recover staging --accept-changed VELERO_REPO_PASSWORD --accept-changed VELERO_REPO_PASSWORD_PREVIOUS
  [ "$status" -eq 2 ]
  [[ "$output" == *"--accept-changed on VELERO_REPO_PASSWORD_PREVIOUS is refused"* ]]
  [ ! -e "$S/.cluster-keyring-pushed" ]
}

@test "FAILING FIXTURE: --empty on a previous member with a non-empty old value is refused" {
  # Both agree, and the old keyring holds a previous value.
  "$REPO/scripts/keyring.sh" rotate "$S/keyring.env" SETEC_DISK_SIGNING_SEED >/dev/null
  old_prev="$(sget SETEC_DISK_SIGNING_SEED_PREVIOUS)"
  [ -n "$old_prev" ]
  secret gibson bringup-keyring '{}' "openbao-seal-key=$(g OPENBAO_SEAL_KEY)" "openbao-seal-previous-key=" \
    "bucket-access-key=$(g BUCKET_ACCESS_KEY)" "bucket-secret-key=$(g BUCKET_SECRET_KEY)" "smtp-password=$(g SMTP_PASSWORD)" \
    "setec-disk-signing-seed=$(sget SETEC_DISK_SIGNING_SEED)" "ghcr-pull-token=" "stripe-secret-key=" "stripe-publishable-key=" "stripe-webhook-secret="
  recover staging --empty SETEC_DISK_SIGNING_SEED_PREVIOUS
  [ "$status" -eq 2 ]
  [[ "$output" == *"SETEC_DISK_SIGNING_SEED_PREVIOUS"* ]]
  [[ "$output" == *"would erase the non-empty old value"* ]]
}

@test "when both agree, a non-empty old previous value is kept with no flag" {
  "$REPO/scripts/keyring.sh" rotate "$S/keyring.env" VELERO_REPO_PASSWORD >/dev/null
  cur="$(sget VELERO_REPO_PASSWORD)"; prev="$(sget VELERO_REPO_PASSWORD_PREVIOUS)"
  # The old substrate.env records this keyring, and the cluster holds its current value.
  { printf 'SUBSTRATE_ENV=staging\nKEYRING_FILE=x\n'; "$REPO/scripts/keyring.sh" fingerprints "$S/keyring.env"; } > "$S/substrate.env"
  secret velero velero-repo-credentials '{}' "repository-password=$cur"
  recover staging
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sget VELERO_REPO_PASSWORD_PREVIOUS)" = "$prev" ]
}

@test "FAILING FIXTURE: --empty with an open rotation is refused, because the old current value is needed" {
  new="$(head -c 32 /dev/urandom | base64 -w0)"
  secret velero velero-repo-credentials '{}' "repository-password=$new"
  recover staging --accept-changed VELERO_REPO_PASSWORD --empty VELERO_REPO_PASSWORD_PREVIOUS
  [ "$status" -eq 2 ]
  [[ "$output" == *"--empty would erase the old value"* ]]
}

@test "FAILING FIXTURE: a Secret that is missing stops the command by member, and nothing is changed" {
  rm "$D/cluster/gibson.route53-credential.json"
  before="$(sha256sum < "$S/keyring.env")"
  recover staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"DNS_ACCESS_KEY (the Secret gibson/route53-credential does not exist)"* ]]
  [[ "$output" == *"DNS_SECRET_KEY"* ]]
  [ "$(sha256sum < "$S/keyring.env")" = "$before" ]
  [ ! -e "$S/.cluster-keyring-pushed" ]
}

@test "FAILING FIXTURE: a required member with no value stops the command by name" {
  secret gibson bringup-keyring '{}' "openbao-seal-key=" "openbao-seal-previous-key=" \
    "bucket-access-key=$(g BUCKET_ACCESS_KEY)" "bucket-secret-key=$(g BUCKET_SECRET_KEY)" "smtp-password=$(g SMTP_PASSWORD)" \
    "setec-disk-signing-seed=$(g SETEC_DISK_SIGNING_SEED)" "ghcr-pull-token=" "stripe-secret-key=" "stripe-publishable-key=" "stripe-webhook-secret="
  recover staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"OPENBAO_SEAL_KEY"* ]]
  [ ! -e "$S/.cluster-keyring-pushed" ]
}

@test "FAILING FIXTURE: a member that differs from substrate.env stops the command, names it, and prints the rerun" {
  new="$(head -c 32 /dev/urandom | base64 -w0)"
  secret gibson bringup-keyring '{}' "openbao-seal-key=$new" "openbao-seal-previous-key=$(g OPENBAO_SEAL_KEY)" \
    "bucket-access-key=$(g BUCKET_ACCESS_KEY)" "bucket-secret-key=$(g BUCKET_SECRET_KEY)" "smtp-password=$(g SMTP_PASSWORD)" \
    "setec-disk-signing-seed=$(g SETEC_DISK_SIGNING_SEED)" "ghcr-pull-token=" "stripe-secret-key=" "stripe-publishable-key=" "stripe-webhook-secret="
  recover staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"--accept-changed OPENBAO_SEAL_KEY --accept-changed OPENBAO_SEAL_KEY_PREVIOUS"* ]]
  [ ! -e "$S/.cluster-keyring-pushed" ]
  recover staging --accept-changed OPENBAO_SEAL_KEY --accept-changed OPENBAO_SEAL_KEY_PREVIOUS
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(sget OPENBAO_SEAL_KEY)" = "$new" ]
  [ "$(sget OPENBAO_SEAL_KEY_PREVIOUS)" = "$(g OPENBAO_SEAL_KEY)" ]
  run "$REPO/scripts/keyring.sh" verify "$S/keyring.env" "$S/substrate.env"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: an environment that is not staging or prod is refused" {
  recover drill
  [ "$status" -eq 2 ]
  [ ! -e "$S/.cluster-keyring-pushed" ]
}

@test "every member of keyring.sh is rebuilt from the cluster or taken from the old keyring" {
  members="$(sed -n '/^MEMBERS=(/,/^)/p' "$REPO/scripts/keyring.sh" | grep -oE '^  [A-Z_]+' | tr -d ' ')"
  for m in $members; do
    grep -qE "\"$m\\|" "$REPO/scripts/recover-keyring.sh" || grep -qE "^NOT_IN_CLUSTER=.*\\b$m\\b" "$REPO/scripts/recover-keyring.sh" \
      || { echo "$m is neither rebuilt nor named as not stored"; false; }
  done
}

@test "the recovery has one entry point: the workflow mode, with no gh login path and no here-string for the Secret JSON" {
  wf="$REPO/.github/workflows/rotate-credentials.yml"
  grep -q 'options: \[rotate, retire, recover\]' "$wf"
  grep -q 'scripts/recover-keyring.sh' "$wf"
  run grep -nE '\bgh\b|\$GH|WRITEBACK' "$REPO/scripts/recover-keyring.sh"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  run grep -n '<<<"\$json"' "$REPO/scripts/recover-keyring.sh"
  [ "$status" -ne 0 ] || { echo "$output"; false; }
  grep -q 'step recover' "$REPO/substrate/gibson-bootstrap/README.md"
}

@test "the write-back writes a file only when it differs from the copy that was read" {
  W="$D/wstate"; mkdir -p "$W" "$D/gh"; cp "$K" "$W/keyring.env"; cp "$S/substrate.env" "$W/substrate.env"
  cat > "$D/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "secret set")   cat > "$D/gh/secret.$3" ;;
  "variable set") cat > "$D/gh/variable.$3" ;;
  *) echo "gh stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$D/bin/gh"
  sha256sum < "$W/keyring.env" | cut -d' ' -f1 > "$W/.read-keyring.sha256"
  sha256sum < "$W/substrate.env" | cut -d' ' -f1 > "$W/.read-substrate.sha256"
  GH="$D/bin/gh" run "$REPO/scripts/keyring-writeback.sh" "$W" staging
  [ "$status" -eq 0 ]
  [ ! -e "$D/gh/secret.BRINGUP_KEYRING" ]
  echo "KEYRING_SET_AT_X=1" >> "$W/keyring.env"
  GH="$D/bin/gh" run "$REPO/scripts/keyring-writeback.sh" "$W" staging
  [ "$status" -eq 0 ]
  [ -s "$D/gh/secret.BRINGUP_KEYRING" ]
  [ ! -e "$D/gh/variable.SUBSTRATE_ENV_FILE" ]
}
