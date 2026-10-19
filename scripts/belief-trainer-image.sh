#!/usr/bin/env bash
# belief-trainer-image.sh — copy the belief trainer image that the env overlay
# pins into the ECR repository of the env (gibson#31, the D85 path).
#
# In plain words: the SaaS trainer image (ghcr.io/zeroroot-ai/billing-belief-
# trainer, with the curated base model) is private, and the trainer CronJob of
# each tenant namespace has no image pull secret. So the node pulls a copy
# from the private ECR repository of the env with its instance role. This
# script makes that copy, with the digest unchanged.
#
# The overlay names the copy as a reviewed commit:
#   gibson-operators.tenantOperator.beliefTrainer.image.repository
#     = BELIEF_TRAINER_REPO of substrate.env (substrate/gibson-bootstrap/ecr.tf)
#   gibson-operators.tenantOperator.beliefTrainer.image.tag
#     = "<tag>@sha256:<digest>", the tag and digest of the GHCR image
# scripts/check-overlay-belief-trainer.py proves the repository at check time.
#
# The script:
#   1. reads the pin from gitops/envs/<env>/values.yaml. An overlay that pins
#      no trainer image needs no copy, and the script says so and stops;
#   2. refuses a repository that is not BELIEF_TRAINER_REPO, or a tag with no
#      digest;
#   3. when the ECR tag exists, proves it holds the pinned digest (the tags
#      are immutable, so another digest is a defect, never a move);
#   4. else copies ghcr.io/zeroroot-ai/billing-belief-trainer@<digest> to
#      <repo>:<tag> with skopeo, every platform and the digest preserved, and
#      proves the digest again.
#
# Credentials: GHCR_PULL_TOKEN of the bringup keyring reads the source. The
# AWS session of the operator (stage 1, ADR-0083) writes ECR. The recreate
# verbs of AWS call this after their identity check, and
# `make belief-trainer-image ENV=<env>` runs it alone: run it BEFORE a commit
# that moves the pin reaches main, so the node never pulls a missing tag.
#
# Usage: belief-trainer-image.sh <substrate.env> <env>
# Exit:  0 the copy holds the pinned digest, or the overlay pins none
#        1 a refusal · 2 the script could not run
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SUBSTRATE_ENV="${1:-}"
ENV_NAME="${2:-}"
SOURCE_REPO="${BELIEF_TRAINER_SOURCE:-ghcr.io/zeroroot-ai/billing-belief-trainer}"

log() { printf '▶ [belief-trainer %s] %s\n' "$ENV_NAME" "$*"; }
die() { printf '✗ [belief-trainer %s] %s\n' "$ENV_NAME" "$*" >&2; exit "${2:-1}"; }

if [ -z "$SUBSTRATE_ENV" ] || [ -z "$ENV_NAME" ]; then
  die "usage: belief-trainer-image.sh <substrate.env> <env>" 2
fi
[ -r "$SUBSTRATE_ENV" ] || die "cannot read ${SUBSTRATE_ENV}" 2
substrate_get() { grep -E "^$1=" "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true; }

# GITOPS_PATH is the overlay directory the app-of-apps syncs, as in the
# recreate verbs, relative to the repo root.
overlay="$REPO/${GITOPS_PATH:-gitops/envs/${ENV_NAME}}/values.yaml"
[ -s "$overlay" ] || die "no overlay at ${overlay}" 2
read -r repo tag < <(python3 -c '
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
i = (((((v.get("gibson-operators") or {}).get("tenantOperator") or {})
       .get("beliefTrainer") or {}).get("image")) or {})
print(i.get("repository") or "-", i.get("tag") or "-")
' "$overlay") || die "could not read gibson-operators.tenantOperator.beliefTrainer.image from ${overlay}" 2

if [ "$repo" = - ] && [ "$tag" = - ]; then
  log "the overlay pins no belief trainer image: the chart default runs, and there is nothing to copy"
  exit 0
fi

want_repo="$(substrate_get BELIEF_TRAINER_REPO)"
[ -n "$want_repo" ] \
  || die "${SUBSTRATE_ENV} has no BELIEF_TRAINER_REPO. Run make substrate ENV=${ENV_NAME} again"
[ "$repo" = "$want_repo" ] \
  || die "${overlay} sets beliefTrainer.image.repository to '${repo}', and stage 0 of ${ENV_NAME} made ${want_repo}. A tenant namespace has no pull secret, so the node can pull only that repository"
case "$tag" in
  *@sha256:*) ;;
  *) die "${overlay} sets beliefTrainer.image.tag to '${tag}', with no digest. Pin '<tag>@sha256:<digest>' of ${SOURCE_REPO}" ;;
esac
name="${tag%@*}"
digest="${tag#*@}"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "the digest '${digest}' of ${overlay} is not sha256:<64 hex>"

# shellcheck source=lib/skopeo.sh
. "$HERE/lib/skopeo.sh"
skopeo_reason="$(skopeo_missing_all)" || die "$skopeo_reason" 2
command -v aws >/dev/null 2>&1 || die "aws is not on PATH" 2

region="$(printf '%s' "$repo" | sed -nE 's#^[0-9]+\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com/.*#\1#p')"
[ -n "$region" ] || die "'${repo}' is not an ECR repository URL"
ecr_password="$(aws ecr get-login-password --region "$region" 2>/dev/null)" \
  || die "aws ecr get-login-password failed: the AWS session cannot reach ECR in ${region}"
dest="docker://${repo}:${name}"

# The registry credentials go to skopeo in an auth file of mode 0600, never
# on a command line, where each local user could read them in the process
# list. The helper reads them on stdin for the same reason. The file lives in
# a private directory and leaves on exit.
AUTH_DIR="$(mktemp -d)"
chmod 700 "$AUTH_DIR"
trap 'rm -rf "$AUTH_DIR"' EXIT
AUTH="$AUTH_DIR/auth.json"
# write_auth: the auth file with one entry for each stdin line
# "<host> <user> <password>" (the password is the rest of the line).
write_auth() {
  ( umask 077
    python3 -c '
import base64, json, sys
auths = {}
for line in sys.stdin.read().splitlines():
    host, user, password = line.split(" ", 2)
    auths[host] = {"auth": base64.b64encode((user + ":" + password).encode()).decode()}
print(json.dumps({"auths": auths}))
' > "$AUTH" )
}
printf '%s AWS %s\n' "${repo%%/*}" "$ecr_password" | write_auth

# dest_digest: the digest of the manifest at the ECR tag, or nothing.
dest_digest() {
  local raw
  raw="$(skopeo inspect --raw --authfile "$AUTH" "$dest" 2>/dev/null)" || return 0
  printf 'sha256:%s' "$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1)"
}

have="$(dest_digest)"
if [ -n "$have" ]; then
  [ "$have" = "$digest" ] \
    || die "${repo}:${name} holds ${have}, and the overlay pins ${digest}. The tags are immutable: pin a new tag, never another digest under the same tag"
  log "${repo}:${name} already holds ${digest}"
  exit 0
fi

KEYRING_FILE="${KEYRING_FILE:-$(substrate_get KEYRING_FILE)}"
[ -s "$KEYRING_FILE" ] || die "no readable KEYRING_FILE: GHCR_PULL_TOKEN of the keyring reads the private source image" 2
token="$("$HERE/keyring.sh" get "$KEYRING_FILE" GHCR_PULL_TOKEN)"
[ -n "$token" ] \
  || die "the keyring holds no GHCR_PULL_TOKEN, so ${SOURCE_REPO} cannot be read. Set it with scripts/keyring.sh set, then run this again"

printf '%s AWS %s\n%s x-access-token %s\n' \
  "${repo%%/*}" "$ecr_password" "${SOURCE_REPO%%/*}" "$token" | write_auth
log "copying ${SOURCE_REPO}@${digest} to ${repo}:${name}"
skopeo copy --all --preserve-digests --authfile "$AUTH" \
  "docker://${SOURCE_REPO}@${digest}" "$dest" >/dev/null \
  || die "skopeo copy of ${SOURCE_REPO}@${digest} failed"
have="$(dest_digest)"
[ "$have" = "$digest" ] || die "after the copy ${repo}:${name} holds '${have:-nothing}', not ${digest}"
log "${repo}:${name} holds ${digest}"
