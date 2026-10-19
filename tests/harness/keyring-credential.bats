#!/usr/bin/env bats
#
# keyring-credential.bats — a call with the keyring's bucket credential sends
# that credential and nothing of the caller's.
#
# On a runner the OIDC role leaves AWS_SESSION_TOKEN in the environment. The
# durable-bucket helper set its own key pair and kept the token, so S3 refused
# the call as InvalidToken and the drill recreate stopped at the archive gate
# (run 37413963774, 2026-10-06). The workstation never saw it: a profile sets
# no session token in the environment.
#
# Run:
#   bats tests/harness/keyring-credential.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin"
  # An aws that prints the credential it was given.
  cat > "$WORK/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "key=${AWS_ACCESS_KEY_ID:-} token=${AWS_SESSION_TOKEN:-<unset>} profile=${AWS_PROFILE:-<unset>}"
EOF
  chmod +x "$WORK/bin/aws"
  export PATH="$WORK/bin:$PATH"
  export AWS_SESSION_TOKEN=caller-session AWS_PROFILE=caller-profile
  export BUCKET_ENDPOINT=https://s3.example BUCKET_REGION=us-east-1
}

teardown() { rm -rf "$WORK"; }

@test "FAILING FIXTURE: the durable-bucket helper drops the caller's session token and profile" {
  printf 'BUCKET_ENDPOINT=https://s3.example\nBUCKET_NAME=b\nBUCKET_REGION=us-east-1\nKEYRING_FILE=%s\n' \
    "$WORK/keyring.env" > "$WORK/substrate.env"
  printf 'BUCKET_ACCESS_KEY=keyring-key\nBUCKET_SECRET_KEY=keyring-secret\n' > "$WORK/keyring.env"
  SUBSTRATE_ENV="$WORK/substrate.env"
  die() { echo "die: $*" >&2; return 1; }
  # shellcheck source=../../scripts/lib/durable-bucket.sh
  . "$REPO_ROOT/scripts/lib/durable-bucket.sh"
  run s3 s3api list-objects-v2
  [ "$status" -eq 0 ]
  [ "$output" = "key=keyring-key token=<unset> profile=<unset>" ]
}

@test "every keyring bucket credential in scripts/ drops the caller's session token" {
  # Each place that sets AWS_ACCESS_KEY_ID from the keyring must be preceded by
  # `env -u AWS_SESSION_TOKEN`. preflight.sh unsets it for the whole script.
  run python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
bad = []
for f in sorted((root / "scripts").rglob("*.sh")):
    if f.name == "preflight.sh":
        continue
    lines = f.read_text().splitlines()
    for i, line in enumerate(lines):
        if re.match(r'\s*AWS_ACCESS_KEY_ID="\$(\(keyring_get BUCKET|BUCKET_ACCESS_KEY)', line):
            prev = lines[i - 1] if i else ""
            if "env -u AWS_SESSION_TOKEN" not in prev:
                bad.append(f"{f.relative_to(root)}:{i + 1}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  [ "$status" -eq 0 ]
}
