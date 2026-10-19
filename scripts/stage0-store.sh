#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stage0-store.sh — where the stage 0 files of an environment live (ADR-0083,
# amendment of 2026-10-13).
#
# Staging and prod keep stage 0 on the operator workstation, under
# <state-dir> (SUBSTRATE_DIR/<env>): the Terraform state, the access key
# slots, the rotation record, the keyring and substrate.env.
#
# An environment whose envs/<env>.tfvars sets `keyring_in_aws = true` (drill
# only) keeps them in AWS, so a runner with the bringup role can run stage 0
# and rotate the access keys:
#
#   the state            s3://zeroroot-ai-prod-tfstate-<account>-us-east-1/
#                        substrate/<env>/terraform.tfstate, with the lock
#                        table zeroroot-ai-prod-tf-locks and the KMS key
#                        alias/zeroroot-ai-prod-tf-bootstrap (the same as
#                        substrate/apex-zone)
#   the slots, the record   the same prefix, key-slots.tfvars.json and
#                        key-rotation.json
#   keyring, substrate.env  the Secrets Manager secret zeroroot-ai/<env>/keyring
#                        (keyring-secret.tf), as {"keyring", "substrate_env"}
#
# Functions (source this file; the caller defines die):
#   stage0_remote <env>                       true when the env keeps stage 0 in AWS
#   stage0_init <tf-dir> <env> <state-dir>    terraform init on the right backend
#   stage0_pull <env> <state-dir>             AWS -> <state-dir> (remote only)
#   stage0_push <env> <state-dir>             <state-dir> -> AWS (remote only)
#
# As a command, for a runner: stage0-store.sh pull <env> <state-dir>
#
# The files that hold secrets go to disk only under <state-dir>, mode 0600,
# and through `file://`, never through an argument.
# ---------------------------------------------------------------------------

STAGE0_TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../substrate/gibson-bootstrap" && pwd)"
STAGE0_REGION="us-east-1"

stage0_remote() {
  grep -qE '^keyring_in_aws[[:space:]]*=[[:space:]]*true' "$STAGE0_TF_DIR/envs/$1.tfvars" 2>/dev/null
}

_stage0_bucket() {
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text)" || return 1
  printf 'zeroroot-ai-prod-tfstate-%s-%s' "$acct" "$STAGE0_REGION"
}

# stage0_init <tf-dir> <env> <state-dir>
stage0_init() {
  local tf="$1" env="$2" state="$3" bucket
  if stage0_remote "$env"; then
    bucket="$(_stage0_bucket)" || die "could not read the AWS account, so the stage 0 state bucket of ${env} has no name"
    # The one backend block of the root is local. An override file selects
    # S3 for this env only. It is git-ignored, and stage0_init of a local env
    # removes it.
    printf 'terraform {\n  backend "s3" {}\n}\n' > "$tf/backend_override.tf"
    terraform -chdir="$tf" init -reconfigure -input=false -no-color \
      -backend-config="bucket=${bucket}" \
      -backend-config="key=substrate/${env}/terraform.tfstate" \
      -backend-config="region=${STAGE0_REGION}" \
      -backend-config="dynamodb_table=zeroroot-ai-prod-tf-locks" \
      -backend-config="kms_key_id=alias/zeroroot-ai-prod-tf-bootstrap" \
      -backend-config="encrypt=true" >/dev/null \
      || die "terraform init of stage 0 failed against s3://${bucket}/substrate/${env}/"
  else
    rm -f "$tf/backend_override.tf"
    terraform -chdir="$tf" init -reconfigure -input=false -no-color \
      -backend-config="path=${state}/terraform.tfstate" >/dev/null \
      || die "terraform init of stage 0 failed on ${state}/terraform.tfstate"
  fi
}

# _stage0_s3_get <bucket> <key> <file>: copy one object down. A missing object
# is not an error (the file has not been written yet); any other failure is.
_stage0_s3_get() {
  local err
  err="$(aws s3api head-object --bucket "$1" --key "$2" 2>&1 >/dev/null)" || {
    case "$err" in *"Not Found"*|*404*) rm -f "$3"; return 0 ;; esac
    die "could not read s3://$1/$2: ${err}"
  }
  ( umask 077; aws s3 cp --only-show-errors "s3://$1/$2" "$3" ) || die "could not copy s3://$1/$2"
}

# stage0_pull <env> <state-dir>
stage0_pull() {
  local env="$1" state="$2" bucket f
  stage0_remote "$env" || return 0
  # A caller that pulled already (substrate-rotate.sh, which then runs
  # substrate.sh) has newer files than AWS until it pushes. Pull once.
  [ "${STAGE0_PULLED:-}" != "$state" ] || return 0
  bucket="$(_stage0_bucket)" || die "could not read the AWS account"
  ( umask 077; mkdir -p "$state" )
  # A keyring changed on this runner since the last pull or push holds a
  # value that AWS does not: a pull would overwrite it and write the old value
  # back (drill sweep row 42, the seal key class of the rotation test).
  # Refuse, and name the file.
  if [ -s "${state}/keyring.env" ] && [ -s "${state}/.keyring.sha256" ] \
     && [ "$(sha256sum < "${state}/keyring.env" | cut -d' ' -f1)" != "$(cat "${state}/.keyring.sha256")" ]; then
    die "${state}/keyring.env changed since it was read from or written to AWS; a pull would overwrite it with the copy in zeroroot-ai/${env}/keyring. Push it, or remove it, first"
  fi
  for f in key-slots.tfvars.json key-rotation.json; do
    _stage0_s3_get "$bucket" "substrate/${env}/${f}" "${state}/${f}"
  done
  if ! ( umask 077
      aws secretsmanager get-secret-value --secret-id "zeroroot-ai/${env}/keyring" \
        --query SecretString --output text > "${state}/.keyring-secret.json" 2> "${state}/.keyring-secret.err" ); then
    # A secret with no value yet: stage 0 made it and has not written it. The
    # workstation run that moves the keyring into AWS keeps its own files.
    if grep -q "can't find the specified secret value" "${state}/.keyring-secret.err"; then
      rm -f "${state}/.keyring-secret.json" "${state}/.keyring-secret.err"
      printf '  the keyring secret zeroroot-ai/%s/keyring holds no value yet; the files in %s stay\n' "$env" "$state" >&2
      return 0
    fi
    die "could not read the keyring secret zeroroot-ai/${env}/keyring: $(head -c 300 "${state}/.keyring-secret.err")"
  fi
  rm -f "${state}/.keyring-secret.err"
  python3 - "${state}/.keyring-secret.json" "$state" <<'PY' || die "the keyring secret zeroroot-ai/${env}/keyring is not {keyring, substrate_env}"
import json, os, re, sys
v = json.load(open(sys.argv[1]))
state = sys.argv[2]
for name, text in (("keyring.env", v["keyring"]), ("substrate.env", v["substrate_env"])):
    path = os.path.join(state, name)
    if name == "substrate.env":
        text = re.sub(r"(?m)^KEYRING_FILE=.*$", "KEYRING_FILE=" + os.path.join(state, "keyring.env"), text)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text if text.endswith("\n") else text + "\n")
PY
  rm -f "${state}/.keyring-secret.json"
  sha256sum < "${state}/keyring.env" | cut -d' ' -f1 > "${state}/.keyring.sha256"
  export STAGE0_PULLED="$state"
}

# stage0_push <env> <state-dir>
stage0_push() {
  local env="$1" state="$2" bucket f
  stage0_remote "$env" || return 0
  bucket="$(_stage0_bucket)" || die "could not read the AWS account"
  for f in key-slots.tfvars.json key-rotation.json; do
    [ -f "${state}/${f}" ] || continue
    aws s3 cp --only-show-errors --sse aws:kms --sse-kms-key-id alias/zeroroot-ai-prod-tf-bootstrap \
      "${state}/${f}" "s3://${bucket}/substrate/${env}/${f}" || die "could not write s3://${bucket}/substrate/${env}/${f}"
  done
  [ -s "${state}/keyring.env" ] && [ -s "${state}/substrate.env" ] \
    || die "${state} holds no keyring.env or substrate.env to keep"
  ( umask 077
    python3 - "${state}/keyring.env" "${state}/substrate.env" > "${state}/.keyring-secret.json" <<'PY'
import json, sys
print(json.dumps({"keyring": open(sys.argv[1]).read(), "substrate_env": open(sys.argv[2]).read()}))
PY
  ) || die "could not build the keyring secret value"
  aws secretsmanager put-secret-value --secret-id "zeroroot-ai/${env}/keyring" \
    --secret-string "file://${state}/.keyring-secret.json" >/dev/null \
    || { rm -f "${state}/.keyring-secret.json"; die "could not write the keyring secret zeroroot-ai/${env}/keyring"; }
  rm -f "${state}/.keyring-secret.json"
  sha256sum < "${state}/keyring.env" | cut -d' ' -f1 > "${state}/.keyring.sha256"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  die() { printf '! [stage0-store] %s\n' "$*" >&2; exit 2; }
  case "${1:-}" in
    pull) [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "usage: stage0-store.sh pull <env> <state-dir>"
          stage0_remote "$2" || die "ENV=$2 keeps stage 0 on the workstation, not in AWS"
          stage0_pull "$2" "$3"
          [ -s "$3/keyring.env" ] && [ -s "$3/substrate.env" ] \
            || die "the keyring secret zeroroot-ai/$2/keyring holds no keyring yet. Run make substrate ENV=$2 once from the workstation"
          printf '  ✓ [stage0-store] stage 0 of %s read from AWS into %s\n' "$2" "$3" ;;
    *) die "usage: stage0-store.sh pull <env> <state-dir>" ;;
  esac
fi
