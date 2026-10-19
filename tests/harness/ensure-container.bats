#!/usr/bin/env bats
#
# ensure-container.bats — a stage 0 container is keyed by its whole run
# configuration, never by its image and address alone.
#
# WHY THIS SUITE EXISTS
# ---------------------
# On 2026-09-05 the kind state directory was regenerated with a new MinIO
# root credential and a new Mailpit AUTH table. The containers from
# 2026-09-01 kept running: `ensure_container` compared the image and the
# address, both unchanged, and a container reads its --env-file only at
# `docker run`. Stage 0 then died at the bucket step with a signature
# mismatch that named nothing. scripts/lib/ensure-container.sh fingerprints
# the run configuration, including the CONTENT of every --env-file, and
# stores it as a label; a mismatch recreates the container on its data.
#
# HOW IT IS OFFLINE
# -----------------
# `docker` is stubbed on PATH. The stub keeps one state file per container
# (label, running) under the test tmpdir and appends every call to a log.
# The assertions are on that log: which verbs ran, in which order.
#
# Run:
#   bats tests/harness/ensure-container.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/ensure-container.sh"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  DOCKER_STATE="$BATS_TEST_TMPDIR/docker"
  mkdir -p "$STUB_DIR" "$DOCKER_STATE"
  export DOCKER_STATE
  export DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  : > "$DOCKER_LOG"
  PATH="$STUB_DIR:$PATH"

  cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
# A docker that knows five verbs and one label. State: $DOCKER_STATE/<name>.label
# and $DOCKER_STATE/<name>.running. Every call lands in $DOCKER_LOG.
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1 $2" in
  "container inspect")
    [ -f "$DOCKER_STATE/$3.label" ] ;;
  "inspect -f")
    name="$4"
    case "$3" in
      *Labels*)   cat "$DOCKER_STATE/$name.label" ;;
      *Running*)  cat "$DOCKER_STATE/$name.running" ;;
      *) echo "stub: unknown inspect format $3" >&2; exit 2 ;;
    esac ;;
  "rm -f")
    rm -f "$DOCKER_STATE/$3.label" "$DOCKER_STATE/$3.running" ;;
  "start "*)
    printf 'true\n' > "$DOCKER_STATE/$2.running" ;;
  "run -d")
    name=""; label=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift ;;
        --label) case "$2" in zeroroot.ai/substrate-config=*) label="${2#*=}" ;; esac; shift ;;
      esac
      shift
    done
    printf '%s\n' "$label" > "$DOCKER_STATE/$name.label"
    printf 'true\n' > "$DOCKER_STATE/$name.running"
    echo "0123456789ab" ;;
  *) echo "stub: unknown docker verb $1 $2" >&2; exit 2 ;;
esac
STUB
  chmod +x "$STUB_DIR/docker"

  ENV_FILE="$BATS_TEST_TMPDIR/minio-root.env"
  printf 'MINIO_ROOT_USER=substrate-admin\nMINIO_ROOT_PASSWORD=first\n' > "$ENV_FILE"
}

# run_ensure — source the lib with the caller's contract (NET, say, step,
# die) and run ensure_container against the stub for the minio shape.
run_ensure() {
  NET=kind
  say()  { printf 'say: %s\n' "$*"; }
  step() { printf 'step: %s\n' "$*"; }
  die()  { printf 'die: %s\n' "$*" >&2; exit 2; }
  # shellcheck source=/dev/null
  . "$LIB"
  ensure_container substrate-kind-minio "ghcr.io/x/minio:1" 172.18.255.250 -- \
    --env-file "$ENV_FILE" -v "$BATS_TEST_TMPDIR/minio:/data" "ghcr.io/x/minio:1" server /data
}

verbs() { awk '{print $1" "$2}' "$DOCKER_LOG" | grep -vE '^(container|inspect) ' ; }

@test "a container that does not exist is started with the fingerprint label" {
  run run_ensure
  [ "$status" -eq 0 ]
  [[ "$output" == *"started at 172.18.255.250 (config "* ]]
  grep -qE '^run -d .*--label zeroroot.ai/substrate-config=[0-9a-f]{16} ' "$DOCKER_LOG"
  [ -s "$DOCKER_STATE/substrate-kind-minio.label" ]
}

@test "a running container with the same configuration is left alone" {
  run run_ensure
  [ "$status" -eq 0 ]
  : > "$DOCKER_LOG"
  run run_ensure
  [ "$status" -eq 0 ]
  [[ "$output" == *"running at 172.18.255.250"* ]]
  [ -z "$(verbs)" ]
}

@test "a stopped container with the same configuration is started, not recreated" {
  run run_ensure
  [ "$status" -eq 0 ]
  printf 'false\n' > "$DOCKER_STATE/substrate-kind-minio.running"
  : > "$DOCKER_LOG"
  run run_ensure
  [ "$status" -eq 0 ]
  [ "$(verbs)" = "start substrate-kind-minio" ]
}

@test "a regenerated env-file with the same image and address recreates the container" {
  run run_ensure
  [ "$status" -eq 0 ]
  old="$(cat "$DOCKER_STATE/substrate-kind-minio.label")"
  printf 'MINIO_ROOT_USER=substrate-admin\nMINIO_ROOT_PASSWORD=second\n' > "$ENV_FILE"
  : > "$DOCKER_LOG"
  run run_ensure
  [ "$status" -eq 0 ]
  [[ "$output" == *"was started from a different configuration"* ]]
  [ "$(verbs | tr '\n' ' ')" = "rm -f run -d " ]
  [ "$(cat "$DOCKER_STATE/substrate-kind-minio.label")" != "$old" ]
}

@test "rewriting the env-file with the same bytes changes nothing" {
  run run_ensure
  [ "$status" -eq 0 ]
  printf 'MINIO_ROOT_USER=substrate-admin\nMINIO_ROOT_PASSWORD=first\n' > "$ENV_FILE"
  : > "$DOCKER_LOG"
  run run_ensure
  [ "$status" -eq 0 ]
  [ -z "$(verbs)" ]
}

@test "a container with no fingerprint label (pre-fix) is recreated" {
  printf '\n' > "$DOCKER_STATE/substrate-kind-minio.label"
  printf 'true\n' > "$DOCKER_STATE/substrate-kind-minio.running"
  run run_ensure
  [ "$status" -eq 0 ]
  [[ "$output" == *"(no label vs "* ]]
  [ "$(verbs | tr '\n' ' ')" = "rm -f run -d " ]
}

@test "an unreadable env-file is a refusal, not a silent fingerprint" {
  rm -f "$ENV_FILE"
  run run_ensure
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not readable"* ]]
  [ -z "$(verbs)" ]
}
