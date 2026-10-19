# shellcheck shell=bash
# ---------------------------------------------------------------------------
# durable-bucket.sh — read stage 0's substrate and talk to the durable bucket.
#
# SOURCED. The caller must have set SUBSTRATE_ENV and provided log() and die().
#
# It exists because two consumers need exactly these readers and must never
# disagree about the bucket, the credential or the endpoint (ADR-0027):
#
#   scripts/lib/bringup-before-cluster.sh   the bringup's stage-0 gates
#   scripts/stamp-pg-archive.sh             picks the next free archive directory
#
# The second one cannot source the first: bringup-before-cluster.sh ends by
# RUNNING the archive gate, and that gate's refusal is what tells an operator to
# run stamp-pg-archive — so sourcing it to stamp a name would refuse to stamp
# the name.
#
# It leaves behind:
#   substrate_get keyring_get s3
#   BUCKET_ENDPOINT BUCKET_NAME BUCKET_REGION KEYRING_FILE
# ---------------------------------------------------------------------------

# A key that is not in substrate.env yields the empty string. Without the
# `|| true` grep exits 1, and under `set -e` a command substitution carries
# that out to the whole script — so an ABSENT OPTIONAL key killed the verb
# with no message at all. The required keys are asserted by name below.
substrate_get() { grep -E "^$1=" "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true; }
BUCKET_ENDPOINT="$(substrate_get BUCKET_ENDPOINT)"
BUCKET_NAME="$(substrate_get BUCKET_NAME)"
BUCKET_REGION="$(substrate_get BUCKET_REGION)"
KEYRING_FILE="${KEYRING_FILE:-$(substrate_get KEYRING_FILE)}"
[ -n "$BUCKET_ENDPOINT" ] && [ -n "$BUCKET_NAME" ] && [ -s "$KEYRING_FILE" ] \
  || die "${SUBSTRATE_ENV} is missing BUCKET_ENDPOINT, BUCKET_NAME or a readable KEYRING_FILE"

keyring_get() { grep -E "^$1=" "$KEYRING_FILE" | head -n1 | cut -d= -f2- || true; }

# s3 <aws args…> — the durable bucket, read with the keyring's OWN bucket
# credential. It has to work before stage 1 exists and after stage 1 is gone,
# so it never uses the cluster.
s3() {
  # The keyring's own credential, and nothing of the caller's. On a runner the
  # OIDC role leaves AWS_SESSION_TOKEN in the environment, and a key pair sent
  # with a foreign session token is refused as InvalidToken (drill run
  # 37413963774, 2026-10-06). AWS_PROFILE goes for the same reason.
  env -u AWS_SESSION_TOKEN -u AWS_PROFILE \
  AWS_ACCESS_KEY_ID="$(keyring_get BUCKET_ACCESS_KEY)" \
  AWS_SECRET_ACCESS_KEY="$(keyring_get BUCKET_SECRET_KEY)" \
  AWS_DEFAULT_REGION="${BUCKET_REGION:-us-east-1}" \
    aws --endpoint-url "$BUCKET_ENDPOINT" "$@"
}
