#!/usr/bin/env bats
#
# baseline-set-secret-target.bats: `make baseline-set-secret` passes the value
# on stdin, never on an argv, and refuses VALUE= (security advisory follow-up,
# charts#679 interface).
#
# Offline. CHARTS_ROOT is a stub tree whose baseline-set-secret.sh records its
# argv and its stdin.
#
# Run:
#   bats tests/harness/baseline-set-secret-target.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  CR="$BATS_TEST_TMPDIR/charts"
  mkdir -p "$CR/helm/gibson" "$CR/scripts"
  cat > "$CR/scripts/baseline-set-secret.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$#" > "$CR_OUT/argc"
printf '%s\n' "$@" > "$CR_OUT/argv"
cat > "$CR_OUT/stdin"
SH
  chmod +x "$CR/scripts/baseline-set-secret.sh"
  export CR_OUT="$BATS_TEST_TMPDIR"
  MK="$REPO_ROOT/Makefile"
}

# setter MAKEFILE ARGS...: pipe a known value into the target.
setter() {
  local mk="$1"; shift
  printf '%s\n' 'v4lue-xyz' | make -s -C "$REPO_ROOT" -f "$mk" baseline-set-secret CHARTS_ROOT="$CR" "$@"
}

@test "the value reaches the script on stdin, and the script gets two arguments" {
  run setter "$MK" KEY=ghcr-pull-secret PROP=pat
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$BATS_TEST_TMPDIR/argc")" = 2 ]
  [ "$(cat "$BATS_TEST_TMPDIR/argv")" = $'ghcr-pull-secret\npat' ]
  [ "$(cat "$BATS_TEST_TMPDIR/stdin")" = "v4lue-xyz" ]
}

@test "VALUE= is refused, names the stdin form, and never runs the script" {
  run make -s -C "$REPO_ROOT" baseline-set-secret CHARTS_ROOT="$CR" KEY=k PROP=p VALUE=s3cr3t-abc </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"VALUE= is refused"* ]]
  [[ "$output" == *"| make baseline-set-secret KEY=<key> PROP=<property>"* ]]
  [[ "$output" != *"s3cr3t-abc"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/argc" ]
}

@test "the recipe that make would run with VALUE= does not hold the value" {
  run make -n -C "$REPO_ROOT" baseline-set-secret CHARTS_ROOT="$CR" KEY=k PROP=p VALUE=s3cr3t-abc
  [[ "$output" != *"s3cr3t-abc"* ]]
}

@test "FAILING FIXTURE: the old recipe, with the value as a third argument, is caught" {
  sed 's|scripts/baseline-set-secret.sh "$(KEY)" "$(PROP)"$|scripts/baseline-set-secret.sh "$(KEY)" "$(PROP)" "$(VALUE)"|; s|^\t@$(if $(VALUE),.*$|\t@true|' \
    "$MK" > "$BATS_TEST_TMPDIR/old.mk"
  run setter "$BATS_TEST_TMPDIR/old.mk" KEY=k PROP=p VALUE=s3cr3t-abc
  [ "$(cat "$BATS_TEST_TMPDIR/argc")" = 3 ]
  run make -n -C "$REPO_ROOT" -f "$BATS_TEST_TMPDIR/old.mk" baseline-set-secret CHARTS_ROOT="$CR" KEY=k PROP=p VALUE=s3cr3t-abc
  [[ "$output" == *"s3cr3t-abc"* ]]
}
