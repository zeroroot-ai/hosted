#!/usr/bin/env bats
#
# drill-archive-clear.bats — the drill teardown empties the drill archive
# directory, and the verb refuses every other env and bucket (hosted#641).
#
# Offline: `aws` is a stub over a directory tree that stands for the bucket.
#
# Run:
#   bats tests/harness/drill-archive-clear.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
VERB="$REPO_ROOT/scripts/drill-archive-clear.sh"

setup() {
  BIN="$BATS_TEST_TMPDIR/bin"; STORE="$BATS_TEST_TMPDIR/bucket"
  mkdir -p "$BIN" "$STORE"
  export STORE
  # The bucket of the drill overlay, and its archive directory.
  read -r BUCKET PREFIX NAME < <(python3 - "$REPO_ROOT/gitops/envs/drill/values.yaml" <<'PY'
import sys, yaml
b = (yaml.safe_load(open(sys.argv[1])) or {})["platformPostgres"]["backup"]
d = b["destinationPath"][len("s3://"):]
bucket, _, prefix = d.partition("/")
print(bucket, prefix.rstrip("/") + "/", b["serverName"])
PY
)
  export BUCKET PREFIX NAME
  SUB="$BATS_TEST_TMPDIR/substrate.env"
  printf 'BUCKET_NAME=%s\n' "$BUCKET" > "$SUB"
  # Two archive objects of the drill, and one object of another directory.
  mkdir -p "$STORE/$PREFIX$NAME/wals" "$STORE/${PREFIX}other"
  echo w > "$STORE/$PREFIX$NAME/wals/000000010000000000000001"
  echo b > "$STORE/$PREFIX$NAME/base.info"
  echo o > "$STORE/${PREFIX}other/keep"
  # The derived archive of one restore (D91), and a hand-stamped neighbor
  # whose name starts the same way but is not a restore archive.
  mkdir -p "$STORE/$PREFIX$NAME-r20261012T040000/wals" "$STORE/$PREFIX$NAME-rebuild"
  echo w > "$STORE/$PREFIX$NAME-r20261012T040000/wals/000000020000000000000005"
  echo k > "$STORE/$PREFIX$NAME-rebuild/keep"
  cat > "$BIN/aws" <<'SH'
#!/usr/bin/env bash
echo "aws $*" >> "$STORE.calls"
# Only the archive directory of the drill overlay, in its bucket, is
# declared (hosted#654): a delete of any other bucket or prefix fails.
case "$*" in
  "s3 rm --recursive --only-show-errors s3://${BUCKET}/${PREFIX}${NAME}"*/)
    t="${*: -1}"; p="${t#s3://*/}"
    rm -rf "${STORE:?}/${p}"; exit 0 ;;
  "s3api list-objects-v2 --bucket ${BUCKET} --prefix ${PREFIX}${NAME}"*)
    p=""; prev=""; delim=""
    for a in "$@"; do [ "$prev" = --prefix ] && p="$a"; [ "$prev" = --delimiter ] && delim="$a"; prev="$a"; done
    if [ -n "$delim" ]; then
      # CommonPrefixes: each directory whose path starts with the prefix.
      out=""
      for d in "$STORE/${p}"*/; do [ -d "$d" ] || continue; out="${out:+$out	}${d#"$STORE/"}"; done
      echo "${out:-None}"; exit 0
    fi
    n=$( [ -d "$STORE/$p" ] && find "$STORE/$p" -type f | wc -l || echo 0)
    echo "$n"; exit 0 ;;
  *) echo "aws stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$BIN/aws"
  export PATH="$BIN:$PATH"
}

@test "the teardown empties the drill archive directory and nothing else" {
  run "$VERB" "$SUB" drill
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$(find "$STORE/$PREFIX$NAME" -type f 2>/dev/null)" ]
  [ -f "$STORE/${PREFIX}other/keep" ]
  [[ "$output" == *"is empty: the next drill run can archive"* ]]
}

@test "FAILING FIXTURE (D91): the teardown also empties the derived archive of a restore, and keeps a neighbor of another shape" {
  run "$VERB" "$SUB" drill
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$(find "$STORE/$PREFIX$NAME-r20261012T040000" -type f 2>/dev/null)" ]
  [ -f "$STORE/$PREFIX$NAME-rebuild/keep" ]
  [[ "$output" == *"${NAME}-r20261012T040000/ is empty"* ]]
  [[ "$output" == *"${NAME}-rebuild/ is not a restore archive"* ]]
}

@test "FAILING FIXTURE: staging is refused before any call to the bucket" {
  run "$VERB" "$SUB" staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"only the drill clears its archive"* ]]
  [ ! -s "$STORE.calls" ]
  [ -f "$STORE/$PREFIX$NAME/base.info" ]
}

@test "FAILING FIXTURE: prod is refused before any call to the bucket" {
  run "$VERB" "$SUB" prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"only the drill clears its archive"* ]]
  [ ! -s "$STORE.calls" ]
}

@test "FAILING FIXTURE: a substrate.env that names the staging bucket is refused" {
  printf 'BUCKET_NAME=zeroroot-ai-staging-durable-447184491447\n' > "$SUB"
  run "$VERB" "$SUB" drill
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a drill durable bucket"* ]]
  [ ! -s "$STORE.calls" ]
  [ -f "$STORE/$PREFIX$NAME/base.info" ]
}

@test "FAILING FIXTURE: a delete that leaves objects behind fails" {
  cat > "$BIN/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "s3 rm --recursive --only-show-errors s3://${BUCKET}/${PREFIX}${NAME}/") exit 0 ;;
  "s3api list-objects-v2 --bucket ${BUCKET} --prefix ${PREFIX}${NAME}/ "*) echo 2; exit 0 ;;
  *) echo "aws stub: undeclared call: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$BIN/aws"
  run "$VERB" "$SUB" drill
  [ "$status" -ne 0 ]
  [[ "$output" == *"still lists 2 object(s)"* ]]
}

@test "the drill workflow empties the archive after the teardown, pass or fail" {
  run python3 - "$REPO_ROOT/.github/workflows/drill.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]
steps = [s for j in steps.values() for s in j.get("steps", [])]
names = [s.get("name", "") for s in steps]
td = names.index("Tear down, and ask the account what survived")
cl = names.index("Empty the drill Postgres archive")
assert cl > td, "the archive is emptied before the teardown"
step = steps[cl]
assert "always()" in step.get("if", ""), "the step does not run on a failed drill"
assert step["run"].strip() == 'make drill-archive-clear ENV="${ENV}"', step["run"]
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
