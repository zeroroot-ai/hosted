#!/usr/bin/env bats
# belief-trainer-image.bats — the copy of the belief trainer image refuses a
# pin that a tenant pod cannot pull, before any registry call (gibson#31).
#
# Run:
#   bats tests/harness/belief-trainer-image.bats

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
REPO_URL="111122223333.dkr.ecr.us-east-1.amazonaws.com/zeroroot-ai-fx-belief-trainer"
DIGEST="sha256:$(printf 'a%.0s' $(seq 64))"

setup() {
  SUB="$BATS_TEST_TMPDIR/substrate.env"
  printf 'BELIEF_TRAINER_REPO=%s\nKEYRING_FILE=%s/keyring.env\n' "$REPO_URL" "$BATS_TEST_TMPDIR" > "$SUB"
  mkdir -p "$BATS_TEST_TMPDIR/overlay"
  GITOPS_PATH="$(realpath --relative-to="$ROOT" "$BATS_TEST_TMPDIR/overlay")"
  export GITOPS_PATH
  # No tool reaches a registry or AWS: each one fails if it is called.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  for t in skopeo aws; do
    printf '#!/usr/bin/env bash\necho "%s must not run" >&2\nexit 99\n' "$t" > "$BIN/$t"
    chmod +x "$BIN/$t"
  done
}

overlay() {
  cat > "$BATS_TEST_TMPDIR/overlay/values.yaml" <<YAML
gibson-operators:
  tenantOperator:
    beliefTrainer:
      image:
        repository: "$1"
        tag: "$2"
YAML
}

@test "an overlay that pins no trainer image needs no copy" {
  printf 'gibson-operators: {}\n' > "$BATS_TEST_TMPDIR/overlay/values.yaml"
  PATH="$BIN:$PATH" run "$ROOT/scripts/belief-trainer-image.sh" "$SUB" fx
  [ "$status" -eq 0 ]
  [[ "$output" == *"pins no belief trainer image"* ]]
}

@test "FAILING FIXTURE: the private GHCR image is refused: no tenant pod can pull it" {
  overlay "ghcr.io/zeroroot-ai/billing-belief-trainer" "main@$DIGEST"
  PATH="$BIN:$PATH" run "$ROOT/scripts/belief-trainer-image.sh" "$SUB" fx
  [ "$status" -eq 1 ]
  [[ "$output" == *"stage 0 of fx made $REPO_URL"* ]]
  [[ "$output" != *"must not run"* ]]
}

@test "FAILING FIXTURE: a tag with no digest is refused" {
  overlay "$REPO_URL" "main"
  PATH="$BIN:$PATH" run "$ROOT/scripts/belief-trainer-image.sh" "$SUB" fx
  [ "$status" -eq 1 ]
  [[ "$output" == *"with no digest"* ]]
  [[ "$output" != *"must not run"* ]]
}

@test "FAILING FIXTURE: a substrate.env with no trainer repository is refused" {
  overlay "$REPO_URL" "main@$DIGEST"
  sed -i '/^BELIEF_TRAINER_REPO=/d' "$SUB"
  PATH="$BIN:$PATH" run "$ROOT/scripts/belief-trainer-image.sh" "$SUB" fx
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no BELIEF_TRAINER_REPO"* ]]
}

# A fake skopeo that logs its argv and the mode and entries of its auth file.
# The tag is empty until the copy, then holds the manifest "m".
fake_registry() {
  cat > "$BIN/aws" <<'SH'
#!/usr/bin/env bash
printf 'ecr-secret-password'
SH
  cat > "$BIN/skopeo" <<SH
#!/usr/bin/env bash
log="$BATS_TEST_TMPDIR/skopeo.log"
echo "argv: \$*" >> "\$log"
auth=""
prev=""
for a in "\$@"; do [ "\$prev" = "--authfile" ] && auth="\$a"; prev="\$a"; done
[ -n "\$auth" ] && echo "mode: \$(stat -c %a "\$auth")" >> "\$log"
[ -n "\$auth" ] && python3 -c 'import base64,json,sys;[print("entry:",h,base64.b64decode(v["auth"]).decode()) for h,v in json.load(open(sys.argv[1]))["auths"].items()]' "\$auth" >> "\$log"
[ "\$*" = "copy --help" ] && { printf '  -a, --all    Copy all images if SOURCE-IMAGE is a list\n'; exit 0; }
case "\$1" in
  inspect) [ -f "$BATS_TEST_TMPDIR/copied" ] || exit 1; printf 'm' ;;
  copy) touch "$BATS_TEST_TMPDIR/copied" ;;
esac
SH
  chmod +x "$BIN/aws" "$BIN/skopeo"
  printf 'GHCR_PULL_TOKEN=ghcr-secret-token\n' > "$BATS_TEST_TMPDIR/keyring.env"
  chmod 600 "$BATS_TEST_TMPDIR/keyring.env"
}

@test "the registry credentials reach skopeo in an auth file of mode 0600, never in an argv" {
  fake_registry
  overlay "$REPO_URL" "main@sha256:$(printf 'm' | sha256sum | cut -d' ' -f1)"
  PATH="$BIN:$PATH" run "$ROOT/scripts/belief-trainer-image.sh" "$SUB" fx
  [ "$status" -eq 0 ]
  log="$(cat "$BATS_TEST_TMPDIR/skopeo.log")"
  [[ "$log" == *"argv: copy"* ]]
  [[ "$log" == *"entry: ghcr.io x-access-token:ghcr-secret-token"* ]]
  [[ "$log" == *"entry: 111122223333.dkr.ecr.us-east-1.amazonaws.com AWS:ecr-secret-password"* ]]
  run grep -E '^argv: .*(secret|--creds|--src-creds|--dest-creds)' "$BATS_TEST_TMPDIR/skopeo.log"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^mode: ' "$BATS_TEST_TMPDIR/skopeo.log")" -ge 2 ]
  run grep -vE '^mode: 600$' <(grep '^mode: ' "$BATS_TEST_TMPDIR/skopeo.log")
  [ "$status" -eq 1 ]
}

# skopeo copy --all (hosted#602). An old skopeo has no --all and failed only
# at the copy, after preflight and the archive gate (staging, 2026-10-11).
old_skopeo() {
  cat > "$BIN/skopeo" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "copy --help") printf '  --authfile string   path of the authentication file\n  --remove-signatures\n' ;;
  --version) echo "skopeo version 0.1.36-dev" ;;
  *) echo "skopeo must not copy" >&2; exit 99 ;;
esac
SH
  chmod +x "$BIN/skopeo"
}

@test "FAILING FIXTURE: a skopeo with no copy --all is refused before any registry call" {
  old_skopeo
  overlay "$REPO_URL" "main@$DIGEST"
  PATH="$BIN:$PATH" run "$ROOT/scripts/belief-trainer-image.sh" "$SUB" fx
  [ "$status" -eq 2 ]
  [[ "$output" == *"has no copy --all"* ]]
  [[ "$output" == *"0.1.36"* ]]
  [[ "$output" != *"must not"* ]]
}

@test "FAILING FIXTURE: the skopeo check refuses a help text that names only a longer flag" {
  cat > "$BIN/skopeo" <<'SH'
#!/usr/bin/env bash
[ "$*" = "copy --help" ] && printf '  --all-tags   not the flag\n'
SH
  chmod +x "$BIN/skopeo"
  . "$ROOT/scripts/lib/skopeo.sh"
  PATH="$BIN:$PATH" run skopeo_missing_all
  [ "$status" -eq 1 ]
}

@test "the skopeo check passes a skopeo whose copy has --all" {
  fake_registry
  . "$ROOT/scripts/lib/skopeo.sh"
  PATH="$BIN:$PATH" run skopeo_missing_all
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
