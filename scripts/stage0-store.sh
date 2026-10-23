# ---------------------------------------------------------------------------
# stage0-store.sh — where the stage 0 files of an environment live (ADR-0083,
# amendment of 2026-10-21).
#
# The Terraform state of stage 0, the access key slots and the rotation record
# of EVERY environment live in the durable bucket of the environment, under
# the prefix tfstate/stage0/:
#
#   tfstate/stage0/terraform.tfstate     the state, with S3 native lock files
#   tfstate/stage0/key-slots.tfvars.json the active access key slot of each user
#   tfstate/stage0/key-rotation.json     the time of the last switch of each user
#
# So the credential rotation workflow (.github/workflows/rotate-credentials.yml)
# and a workstation see the same state. The bucket is
# zeroroot-ai-<env>-durable-<account>. The role of the workflow can write
# only under that prefix (substrate/gibson-bootstrap/rotation-role.tf).
#
# The keyring and substrate.env of EVERY environment live in one Secrets
# Manager secret, zeroroot-ai/<env>/keyring (substrate/gibson-bootstrap/
# keyring-secret.tf), as {"keyring", "substrate_env"}. No GitHub environment
# secret and no workstation file holds a keyring (ADR-0083, amendment of
# 2026-10-22).
#
# Functions (source this file; the caller defines die):
#   stage0_bucket <env>                       the durable bucket of the env
#   stage0_init <tf-dir> <env> <state-dir>    terraform init on the S3 backend
#   stage0_pull_keyring <env> <state-dir>     the keyring and substrate.env, from Secrets Manager
#   stage0_pull <env> <state-dir>             the same, and the slot files from the bucket
#   stage0_push_keyring <env> <state-dir>     keyring.env and substrate.env -> Secrets Manager
#   stage0_push <env> <state-dir>             the same, and the slot files -> the bucket
#
# As a command: stage0-store.sh pull-keyring <env> <state-dir> (a job that
# reads only the keyring), stage0-store.sh pull <env> <state-dir> (a job that
# also reads the slot files), and
# stage0-store.sh migrate <env> <state-dir> (the one-time move of an existing state)
#
# The files that hold secrets go to disk only under <state-dir>, mode 0600,
# and through `file://`, never through an argument.
# ---------------------------------------------------------------------------

STAGE0_TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../substrate/gibson-bootstrap" && pwd)"
STAGE0_REGION="us-east-1"
STAGE0_PREFIX="tfstate/stage0"

stage0_bucket() {
  local acct
  acct="$(aws sts get-caller-identity --query Account --output text)" || return 1
  printf 'zeroroot-ai-%s-durable-%s' "$1" "$acct"
}

# _stage0_head <bucket> <key>: 0 when the object exists, 1 when it does not,
# 2 when the answer is an error (no access, no network). A caller never reads
# an error as "does not exist".
_stage0_head() {
  local err
  err="$(aws s3api head-object --bucket "$1" --key "$2" 2>&1 >/dev/null)" && return 0
  case "$err" in *"Not Found"*|*404*|*NoSuchKey*|*NoSuchBucket*) return 1 ;; esac
  printf '%s\n' "$err" >&2
  return 2
}

# stage0_init <tf-dir> <env> <state-dir>
# The state is in the durable bucket. A new environment has no bucket yet, so
# its first apply uses a local state file under <state-dir>, and substrate.sh
# moves it into the bucket when the apply made the bucket (stage0_migrate).
stage0_init() {
  local tf="$1" env="$2" state="$3" bucket
  bucket="$(stage0_bucket "$env")" || die "could not read the AWS account, so the stage 0 state bucket of ${env} has no name"
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    rm -f "$state/.stage0-bootstrap" "$tf/backend_override.tf"
    # The durable bucket exists, so stage 0 has been applied, so its state must
    # be at this key. An empty key means a plan from nothing, which would try to
    # create every resource again. This holds on any machine: it does not depend
    # on what files a machine has. The state moves once, with the command below.
    local rc=0
    _stage0_head "$bucket" "${STAGE0_PREFIX}/terraform.tfstate" || rc=$?
    case "$rc" in
      0) ;;
      1) die "the durable bucket ${bucket} exists, and the stage 0 state of ${env} is not at s3://${bucket}/${STAGE0_PREFIX}/terraform.tfstate. A plan now would start from nothing and try to create every resource again. Move the existing state there once, on the machine that holds it: scripts/stage0-store.sh migrate ${env} ${state}" ;;
      *) die "could not read s3://${bucket}/${STAGE0_PREFIX}/terraform.tfstate, so this run cannot tell an empty state from a state it may not read" ;;
    esac
    terraform -chdir="$tf" init -reconfigure -input=false -no-color \
      -backend-config="bucket=${bucket}" \
      -backend-config="key=${STAGE0_PREFIX}/terraform.tfstate" \
      -backend-config="region=${STAGE0_REGION}" \
      -backend-config="use_lockfile=true" \
      -backend-config="encrypt=true" >/dev/null \
      || die "terraform init of stage 0 failed against s3://${bucket}/${STAGE0_PREFIX}/. If the state is still on a workstation, run the one-time terraform init -migrate-state (substrate/gibson-bootstrap/README.md)"
  else
    ( umask 077; mkdir -p "$state"; : > "$state/.stage0-bootstrap" )
    printf 'terraform {\n  backend "local" {\n    path = "%s/terraform.tfstate"\n  }\n}\n' "$state" > "$tf/backend_override.tf"
    terraform -chdir="$tf" init -reconfigure -input=false -no-color >/dev/null \
      || die "terraform init of stage 0 failed on ${state}/terraform.tfstate"
  fi
}

# stage0_migrate <tf-dir> <env> <state-dir>: after the apply that made the
# durable bucket, move the local state into it. Nothing to do otherwise.
stage0_migrate() {
  local tf="$1" env="$2" state="$3"
  [ -e "$state/.stage0-bootstrap" ] || return 0
  rm -f "$state/.stage0-bootstrap" "$tf/backend_override.tf"
  aws s3api head-bucket --bucket "$(stage0_bucket "$env")" >/dev/null 2>&1 \
    || die "the durable bucket of ${env} does not exist after the apply, so the state stays in ${state}/terraform.tfstate"
  terraform -chdir="$tf" init -migrate-state -force-copy -input=false -no-color \
    -backend-config="bucket=$(stage0_bucket "$env")" \
    -backend-config="key=${STAGE0_PREFIX}/terraform.tfstate" \
    -backend-config="region=${STAGE0_REGION}" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true" >/dev/null \
    || die "could not move the stage 0 state of ${env} into the durable bucket"
}

# _stage0_s3_get <bucket> <key> <file>: copy one object down. A missing object
# is not an error (the file has not been written yet); any other failure is.
_stage0_s3_get() {
  local err
  err="$(aws s3api head-object --bucket "$1" --key "$2" 2>&1 >/dev/null)" || {
    case "$err" in *"Not Found"*|*404*|*NoSuchBucket*) return 0 ;; esac
    die "could not read s3://$1/$2: ${err}"
  }
  ( umask 077; aws s3 cp --only-show-errors "s3://$1/$2" "$3" ) || die "could not copy s3://$1/$2"
}

# stage0_pull_keyring <env> <state-dir>: keyring.env and substrate.env from the
# keyring secret. A job that has no access to tfstate/stage0/ calls this one.
stage0_pull_keyring() {
  local env="$1" state="$2"
  # A caller that pulled already (substrate-rotate.sh, which then runs
  # substrate.sh) has newer files than AWS until it pushes. Pull once.
  [ "${STAGE0_PULLED:-}" != "$state" ] || return 0
  ( umask 077; mkdir -p "$state" )
  # A keyring changed on this runner since the last pull or push holds a
  # value that AWS does not: a pull would overwrite it and write the old value
  # back (drill sweep row 42, the seal key class of the rotation test).
  # Refuse, and name the file.
  if [ -s "${state}/keyring.env" ] && [ -s "${state}/.keyring.sha256" ] \
     && [ "$(sha256sum < "${state}/keyring.env" | cut -d' ' -f1)" != "$(cat "${state}/.keyring.sha256")" ]; then
    die "${state}/keyring.env changed since it was read from or written to AWS; a pull would overwrite it with the copy in zeroroot-ai/${env}/keyring. Push it, or remove it, first"
  fi
  if ! ( umask 077
      aws secretsmanager get-secret-value --secret-id "zeroroot-ai/${env}/keyring" \
        --query SecretString --output text > "${state}/.keyring-secret.json" 2> "${state}/.keyring-secret.err" ); then
    # A secret with no value yet, or no secret yet: stage 0 has not written
    # one. The first stage 0 run of an environment keeps its own files.
    if grep -q "can't find the specified secret" "${state}/.keyring-secret.err"; then
      rm -f "${state}/.keyring-secret.json" "${state}/.keyring-secret.err"
      printf '  the keyring secret zeroroot-ai/%s/keyring holds no value yet; the files in %s stay\n' "$env" "$state" >&2
      export STAGE0_PULLED="$state"
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

# stage0_pull <env> <state-dir>: the keyring, and the slot files.
stage0_pull() {
  local env="$1" state="$2" bucket f
  [ "${STAGE0_PULLED:-}" != "$state" ] || return 0
  bucket="$(stage0_bucket "$env")" || die "could not read the AWS account"
  ( umask 077; mkdir -p "$state" )
  for f in key-slots.tfvars.json key-rotation.json; do
    _stage0_s3_get "$bucket" "${STAGE0_PREFIX}/${f}" "${state}/${f}"
  done
  stage0_pull_keyring "$env" "$state"
}

# stage0_push_keyring <env> <state-dir>: keyring.env and substrate.env into the
# keyring secret. The one write of the keyring.
stage0_push_keyring() {
  local env="$1" state="$2"
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

# stage0_push <env> <state-dir>: the keyring, and the slot files.
stage0_push() {
  local env="$1" state="$2" bucket f
  bucket="$(stage0_bucket "$env")" || die "could not read the AWS account"
  for f in key-slots.tfvars.json key-rotation.json; do
    [ -f "${state}/${f}" ] || continue
    aws s3 cp --only-show-errors "${state}/${f}" "s3://${bucket}/${STAGE0_PREFIX}/${f}" \
      || die "could not write s3://${bucket}/${STAGE0_PREFIX}/${f}"
  done
  stage0_push_keyring "$env" "$state"
}

# stage0_migrate_old <env> <state-dir>: the one-time move of an existing state
# into tfstate/stage0/ (scripts/stage0-store.sh migrate <env> <state-dir>).
# It refuses when the new key already holds a state. The source of staging and
# prod is the local file of the state directory. The source of drill is the old
# key in the prod state bucket, and drill refuses a state directory that holds
# a local copy. The key slots and the rotation record move with the state. When
# the state in the bucket has the lineage and the serial of the source, the
# command deletes terraform.tfstate and terraform.tfstate.backup of the state
# directory.
stage0_migrate_old() {
  local env="$1" state="$2" bucket rc=0 f tf="$STAGE0_TF_DIR"
  bucket="$(stage0_bucket "$env")" || die "could not read the AWS account"
  aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 \
    || die "the durable bucket ${bucket} does not exist. A new environment needs no migration: make substrate ENV=${env}"
  _stage0_head "$bucket" "${STAGE0_PREFIX}/terraform.tfstate" || rc=$?
  [ "$rc" -eq 1 ] || { [ "$rc" -eq 0 ] && die "s3://${bucket}/${STAGE0_PREFIX}/terraform.tfstate already holds a state. Nothing to migrate"; die "could not read s3://${bucket}/${STAGE0_PREFIX}/terraform.tfstate"; }
  ( umask 077; mkdir -p "$state" )
  # The source of drill is the old key in the prod state bucket: the drill runs
  # wrote there, and a file on a workstation is older. So drill takes no local
  # state, key slots or rotation record.
  if [ "$env" = drill ]; then
    for f in terraform.tfstate key-slots.tfvars.json key-rotation.json; do
      [ ! -e "${state}/${f}" ] \
        || die "${state}/${f} exists. The stage 0 state of drill moves from the old key in the prod state bucket, which the drill runs wrote, and a local copy may be older. Run the migrate with an empty state directory: scripts/stage0-store.sh migrate drill \"\$(mktemp -d)\""
    done
    local acct; acct="$(aws sts get-caller-identity --query Account --output text)" || die "could not read the AWS account"
    ( umask 077; aws s3 cp --only-show-errors "s3://zeroroot-ai-prod-tfstate-${acct}-${STAGE0_REGION}/substrate/drill/terraform.tfstate" "${state}/terraform.tfstate" ) \
      || die "could not read the old state of drill"
  fi
  # Drill also keeps its key slots and rotation record in the old location.
  if [ "$env" = drill ]; then
    local oacct ob; oacct="$(aws sts get-caller-identity --query Account --output text)" || die "could not read the AWS account"
    ob="zeroroot-ai-prod-tfstate-${oacct}-${STAGE0_REGION}"
    for f in key-slots.tfvars.json key-rotation.json; do
      if _stage0_head "$ob" "substrate/drill/${f}"; then
        aws s3 cp --only-show-errors "s3://${ob}/substrate/drill/${f}" "${state}/${f}" \
          || die "could not read the old ${f} of drill"
      fi
    done
  fi
  [ -s "${state}/terraform.tfstate" ] || die "${state}/terraform.tfstate does not exist, so there is no state to migrate"
  printf 'terraform {\n  backend "local" {\n    path = "%s/terraform.tfstate"\n  }\n}\n' "$state" > "$tf/backend_override.tf"
  terraform -chdir="$tf" init -reconfigure -input=false -no-color >/dev/null \
    || { rm -f "$tf/backend_override.tf"; die "terraform init on the local state failed"; }
  rm -f "$tf/backend_override.tf"
  terraform -chdir="$tf" init -migrate-state -force-copy -input=false -no-color \
    -backend-config="bucket=${bucket}" \
    -backend-config="key=${STAGE0_PREFIX}/terraform.tfstate" \
    -backend-config="region=${STAGE0_REGION}" \
    -backend-config="use_lockfile=true" \
    -backend-config="encrypt=true" >/dev/null \
    || die "terraform init -migrate-state failed against s3://${bucket}/${STAGE0_PREFIX}/"
  for f in key-slots.tfvars.json key-rotation.json; do
    [ -f "${state}/${f}" ] || continue
    aws s3 cp --only-show-errors "${state}/${f}" "s3://${bucket}/${STAGE0_PREFIX}/${f}" \
      || die "could not write s3://${bucket}/${STAGE0_PREFIX}/${f}"
  done
  # The state in the bucket must be the local state: the same lineage and the
  # same serial. Then no local copy of the state stays. The state holds the
  # access keys in clear text, and a second copy is a second place to read
  # them and a second state to apply from by mistake.
  ( umask 077; terraform -chdir="$tf" state pull > "${state}/.stage0-remote.tfstate" ) \
    || { rm -f "${state}/.stage0-remote.tfstate"; die "could not read back the state from s3://${bucket}/${STAGE0_PREFIX}/terraform.tfstate. The local state stays in ${state}"; }
  python3 - "${state}/terraform.tfstate" "${state}/.stage0-remote.tfstate" <<'PY' \
    || { rm -f "${state}/.stage0-remote.tfstate"; die "the state in s3://${bucket}/${STAGE0_PREFIX}/terraform.tfstate is not the local state ${state}/terraform.tfstate. The local state stays. Read both before the next apply"; }
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
sys.exit(0 if (a.get("lineage"), a.get("serial")) == (b.get("lineage"), b.get("serial")) and a.get("lineage") else 1)
PY
  rm -f "${state}/.stage0-remote.tfstate" "${state}/terraform.tfstate" "${state}/terraform.tfstate.backup"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  die() { printf '! [stage0-store] %s\n' "$*" >&2; exit 2; }
  case "${1:-}" in
    pull)         [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "usage: stage0-store.sh pull <env> <state-dir>"
                  stage0_pull "$2" "$3"
                  [ -s "$3/keyring.env" ] && [ -s "$3/substrate.env" ] \
                    || die "the keyring secret zeroroot-ai/$2/keyring holds no keyring yet. Run make substrate ENV=$2 once from the workstation"
                  printf '  ✓ [stage0-store] stage 0 of %s read from AWS into %s\n' "$2" "$3" ;;
    pull-keyring) [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "usage: stage0-store.sh pull-keyring <env> <state-dir>"
                  stage0_pull_keyring "$2" "$3"
                  [ -s "$3/keyring.env" ] && [ -s "$3/substrate.env" ] \
                    || die "the keyring secret zeroroot-ai/$2/keyring holds no keyring yet. Run make substrate ENV=$2 once from the workstation"
                  printf '  ✓ [stage0-store] the keyring of %s read from AWS into %s\n' "$2" "$3" ;;
    migrate) [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "usage: stage0-store.sh migrate <env> <state-dir>"
             stage0_migrate_old "$2" "$3"
             printf '  ✓ [stage0-store] the stage 0 state of %s is now in s3://%s/%s/\n' "$2" "$(stage0_bucket "$2")" "$STAGE0_PREFIX" ;;
    *) die "usage: stage0-store.sh pull|pull-keyring|migrate <env> <state-dir>" ;;
  esac
fi
