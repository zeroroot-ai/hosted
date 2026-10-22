#!/usr/bin/env bash
# keyring.sh — the bringup keyring: generate, fingerprint, verify (ADR-0083).
#
# The bringup keyring is the small set of secrets without which nothing in
# the durable bucket is readable. It outlives every cluster and never lives
# in a cluster, in the bucket, or in OpenBao. This file is the ONE definition
# of its shape. Stage 0 of every environment (kind/substrate/substrate.sh,
# substrate/gibson-bootstrap/substrate.sh) generates it with `generate` and records
# its fingerprints in substrate.env with `fingerprints`. preflight proves it
# with `verify`.
#
# File format (mode 0600, one member per line, no quotes, no `export`):
#
#   OPENBAO_SEAL_KEY=<base64 of 32 random bytes, 44 chars>
#   OPENBAO_SEAL_KEY_PREVIOUS=<the seal key before the last rotation, or empty>
#   VELERO_REPO_PASSWORD=<base64 of 32 random bytes, 44 chars>
#   VELERO_REPO_PASSWORD_PREVIOUS=<the repository password before the last rotation, or empty>
#   BUCKET_ACCESS_KEY=<20 chars, A-Z0-9>
#   BUCKET_SECRET_KEY=<base64 of 30 random bytes, 40 chars>
#   SMTP_PASSWORD=<at least 20 chars, no whitespace>
#   SETEC_DISK_SIGNING_SEED=<base64 of 32 random bytes, 44 chars>
#   SETEC_DISK_SIGNING_SEED_PREVIOUS=<the disk seed before the last rotation, or empty>
#   GHCR_PULL_TOKEN=<a GitHub token with read:packages, or empty>
#   DNS_ACCESS_KEY=<the access key id of the DNS credential, or empty>
#   DNS_SECRET_KEY=<its secret access key, or empty>
#   GITHUB_APP_PRIVATE_KEY=<base64 of the Argo CD GitHub App PEM, or empty>
#   STRIPE_SECRET_KEY=<the Stripe secret key, sk_ or rk_, or empty>
#   STRIPE_PUBLISHABLE_KEY=<the Stripe publishable key, pk_, or empty>
#   STRIPE_WEBHOOK_SECRET=<the Stripe webhook signing secret, whsec_, or empty>
#   SETEC_DISK_PUSH_ACCESS_KEY=<the access key id of the disk builder, or empty>
#   SETEC_DISK_PUSH_SECRET_KEY=<its secret access key, or empty>
#
# SETEC_DISK_SIGNING_SEED (D85, hosted#521) is the ed25519 seed that signs
# each setec sandbox disk (ADR-0166). It is always generated here, like the
# first two. The bringup writes it into the keyring Secret as
# `setec-disk-signing-seed`, and the chart seeds it into OpenBao
# (secret/data/setec-disk-signing). Each launcher checks a disk with the
# public key of the seed, which `disk-public-key` prints. The overlay of a
# cloud env names that key as a reviewed commit, and the recreate verb
# refuses an overlay whose keys are not the keys of this keyring: the key of
# the seed, and during a rotation the key of SETEC_DISK_SIGNING_SEED_PREVIOUS
# (`disk-public-keys` prints both).
#
# SETEC_DISK_PUSH_ACCESS_KEY and SETEC_DISK_PUSH_SECRET_KEY are the push
# credential of the disk builder: an access key pair with push on the disk
# repository of the env only (substrate/gibson-bootstrap/ecr.tf). Input
# members, set by stage 0 like the DNS pair. On kind the registry needs no
# credential, and both stay empty. The bringup writes them into the Secret
# `setec-disk-push-credential` (keys access-key-id, secret-access-key).
#
# The first two are always generated here. The next three are the shape
# of an AWS access key pair and of a relay password: on kind `generate`
# makes them up and stage 0 configures MinIO with the pair. kind has no SMTP
# relay (hosted#126), so on kind SMTP_PASSWORD only keeps the one keyring
# shape that every environment shares, and nothing reads it. On AWS
# stage 0 gets them from Terraform and passes them to `generate` in a
# provided file, so the keyring holds the credential the cloud issued. The
# SMTP password is opaque because the relay issues it (an SES SMTP password
# is 44 characters), so only a floor is checked.
#
# The members of kind input are values the keyring cannot generate.
# GHCR_PULL_TOKEN (deploy#1732) is the one seed value the platform consumes.
# The bringup writes it into the keyring Secret as `ghcr-pull-token`, and
# the openbao-auto-init sidecar copies it into OpenBao (`ghcr-pull-secret`,
# property `pat`). It is the ONE exception to "never in OpenBao": an input
# the platform consumes, not a key that opens the bucket. Empty is allowed
# and means "not supplied": the sidecar seeds the key empty, and an operator
# fills it later with scripts/baseline-set-secret.sh. An input member may be
# absent from an older keyring file; that reads as empty. There is no LLM
# key member: the platform holds no LLM credential of its own. A tenant's
# providers and their keys live in that tenant's provider configuration.
# DNS_ACCESS_KEY and DNS_SECRET_KEY are the Route53 credential cert-manager
# (DNS-01) and external-dns use: an access key pair scoped to the
# environment's zone. On AWS stage 0 mints it and `set`s it; on kind there
# is no zone and both stay empty. The bringup writes them into the Secret
# `route53-credential` (keys access-key-id, secret-access-key) when set,
# never into OpenBao.
# `set` writes an input member into an existing keyring; the other members
# never change after `generate`.
#
# GITHUB_APP_PRIVATE_KEY is the Argo CD GitHub App's PEM, base64-encoded
# because this file is one KEY=value line per member and a PEM is not one
# line. Argo CD clones the gitops repo, which is private, so without it the
# app-of-apps cannot read its own source: "failed to list refs:
# authentication required: Repository not found", and stage 2 stalls until
# its cap with one Application and no error anybody reads. Measured on the
# 2026-09-14 staging bringup. The APP'S IDS are not secrets and live in
# substrate.env; only the key is here. Empty is allowed and means the
# environment's Argo syncs from somewhere public, which is what kind does.
#
# STRIPE_SECRET_KEY, STRIPE_PUBLISHABLE_KEY and STRIPE_WEBHOOK_SECRET are
# the Stripe account of the environment (hosted#450). Only the owner holds
# them. The bringup writes them into the keyring Secret (stripe-secret-key,
# stripe-publishable-key, stripe-webhook-secret), and the openbao-auto-init
# sidecar copies them into the OpenBao key gibson-stripe-credentials
# (secret_key, publishable_key, webhook_secret). So a rebuild keeps them, and
# no person writes them into OpenBao by hand. Empty means "not supplied": the
# chart's test-mode placeholders stay, and preflight fails an environment
# that bills (staging, drill, prod).
#
# Comment lines start with `#`. The file is never sourced: a secret file
# that can run shell is a hazard, so it is read line by line.
#
# Fingerprint lines, as `fingerprints` prints them and substrate.env holds
# them:
#
#   KEYRING_FINGERPRINT_<MEMBER>=sha256:<hex of sha256(value)>
#   KEYRING_FINGERPRINT=sha256:<hex of sha256 over the member lines above>
#
# Commands:
#   keyring.sh generate <keyring-file> [<provided>]    write a new keyring, refuse to overwrite.
#                                                      <provided> holds MEMBER=value lines that
#                                                      stage 0 got from the substrate; the rest
#                                                      is generated
#   keyring.sh fingerprints <keyring-file>             print the fingerprint lines
#   keyring.sh verify <keyring-file> <substrate.env>   presence, length, fingerprint, one line per miss
#   keyring.sh get <keyring-file> <MEMBER>             print one member's value
#   keyring.sh set <keyring-file> <MEMBER> <value>     write an INPUT member, or a member the
#                                                      substrate issues (scripts/substrate-rotate.sh),
#                                                      into an existing keyring. Run make substrate
#                                                      ENV=<env> after it, so substrate.env records
#                                                      the new fingerprints
#   keyring.sh rotate <keyring-file> <MEMBER>          keep the value as <MEMBER>_PREVIOUS and
#                                                      generate a new one. Refuses while a
#                                                      previous value is kept
#   keyring.sh retire <keyring-file> <MEMBER>          clear <MEMBER>_PREVIOUS, after the
#                                                      cluster runs on the new value
#   keyring.sh disk-public-key <keyring-file>          print the base64 ed25519 public key of
#                                                      SETEC_DISK_SIGNING_SEED
#   keyring.sh disk-public-key --selftest              a known seed gives its known key
#   keyring.sh disk-public-keys <keyring-file>         print the public key of
#                                                      SETEC_DISK_SIGNING_SEED, then the key of
#                                                      SETEC_DISK_SIGNING_SEED_PREVIOUS when one
#                                                      is kept: the keys each launcher accepts
#
# ROTATION (ADR-0171, row keyring-generated-keys). Only a member with a
# <MEMBER>_PREVIOUS member rotates in place: OPENBAO_SEAL_KEY,
# VELERO_REPO_PASSWORD and SETEC_DISK_SIGNING_SEED. It runs in a workflow
# (ADR-0083, amendment of 2026-10-21): .github/workflows/rotate-credentials.yml.
# That workflow is the one documented entry point. It needs an approval for each run,
# and the workflow writes the new keyring into the keyring secret in Secrets
# Manager. Each step below is one dispatch of that workflow
# (scripts/rotate-credential.sh), except the commit of an overlay. The seal key:
#   1. keyring.sh rotate <file> OPENBAO_SEAL_KEY
#   2. keyring-to-cluster.sh, then restart OpenBao. The static seal unwraps
#      with either key and wraps with the new one (charts, the openbao
#      container writes both keys with their own ids).
#   3. After OpenBao runs unsealed on the new key, keyring.sh retire <file>
#      OPENBAO_SEAL_KEY, keyring-to-cluster.sh, and restart OpenBao again.
#   4. make substrate ENV=<env>, so substrate.env records the new fingerprints.
# rotate refuses while a previous value is kept: a second rotation before
# step 3 would drop the key that still wraps the store, and the store would
# stay sealed.
# The Velero repository password: kopia cannot change the password of a
# repository, so a new password starts a new repository at a new path.
#   1. keyring.sh rotate <file> VELERO_REPO_PASSWORD
#   2. Set the chart value bucket.prefix of gibson-velero to a new path under
#      backups/velero/ (the one prefix where the platform credential may
#      delete, for kopia) in the values of the environment, and merge it.
#   3. keyring-to-cluster.sh. The next scheduled backup starts the new
#      repository with the new password.
#   4. The previous password reads the old repository, for a restore from a
#      backup older than the rotation, until the bucket lifecycle expires the
#      old path (180 days). Then keyring.sh retire <file> VELERO_REPO_PASSWORD.
# The setec disk signing seed (ADR-0171, row setec-disk-signing-seed): each
# launcher accepts the disks of the public keys in the overlay, so the
# overlay lists both keys while the disks are signed again.
#   1. keyring.sh rotate <file> SETEC_DISK_SIGNING_SEED
#   2. keyring.sh disk-public-keys <file> prints the new and the previous key.
#      Commit both in gibson-workloads.setec.launcher.diskBuilder.publicKeys
#      of the env overlay, and merge it. Each launcher then accepts both.
#   3. keyring-to-cluster.sh. The openbao-auto-init sidecar follows the
#      keyring input within five minutes, and the disk builder signs each new
#      disk with the new seed.
#   4. Each disk signed with the previous seed is signed again with the new
#      seed (setec#272: the disk tag names the key that signed it, so the
#      disk builder builds a new disk for the new seed). Until setec#272
#      merges, do not run step 5: each launcher would refuse every old disk.
#   5. keyring.sh retire <file> SETEC_DISK_SIGNING_SEED, then commit the
#      overlay with the new key alone and merge it. A launcher then refuses a
#      disk of the previous seed.
#   6. make substrate ENV=<env>, so substrate.env records the new fingerprints.
# The recreate verb refuses an overlay whose key list is not exactly the keys
# that disk-public-keys prints, so neither a retired key nor a missing
# previous key reaches a cluster.
# Drill keeps SETEC_DISK_SIGNING_SEED_PREVIOUS for good: it is the second seed
# that the rotation test switches to (hosted#444, option a). Never run
# step 5 on drill.
#
# Exit codes: 0 ok, 1 the keyring fails a check, 2 the command could not run.

set -euo pipefail

# name:kind:size — kind b64 means base64 of exactly <size> bytes, kind alnum
# means exactly <size> characters from A-Z0-9, kind opaque means at least
# <size> characters with no whitespace (generated as base64 of 30 bytes),
# kind input means any value without whitespace, empty and absent allowed,
# never generated (size is unused and 0). Kind prev means empty, or base64 of
# exactly <size> bytes: the value of <MEMBER> before its last rotation. Empty
# and absent are allowed, and generate writes it empty.
# Order is the file order and the fingerprint order.
MEMBERS=(
  OPENBAO_SEAL_KEY:b64:32
  OPENBAO_SEAL_KEY_PREVIOUS:prev:32
  VELERO_REPO_PASSWORD:b64:32
  VELERO_REPO_PASSWORD_PREVIOUS:prev:32
  BUCKET_ACCESS_KEY:alnum:20
  BUCKET_SECRET_KEY:b64:30
  SMTP_PASSWORD:opaque:20
  SETEC_DISK_SIGNING_SEED:b64:32
  SETEC_DISK_SIGNING_SEED_PREVIOUS:prev:32
  GHCR_PULL_TOKEN:input:0
  DNS_ACCESS_KEY:input:0
  DNS_SECRET_KEY:input:0
  GITHUB_APP_PRIVATE_KEY:input:0
  STRIPE_SECRET_KEY:input:0
  STRIPE_PUBLISHABLE_KEY:input:0
  STRIPE_WEBHOOK_SECRET:input:0
  SETEC_DISK_PUSH_ACCESS_KEY:input:0
  SETEC_DISK_PUSH_SECRET_KEY:input:0
)

# The members that a vendor issues (GitHub, Stripe). A person gets a new value
# at the vendor and runs `set`, so the keyring records the time of each set:
# a line KEYRING_SET_AT_<MEMBER>=<epoch>, and the fingerprint of the value
# it set: KEYRING_SET_FP_<MEMBER>=<16 hex>. Neither is a member or in any
# fingerprint of substrate.env. `set` refuses the value already set, so a
# new set time always means a new value. keyring-to-cluster.sh copies the dates onto the keyring
# Secret, and the rotation drill fails a value older than its lifetime
# (ADR-0171, row vendor-issued-inputs).
VENDOR_MEMBERS="GHCR_PULL_TOKEN GITHUB_APP_PRIVATE_KEY STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY STRIPE_WEBHOOK_SECRET"
is_vendor() { case " $VENDOR_MEMBERS " in *" $1 "*) return 0 ;; esac; return 1; }

# The members that stage 0 gets from the substrate (AWS access keys and the
# SES SMTP password). scripts/substrate-rotate.sh sets the new value after it
# rotates an access key (ADR-0171). On kind they are generated and never set.
ISSUED_MEMBERS="BUCKET_ACCESS_KEY BUCKET_SECRET_KEY SMTP_PASSWORD"
is_issued() { case " $ISSUED_MEMBERS " in *" $1 "*) return 0 ;; esac; return 1; }

die() { printf 'keyring: %s\n' "$*" >&2; exit 2; }

# envfile_get FILE KEY — print the value of the first `KEY=value` line.
# Prints nothing and returns 1 when the key is absent.
envfile_get() {
  local line
  line="$(grep -E "^$2=" "$1" | head -n1)" || return 1
  printf '%s' "${line#*=}"
}

# b64_len SIZE — the base64 length of SIZE bytes.
b64_len() { echo $(( (($1 + 2) / 3) * 4 )); }

member_name() { echo "${1%%:*}"; }
member_kind() { local r="${1#*:}"; echo "${r%%:*}"; }
member_size() { echo "${1##*:}"; }

# member_spec NAME — the spec line of one member, or nothing.
member_spec() {
  local spec
  for spec in "${MEMBERS[@]}"; do
    [ "$(member_name "$spec")" = "$1" ] && { echo "$spec"; return 0; }
  done
  return 1
}

# is_input NAME — true for an input member.
is_input() {
  local spec
  spec="$(member_spec "$1")" || return 1
  [ "$(member_kind "$spec")" = input ]
}

# is_optional NAME — true for a member that may be empty or absent: an input
# member, or the previous value of a rotation.
is_optional() {
  local spec
  spec="$(member_spec "$1")" || return 1
  case "$(member_kind "$spec")" in input|prev) return 0 ;; esac
  return 1
}

# input_names — the input members, comma-separated, for a message.
input_names() {
  local spec out=()
  for spec in "${MEMBERS[@]}"; do
    [ "$(member_kind "$spec")" = input ] && out+=("$(member_name "$spec")")
  done
  local IFS=,
  echo "${out[*]}"
}

# member_expected_len SPEC — the character length a member must have: exact
# for b64 and alnum, a floor for opaque.
member_expected_len() {
  case "$(member_kind "$1")" in
    b64)    b64_len "$(member_size "$1")" ;;
    alnum)  member_size "$1" ;;
    opaque) member_size "$1" ;;
    input)  echo 0 ;;
    prev)   b64_len "$(member_size "$1")" ;;
  esac
}

# shape_error SPEC VALUE — print why VALUE does not fit SPEC, or nothing.
shape_error() {
  local spec="$1" value="$2" want have
  want="$(member_expected_len "$spec")"
  have="${#value}"
  if [ "$(member_kind "$spec")" = input ]; then
    if [[ "$value" =~ [[:space:]] ]]; then
      printf 'contains whitespace'; return
    fi
    return
  fi
  if [ "$(member_kind "$spec")" = prev ]; then
    [ -z "$value" ] && return
    spec="$(member_name "$spec"):b64:$(member_size "$spec")"
  fi
  if [ "$(member_kind "$spec")" = opaque ]; then
    if [ "$have" -lt "$want" ]; then
      printf 'has length %s, want at least %s' "$have" "$want"; return
    fi
    if [[ "$value" =~ [[:space:]] ]]; then
      printf 'contains whitespace'
    fi
    return
  fi
  if [ "$have" -ne "$want" ]; then
    printf 'has length %s, want %s' "$have" "$want"; return
  fi
  case "$(member_kind "$spec")" in
    b64)
      local bytes
      bytes="$(printf '%s' "$value" | base64 -d 2>/dev/null | wc -c)" || bytes=0
      if [ "$bytes" -ne "$(member_size "$spec")" ]; then
        printf 'is not base64 of %s bytes' "$(member_size "$spec")"
      fi ;;
    alnum)
      if ! [[ "$value" =~ ^[A-Z0-9]+$ ]]; then
        printf 'is not %s characters of A-Z0-9' "$want"
      fi ;;
  esac
}

sha256_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

gen_value() {
  case "$(member_kind "$1")" in
    input|prev) printf '' ;;
    b64)    head -c "$(member_size "$1")" /dev/urandom | base64 -w0 ;;
    # base32 (A-Z2-7) of enough random bytes, cut to size. No pipe from an
    # endless reader, so no SIGPIPE under pipefail.
    alnum)  head -c "$(member_size "$1")" /dev/urandom | base32 | tr -d '=\n' | cut -c1-"$(member_size "$1")" ;;
    opaque) head -c 30 /dev/urandom | base64 -w0 ;;
  esac
}

# cmd_generate FILE [PROVIDED] — write a new keyring. A member named in
# PROVIDED (MEMBER=value lines) takes that value and must fit its shape; every
# other member is generated. PROVIDED may name only members of the shape.
cmd_generate() {
  local file="${1:?usage: keyring.sh generate <keyring-file> [<provided>]}"
  local provided="${2:-}"
  [ -e "$file" ] && die "$file exists. To rotate a member with a previous member, run keyring.sh rotate. Another member is rotated with a new keyring and a new cluster: see docs/runbooks/substrate-kind.md"
  if [ -n "$provided" ]; then
    [ -r "$provided" ] || die "cannot read $provided"
    local key
    while IFS= read -r key; do
      case " ${MEMBERS[*]} " in
        *" $key:"*) ;;
        *) die "$provided names $key, which is not a keyring member" ;;
      esac
    done < <(grep -vE '^\s*(#|$)' "$provided" | cut -d= -f1)
  fi
  mkdir -p "$(dirname "$file")"
  local tmp
  tmp="$(umask 077 && mktemp "$(dirname "$file")/.keyring.XXXXXX")"
  {
    printf '# bringup keyring (ADR-0083), written %s by scripts/keyring.sh.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# Never commit. Never copy into a cluster, the bucket or OpenBao.\n'
    printf '# Shape and fingerprints: scripts/keyring.sh, substrate.env.\n'
    local spec name value err
    for spec in "${MEMBERS[@]}"; do
      name="$(member_name "$spec")"
      if [ -n "$provided" ] && value="$(envfile_get "$provided" "$name")" && [ -n "$value" ]; then
        err="$(shape_error "$spec" "$value")"
        [ -z "$err" ] || { rm -f "$tmp"; die "provided member $name $err"; }
      else
        # An input member not provided is written empty: "not supplied".
        value="$(gen_value "$spec")"
      fi
      printf '%s=%s\n' "$name" "$value"
      if is_vendor "$name" && [ -n "$value" ]; then
        printf 'KEYRING_SET_AT_%s=%s\n' "$name" "$(date +%s)"
        printf 'KEYRING_SET_FP_%s=%s\n' "$name" "$(sha256_of "$value" | cut -c1-16)"
      fi
    done
  } > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
  printf 'keyring: wrote %s (%s members)\n' "$file" "${#MEMBERS[@]}"
}

# check_shape FILE — every member present with the right shape. Prints the
# first miss and returns 1.
check_shape() {
  local file="$1" spec name value err
  for spec in "${MEMBERS[@]}"; do
    name="$(member_name "$spec")"
    if is_optional "$name"; then
      # Absent or empty is "not supplied" for an input member, and "no
      # rotation runs" for a previous value.
      value="$(envfile_get "$file" "$name")" || value=""
      err="$(shape_error "$spec" "$value")"
      if [ -n "$err" ]; then
        printf 'member %s %s\n' "$name" "$err"; return 1
      fi
      continue
    fi
    if ! value="$(envfile_get "$file" "$name")" || [ -z "$value" ]; then
      printf 'member %s missing from %s\n' "$name" "$file"; return 1
    fi
    err="$(shape_error "$spec" "$value")"
    if [ -n "$err" ]; then
      printf 'member %s %s\n' "$name" "$err"; return 1
    fi
  done
}

# member_lines FILE — the per-member fingerprint lines.
member_lines() {
  local spec name value
  for spec in "${MEMBERS[@]}"; do
    name="$(member_name "$spec")"
    # An absent input member fingerprints as the empty value.
    value="$(envfile_get "$1" "$name")" || value=""
    printf 'KEYRING_FINGERPRINT_%s=sha256:%s\n' "$name" "$(sha256_of "$value")"
  done
}

cmd_fingerprints() {
  local file="${1:?usage: keyring.sh fingerprints <keyring-file>}"
  [ -r "$file" ] || die "cannot read $file"
  local miss
  if ! miss="$(check_shape "$file")"; then die "$miss"; fi
  local lines
  lines="$(member_lines "$file")"
  printf '%s\n' "$lines"
  printf 'KEYRING_FINGERPRINT=sha256:%s\n' "$(sha256_of "$lines"$'\n')"
}

cmd_verify() {
  local file="${1:?usage: keyring.sh verify <keyring-file> <substrate.env>}"
  local env="${2:?usage: keyring.sh verify <keyring-file> <substrate.env>}"
  [ -r "$env" ] || die "cannot read $env"
  if [ ! -r "$file" ]; then printf 'keyring file %s is missing or unreadable\n' "$file"; exit 1; fi
  local miss
  if ! miss="$(check_shape "$file")"; then printf '%s\n' "$miss"; exit 1; fi
  local spec name want have
  for spec in "${MEMBERS[@]}"; do
    name="$(member_name "$spec")"
    if ! want="$(envfile_get "$env" "KEYRING_FINGERPRINT_$name")" || [ -z "$want" ]; then
      printf 'substrate.env records no fingerprint for member %s\n' "$name"; exit 1
    fi
    have="sha256:$(sha256_of "$(envfile_get "$file" "$name" || true)")"
    if [ "$have" != "$want" ]; then
      printf 'member %s does not match its recorded fingerprint (%s)\n' "$name" "$want"; exit 1
    fi
  done
  local lines set_want set_have
  lines="$(member_lines "$file")"
  set_have="sha256:$(sha256_of "$lines"$'\n')"
  if ! set_want="$(envfile_get "$env" KEYRING_FINGERPRINT)" || [ -z "$set_want" ]; then
    printf 'substrate.env records no KEYRING_FINGERPRINT\n'; exit 1
  fi
  if [ "$set_have" != "$set_want" ]; then
    printf 'keyring set fingerprint %s does not match the recorded %s\n' "$set_have" "$set_want"; exit 1
  fi
  # Report supplied and not-supplied separately. An input member is allowed to
  # be absent — it means "not supplied" — but counting it as "present" is how a
  # missing GHCR_PULL_TOKEN read as a green preflight while two first-party
  # images could not pull (deploy#1795). ADR-0083: a preflight that passes with
  # a missing input is a defect in preflight, so at minimum it must NAME what
  # is not there.
  local unsupplied=() supplied=0 counted=0
  for spec in "${MEMBERS[@]}"; do
    name="$(member_name "$spec")"
    # An empty previous value means no rotation runs, not a missing input.
    [ "$(member_kind "$spec")" = prev ] && continue
    counted=$((counted + 1))
    have="$(envfile_get "$file" "$name" 2>/dev/null || true)"
    if [ -n "$have" ]; then
      supplied=$((supplied + 1))
    else
      unsupplied+=("$name")
    fi
  done
  if [ "${#unsupplied[@]}" -eq 0 ]; then
    printf '%s members present, lengths right, fingerprints match %s\n' \
      "${#MEMBERS[@]}" "${set_have:0:19}"
  else
    printf '%s of %s members supplied, lengths right, fingerprints match %s; NOT SUPPLIED: %s\n' \
      "$supplied" "$counted" "${set_have:0:19}" "$(IFS=, ; echo "${unsupplied[*]}")"
  fi
}

cmd_get() {
  local file="${1:?usage: keyring.sh get <keyring-file> <MEMBER>}"
  local name="${2:?usage: keyring.sh get <keyring-file> <MEMBER>}"
  [ -r "$file" ] || die "cannot read $file"
  local value
  if ! value="$(envfile_get "$file" "$name")"; then
    # An absent input or previous member is empty: print nothing, succeed.
    is_optional "$name" && return 0
    die "member $name missing from $file"
  fi
  printf '%s' "$value"
}

# cmd_set FILE MEMBER VALUE — write one INPUT member into an existing keyring,
# atomically, keeping mode 0600 and every other line. Only input members may
# change after generate: every other member is a rotation and a new cluster.
cmd_set() {
  local file="${1:?usage: keyring.sh set <keyring-file> <MEMBER> <value>}"
  local name="${2:?usage: keyring.sh set <keyring-file> <MEMBER> <value>}"
  local value="${3-}"
  [ -r "$file" ] || die "cannot read $file"
  is_input "$name" || is_issued "$name" \
    || die "$name is not an input member or a member the substrate issues; only $(input_names) and ${ISSUED_MEMBERS// /,} may be set after generate"
  local spec err
  spec="$(member_spec "$name")"
  err="$(shape_error "$spec" "$value")"
  [ -z "$err" ] || die "member $name $err"
  local fp=""
  if is_vendor "$name" && [ -n "$value" ]; then
    fp="$(sha256_of "$value" | cut -c1-16)"
    [ "$(envfile_get "$file" "KEYRING_SET_FP_$name" || true)" != "$fp" ] \
      || die "$name already holds this value. A rotation needs a new value from the vendor"
  fi
  local tmp
  tmp="$(umask 077 && mktemp "$(dirname "$file")/.keyring.XXXXXX")"
  {
    grep -vE "^($name|KEYRING_SET_AT_$name|KEYRING_SET_FP_$name)=" "$file"
    printf '%s=%s\n' "$name" "$value"
    if [ -n "$fp" ]; then
      printf 'KEYRING_SET_AT_%s=%s\n' "$name" "$(date +%s)"
      printf 'KEYRING_SET_FP_%s=%s\n' "$name" "$fp"
    fi
  } > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
  if [ -n "$value" ]; then
    printf 'keyring: set %s in %s (sha256:%s)\n' "$name" "$file" "$(sha256_of "$value" | cut -c1-16)"
  else
    printf 'keyring: cleared %s in %s\n' "$name" "$file"
  fi
}

# write_members FILE NAME=VALUE... — replace the named members of FILE,
# atomically, keeping mode 0600 and every other line.
write_members() {
  local file="$1"; shift
  local tmp pair pattern=""
  for pair in "$@"; do pattern="${pattern:+$pattern|}^${pair%%=*}="; done
  tmp="$(umask 077 && mktemp "$(dirname "$file")/.keyring.XXXXXX")"
  {
    grep -vE "$pattern" "$file" || true
    for pair in "$@"; do printf '%s\n' "$pair"; done
  } > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
}

# cmd_rotate FILE MEMBER — keep MEMBER as MEMBER_PREVIOUS and generate a new
# MEMBER. Refuses while a previous value is kept (see ROTATION above).
cmd_rotate() {
  local file="${1:?usage: keyring.sh rotate <keyring-file> <MEMBER>}"
  local name="${2:?usage: keyring.sh rotate <keyring-file> <MEMBER>}"
  [ -r "$file" ] || die "cannot read $file"
  local spec pspec cur prev new miss
  spec="$(member_spec "$name")" || die "$name is not a keyring member"
  pspec="$(member_spec "${name}_PREVIOUS")" && [ "$(member_kind "$pspec")" = prev ] \
    || die "$name has no ${name}_PREVIOUS member, so it does not rotate in place. Rotate it with a new keyring and a new cluster"
  if ! miss="$(check_shape "$file")"; then die "$miss"; fi
  cur="$(envfile_get "$file" "$name")"
  prev="$(envfile_get "$file" "${name}_PREVIOUS" || true)"
  [ -z "$prev" ] || die "${name}_PREVIOUS still holds the key of the last rotation. When the cluster runs on ${name}, run keyring.sh retire first"
  new="$(gen_value "$spec")"
  write_members "$file" "${name}=${new}" "${name}_PREVIOUS=${cur}"
  printf 'keyring: rotated %s in %s (new sha256:%s, previous sha256:%s)\n' "$name" "$file" \
    "$(sha256_of "$new" | cut -c1-16)" "$(sha256_of "$cur" | cut -c1-16)"
}

# cmd_retire FILE MEMBER — clear MEMBER_PREVIOUS, after the cluster runs on
# the new value.
cmd_retire() {
  local file="${1:?usage: keyring.sh retire <keyring-file> <MEMBER>}"
  local name="${2:?usage: keyring.sh retire <keyring-file> <MEMBER>}"
  [ -r "$file" ] || die "cannot read $file"
  local pspec prev
  pspec="$(member_spec "${name}_PREVIOUS")" && [ "$(member_kind "$pspec")" = prev ] \
    || die "$name has no ${name}_PREVIOUS member"
  prev="$(envfile_get "$file" "${name}_PREVIOUS" || true)"
  [ -n "$prev" ] || die "${name}_PREVIOUS is already empty"
  write_members "$file" "${name}_PREVIOUS="
  printf 'keyring: retired the previous %s in %s (sha256:%s)\n' "$name" "$file" "$(sha256_of "$prev" | cut -c1-16)"
}

# ed25519_public_key SEED_B64 — the base64 raw public key of a base64 seed.
# openssl 1.1.1 or later: the seed is wrapped as a PKCS#8 ed25519 private key
# (the fixed 16-byte prefix, then the 32-byte seed), and the last 32 bytes of
# the DER public key are the raw key. The same derivation as the charts
# install (charts scripts/setec-disk-public-key.sh), so an overlay key and an
# install key of one seed agree.
ed25519_public_key() {
  {
    printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20'
    printf '%s' "$1" | base64 -d
  } | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0
}

# cmd_disk_public_key FILE — the public key of SETEC_DISK_SIGNING_SEED.
cmd_disk_public_key() {
  local file="${1:?usage: keyring.sh disk-public-key <keyring-file> | --selftest}"
  if [ "$file" = "--selftest" ]; then
    # RFC 8032 test vector 1: seed 9d61b19d...1a0a1b4f, public key d75a9801...3f09.
    local want="11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=" got
    got="$(ed25519_public_key "nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A=")"
    [ "$got" = "$want" ] || die "disk-public-key selftest: want ${want}, got ${got:-nothing}"
    printf 'keyring: disk-public-key selftest: the RFC 8032 seed gives its public key\n'
    return 0
  fi
  disk_key_of "$file" SETEC_DISK_SIGNING_SEED
}

# disk_key_of FILE MEMBER — print the public key of the disk seed MEMBER, or
# nothing when MEMBER is an empty previous seed.
disk_key_of() {
  local file="$1" name="$2" seed key err
  command -v openssl >/dev/null 2>&1 || die "openssl is not on PATH"
  [ -r "$file" ] || die "cannot read $file"
  if ! seed="$(envfile_get "$file" "$name")" || [ -z "$seed" ]; then
    is_optional "$name" && return 0
    die "$file has no $name member. Generate a new keyring: a keyring from before D85 has no disk seed"
  fi
  err="$(shape_error "$(member_spec "$name")" "$seed")"
  [ -z "$err" ] || die "member $name $err"
  key="$(ed25519_public_key "$seed")"
  [ "${#key}" -eq 44 ] || die "openssl could not derive the ed25519 public key of $name"
  printf '%s\n' "$key"
}

# cmd_disk_public_keys FILE — the keys each launcher accepts: the key of the
# seed, then the key of the previous seed while a rotation keeps one.
cmd_disk_public_keys() {
  local file="${1:?usage: keyring.sh disk-public-keys <keyring-file>}"
  disk_key_of "$file" SETEC_DISK_SIGNING_SEED
  disk_key_of "$file" SETEC_DISK_SIGNING_SEED_PREVIOUS
}

case "${1:-}" in
  generate)     shift; cmd_generate "$@" ;;
  fingerprints) shift; cmd_fingerprints "$@" ;;
  verify)       shift; cmd_verify "$@" ;;
  get)          shift; cmd_get "$@" ;;
  set)          shift; cmd_set "$@" ;;
  rotate)       shift; cmd_rotate "$@" ;;
  retire)       shift; cmd_retire "$@" ;;
  disk-public-key) shift; cmd_disk_public_key "$@" ;;
  disk-public-keys) shift; cmd_disk_public_keys "$@" ;;
  *) die "usage: keyring.sh generate|fingerprints|verify|get|set|rotate|retire|disk-public-key|disk-public-keys ..." ;;
esac
