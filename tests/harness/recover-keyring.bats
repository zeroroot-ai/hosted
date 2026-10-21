#!/usr/bin/env bats
# recover-keyring.bats — scripts/recover-keyring.sh rebuilds the keyring of an
# environment from the cluster Secrets, checks each member fingerprint, and
# writes it with scripts/keyring-writeback.sh (ADR-0083 amendment of
# 2026-10-21).
#
# Offline. The keyring tool is the real scripts/keyring.sh. kubectl, gh and
# with-cluster.sh are stubs on PATH. The "cluster" is the directory $D/cluster:
# one JSON file for each Secret.
#
# Run:
#   bats tests/harness/recover-keyring.bats

REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
EMPTIES=(--empty VELERO_REPO_PASSWORD_PREVIOUS --empty SETEC_DISK_SIGNING_SEED_PREVIOUS)

setup() {
  D="$BATS_TEST_TMPDIR"; export D
  mkdir -p "$D/bin" "$D/cluster" "$D/gh"
  K="$D/keyring.env"
  "$REPO/scripts/keyring.sh" generate "$K" >/dev/null
  "$REPO/scripts/keyring.sh" set "$K" GITHUB_APP_PRIVATE_KEY "$(printf -- '-----BEGIN KEY-----\nabc\n-----END KEY-----' | base64 -w0)" >/dev/null
  # substrate.env of the environment: the fingerprints of this keyring.
  { printf 'SUBSTRATE_ENV=staging\nKEYRING_FILE=/old/path/keyring.env\nBUCKET_NAME=b\n'; "$REPO/scripts/keyring.sh" fingerprints "$K"; } > "$D/substrate.env.var"
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
# kubectl -n <ns> get secret <name> -o json
[ "$1" = -n ] && [ "$3" = get ] && [ "$4" = secret ] || { echo "kubectl stub: undeclared call: $*" >&2; exit 1; }
f="$D/cluster/$2.$5.json"
[ -f "$f" ] || { echo "Error from server (NotFound)" >&2; exit 1; }
cat "$f"
SH
  cat > "$D/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "variable get") cat "$D/substrate.env.var" ;;
  "secret set")   cat > "$D/gh/secret.$3" ;;
  "variable set") cat > "$D/gh/variable.$3" ;;
  *) echo "gh stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$D/bin/with-cluster"
  chmod +x "$D/bin/"*
  export PATH="$D/bin:$PATH" WITH_CLUSTER="$D/bin/with-cluster" GH="$D/bin/gh"
}

recover() { run "$REPO/scripts/recover-keyring.sh" "$@"; }

@test "the keyring is rebuilt from the cluster, written, and each member matches" {
  recover staging "${EMPTIES[@]}"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$D/gh/secret.BRINGUP_KEYRING" ]
  [ -s "$D/gh/variable.SUBSTRATE_ENV_FILE" ]
  for m in OPENBAO_SEAL_KEY VELERO_REPO_PASSWORD BUCKET_SECRET_KEY SETEC_DISK_SIGNING_SEED GITHUB_APP_PRIVATE_KEY; do
    [ "$("$REPO/scripts/keyring.sh" get "$D/gh/secret.BRINGUP_KEYRING" "$m")" = "$(g "$m")" ] || { echo "$m differs"; false; }
  done
  # The written substrate.env verifies against the written keyring.
  run "$REPO/scripts/keyring.sh" verify "$D/gh/secret.BRINGUP_KEYRING" "$D/gh/variable.SUBSTRATE_ENV_FILE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "the set time of a vendor value comes back from the annotation" {
  recover staging "${EMPTIES[@]}"
  [ "$status" -eq 0 ]
  [ "$("$REPO/scripts/keyring.sh" get "$D/gh/secret.BRINGUP_KEYRING" KEYRING_SET_AT_GHCR_PULL_TOKEN)" = 1700000000 ]
}

@test "FAILING FIXTURE: the members the cluster does not store stop the command by name, and nothing is written" {
  recover staging
  [ "$status" -eq 2 ]
  [[ "$output" == *"VELERO_REPO_PASSWORD_PREVIOUS"* ]]
  [[ "$output" == *"SETEC_DISK_SIGNING_SEED_PREVIOUS"* ]]
  [ ! -e "$D/gh/secret.BRINGUP_KEYRING" ]
}

@test "FAILING FIXTURE: a Secret that is missing stops the command by member, and nothing is written" {
  rm "$D/cluster/gibson.route53-credential.json"
  recover staging "${EMPTIES[@]}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"DNS_ACCESS_KEY (the Secret gibson/route53-credential does not exist)"* ]]
  [[ "$output" == *"DNS_SECRET_KEY"* ]]
  [ ! -e "$D/gh/secret.BRINGUP_KEYRING" ]
}

@test "FAILING FIXTURE: a required member with no value stops the command by name" {
  secret gibson bringup-keyring '{}' "openbao-seal-key=" "openbao-seal-previous-key=" \
    "bucket-access-key=$(g BUCKET_ACCESS_KEY)" "bucket-secret-key=$(g BUCKET_SECRET_KEY)" "smtp-password=$(g SMTP_PASSWORD)" \
    "setec-disk-signing-seed=$(g SETEC_DISK_SIGNING_SEED)" "ghcr-pull-token=" "stripe-secret-key=" "stripe-publishable-key=" "stripe-webhook-secret="
  recover staging "${EMPTIES[@]}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"OPENBAO_SEAL_KEY"* ]]
  [ ! -e "$D/gh/secret.BRINGUP_KEYRING" ]
}

@test "FAILING FIXTURE: a member that differs from substrate.env stops the command, names it, and prints the exact rerun" {
  new="$(head -c 32 /dev/urandom | base64 -w0)"
  secret gibson bringup-keyring '{}' "openbao-seal-key=$new" "openbao-seal-previous-key=$(g OPENBAO_SEAL_KEY)" \
    "bucket-access-key=$(g BUCKET_ACCESS_KEY)" "bucket-secret-key=$(g BUCKET_SECRET_KEY)" "smtp-password=$(g SMTP_PASSWORD)" \
    "setec-disk-signing-seed=$(g SETEC_DISK_SIGNING_SEED)" "ghcr-pull-token=" "stripe-secret-key=" "stripe-publishable-key=" "stripe-webhook-secret="
  recover staging "${EMPTIES[@]}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"OPENBAO_SEAL_KEY"* ]]
  [[ "$output" == *"OPENBAO_SEAL_KEY_PREVIOUS"* ]]
  [[ "$output" == *"--accept-changed OPENBAO_SEAL_KEY --accept-changed OPENBAO_SEAL_KEY_PREVIOUS"* ]]
  [ ! -e "$D/gh/secret.BRINGUP_KEYRING" ]
  # With the changes accepted, the new keyring is written and verifies.
  recover staging "${EMPTIES[@]}" --accept-changed OPENBAO_SEAL_KEY --accept-changed OPENBAO_SEAL_KEY_PREVIOUS
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$("$REPO/scripts/keyring.sh" get "$D/gh/secret.BRINGUP_KEYRING" OPENBAO_SEAL_KEY)" = "$new" ]
  [ "$("$REPO/scripts/keyring.sh" get "$D/gh/secret.BRINGUP_KEYRING" OPENBAO_SEAL_KEY_PREVIOUS)" = "$(g OPENBAO_SEAL_KEY)" ]
  run "$REPO/scripts/keyring.sh" verify "$D/gh/secret.BRINGUP_KEYRING" "$D/gh/variable.SUBSTRATE_ENV_FILE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "FAILING FIXTURE: an environment that is not staging or prod is refused" {
  recover drill "${EMPTIES[@]}"
  [ "$status" -eq 2 ]
  [ ! -e "$D/gh/secret.BRINGUP_KEYRING" ]
}

@test "every member of keyring.sh is rebuilt from the cluster or named as not stored" {
  members="$(sed -n '/^MEMBERS=(/,/^)/p' "$REPO/scripts/keyring.sh" | grep -oE '^  [A-Z_]+' | tr -d ' ')"
  for m in $members; do
    grep -qE "\"$m\\|" "$REPO/scripts/recover-keyring.sh" || grep -qE "^NOT_IN_CLUSTER=.*\\b$m\\b" "$REPO/scripts/recover-keyring.sh" \
      || { echo "$m is neither rebuilt nor named as not stored"; false; }
  done
}

@test "the workflow and the recovery use the one write-back code" {
  grep -q 'scripts/keyring-writeback.sh' "$REPO/.github/workflows/rotate-credentials.yml"
  grep -q 'WRITEBACK=.*keyring-writeback.sh' "$REPO/scripts/recover-keyring.sh"
}

@test "the write-back writes a file only when it differs from the copy that was read" {
  S="$D/state"; mkdir -p "$S"; cp "$K" "$S/keyring.env"; cp "$D/substrate.env.var" "$S/substrate.env"
  sha256sum < "$S/keyring.env" | cut -d' ' -f1 > "$S/.read-keyring.sha256"
  sha256sum < "$S/substrate.env" | cut -d' ' -f1 > "$S/.read-substrate.sha256"
  run "$REPO/scripts/keyring-writeback.sh" "$S" staging
  [ "$status" -eq 0 ]
  [ ! -e "$D/gh/secret.BRINGUP_KEYRING" ]
  echo "KEYRING_SET_AT_X=1" >> "$S/keyring.env"
  run "$REPO/scripts/keyring-writeback.sh" "$S" staging
  [ "$status" -eq 0 ]
  [ -s "$D/gh/secret.BRINGUP_KEYRING" ]
  [ ! -e "$D/gh/variable.SUBSTRATE_ENV_FILE" ]
}
