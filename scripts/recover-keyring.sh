#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# recover-keyring.sh — rebuild the keyring of an environment from the cluster
# and write it to the GitHub environment (ADR-0083, amendment of 2026-10-21).
#
#   scripts/recover-keyring.sh <staging|prod> [--accept-changed MEMBER]... [--empty MEMBER]...
#
# Use it when the write-back of rotate-credentials.yml failed, or the runner
# died, after the cluster got the new keyring. The environment secret
# BRINGUP_KEYRING then holds an older keyring than the cluster. The command:
#
#   1. reads the keyring Secrets of the cluster (scripts/with-cluster.sh for
#      staging, `make eks-kubeconfig` for prod) and rebuilds each member
#      (scripts/keyring-to-cluster.sh writes them);
#   2. stops, and names each member, that the cluster cannot give: a member that
#      the cluster does not store (VELERO_REPO_PASSWORD_PREVIOUS and
#      SETEC_DISK_SIGNING_SEED_PREVIOUS), a Secret that is missing, or a
#      required member with no value. --empty MEMBER says that such a member is
#      empty in the keyring (only a previous value or an input member may be);
#   3. checks the fingerprint of each member against substrate.env, read from
#      the environment variable SUBSTRATE_ENV_FILE. A member that differs is
#      named, and the command stops. A rotation changes a member on purpose, so
#      --accept-changed MEMBER says that this change is the one to keep;
#   4. writes substrate.env again with the new fingerprints, and writes
#      BRINGUP_KEYRING and SUBSTRATE_ENV_FILE with scripts/keyring-writeback.sh,
#      the code that the workflow uses, under the gh login of the person.
#
# Then run the workflow again.
#
# Env: NS (release namespace, default gibson), GITHUB_REPOSITORY, and for tests
#      WITH_CLUSTER, KEYRING, WRITEBACK, GH.
# Exit: 0 written, 2 stopped (nothing was written)
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
KEYRING="${KEYRING:-$HERE/keyring.sh}"
WITH_CLUSTER="${WITH_CLUSTER:-$HERE/with-cluster.sh}"
WRITEBACK="${WRITEBACK:-$HERE/keyring-writeback.sh}"
GH="${GH:-gh}"
NS="${NS:-gibson}"
REPO_SLUG="${GITHUB_REPOSITORY:-zeroroot-ai/hosted}"

die() { printf '! [recover-keyring] %s\n' "$*" >&2; exit 2; }
say() { printf '  ✓ [recover-keyring] %s\n' "$*"; }

# member | namespace | secret | key | how
#   plain  the value is the decoded Secret key
#   b64    the member holds the base64 of the Secret key (the PEM of the GitHub App)
# An empty value is "not supplied" for these input members and previous values.
SOURCES=(
  "OPENBAO_SEAL_KEY|$NS|bringup-keyring|openbao-seal-key|plain"
  "OPENBAO_SEAL_KEY_PREVIOUS|$NS|bringup-keyring|openbao-seal-previous-key|plain"
  "VELERO_REPO_PASSWORD|velero|velero-repo-credentials|repository-password|plain"
  "BUCKET_ACCESS_KEY|$NS|bringup-keyring|bucket-access-key|plain"
  "BUCKET_SECRET_KEY|$NS|bringup-keyring|bucket-secret-key|plain"
  "SMTP_PASSWORD|$NS|bringup-keyring|smtp-password|plain"
  "SETEC_DISK_SIGNING_SEED|$NS|bringup-keyring|setec-disk-signing-seed|plain"
  "GHCR_PULL_TOKEN|$NS|bringup-keyring|ghcr-pull-token|plain"
  "DNS_ACCESS_KEY|$NS|route53-credential|access-key-id|plain"
  "DNS_SECRET_KEY|$NS|route53-credential|secret-access-key|plain"
  "GITHUB_APP_PRIVATE_KEY|argocd|zeroroot-ai-creds|githubAppPrivateKey|b64"
  "STRIPE_SECRET_KEY|$NS|bringup-keyring|stripe-secret-key|plain"
  "STRIPE_PUBLISHABLE_KEY|$NS|bringup-keyring|stripe-publishable-key|plain"
  "STRIPE_WEBHOOK_SECRET|$NS|bringup-keyring|stripe-webhook-secret|plain"
  "SETEC_DISK_PUSH_ACCESS_KEY|$NS|setec-disk-push-credential|access-key-id|plain"
  "SETEC_DISK_PUSH_SECRET_KEY|$NS|setec-disk-push-credential|secret-access-key|plain"
)
# The members that the cluster does not store.
NOT_IN_CLUSTER="VELERO_REPO_PASSWORD_PREVIOUS SETEC_DISK_SIGNING_SEED_PREVIOUS"
VENDOR_MEMBERS="GHCR_PULL_TOKEN GITHUB_APP_PRIVATE_KEY STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY STRIPE_WEBHOOK_SECRET"

# ---- the half that runs where kubectl reaches the cluster -------------------
# --from-cluster <out-dir>: write <out-dir>/found.env (MEMBER=value, one line
# for each member whose Secret key exists) and <out-dir>/missing (a line
# `MEMBER reason` for each member whose Secret or key does not exist), and the
# set times of the vendor values as KEYRING_SET_AT_<MEMBER> lines in found.env.
if [ "${1:-}" = "--from-cluster" ]; then
  out="${2:?usage: --from-cluster <out-dir>}"
  umask 077
  : > "$out/found.env"; : > "$out/missing"
  declare -A cache=()
  for src in "${SOURCES[@]}"; do
    IFS='|' read -r member ns secret key how <<<"$src"
    ck="$ns/$secret"
    if [ -z "${cache[$ck]+x}" ]; then
      cache[$ck]="$(kubectl -n "$ns" get secret "$secret" -o json 2>/dev/null || true)"
    fi
    json="${cache[$ck]}"
    if [ -z "$json" ]; then echo "$member the Secret $ns/$secret does not exist" >> "$out/missing"; continue; fi
    if ! jq -e --arg k "$key" '.data | has($k)' <<<"$json" >/dev/null 2>&1; then
      echo "$member the Secret $ns/$secret has no key $key" >> "$out/missing"; continue
    fi
    value="$(jq -r --arg k "$key" '.data[$k]' <<<"$json" | base64 -d)"
    [ "$how" != b64 ] || value="$(printf '%s' "$value" | base64 -w0)"
    printf '%s=%s\n' "$member" "$value" >> "$out/found.env"
  done
  json="${cache[$NS/bringup-keyring]:-}"
  if [ -n "$json" ]; then
    for member in $VENDOR_MEMBERS; do
      at="$(jq -r --arg k "keyring.zeroroot.ai/set-at.$(printf '%s' "$member" | tr 'A-Z_' 'a-z-')" '.metadata.annotations[$k] // empty' <<<"$json")"
      [ -z "$at" ] || printf 'KEYRING_SET_AT_%s=%s\n' "$member" "$at" >> "$out/found.env"
    done
  fi
  exit 0
fi

# ---- the half that decides ---------------------------------------------------
ENV="${1:-}"; shift || true
ACCEPT=""; EMPTY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --accept-changed) ACCEPT="$ACCEPT ${2:?--accept-changed needs a member}"; shift 2 ;;
    --empty)          EMPTY="$EMPTY ${2:?--empty needs a member}"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
case "$ENV" in staging|prod) ;; *) die "usage: recover-keyring.sh <staging|prod> [--accept-changed MEMBER]... [--empty MEMBER]..." ;; esac
for tool in kubectl jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"; done

WORK="$(umask 077 && mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 0700 "$WORK"

# 1. Read the cluster.
case "$ENV" in
  staging) "$WITH_CLUSTER" staging "$HERE/recover-keyring.sh" --from-cluster "$WORK" ;;
  prod)    ( cd "$REPO" && make eks-kubeconfig ENV=prod >/dev/null ) \
             && KUBECONFIG="/tmp/eks-prod.kubeconfig" "$HERE/recover-keyring.sh" --from-cluster "$WORK" ;;
esac || die "could not read the keyring Secrets of the cluster of $ENV"
[ -f "$WORK/found.env" ] || die "the cluster read gave no result"

# 2. Rebuild each member, and name each one the cluster cannot give.
cannot=()
KR="$WORK/keyring.env"
: > "$KR"; chmod 0600 "$KR"
for src in "${SOURCES[@]}"; do
  member="${src%%|*}"
  if grep -q "^${member}=" "$WORK/found.env"; then
    grep "^${member}=" "$WORK/found.env" | head -n1 >> "$KR"
  else
    reason="$(grep "^${member} " "$WORK/missing" | head -n1 | cut -d' ' -f2-)"
    case " $EMPTY " in
      *" $member "*) printf '%s=\n' "$member" >> "$KR" ;;
      *) cannot+=("$member (${reason:-not read})") ;;
    esac
  fi
done
for member in $NOT_IN_CLUSTER; do
  case " $EMPTY " in
    *" $member "*) printf '%s=\n' "$member" >> "$KR" ;;
    *) cannot+=("$member (the cluster does not store it)") ;;
  esac
done
if [ "${#cannot[@]}" -gt 0 ]; then
  printf '! [recover-keyring] the cluster cannot give these members:\n' >&2
  printf '    %s\n' "${cannot[@]}" >&2
  die "Stopped, and wrote nothing. If a previous value is empty in the keyring, run again with --empty <MEMBER> for it. Anything else must come from the person who holds the keyring"
fi
grep '^KEYRING_SET_AT_' "$WORK/found.env" >> "$KR" || true

# The shape of each member (length, kind). A required member with no value
# stops here, by name.
if ! fp="$("$KEYRING" fingerprints "$KR" 2>&1)"; then
  die "the rebuilt keyring is not a keyring: ${fp}. Stopped, and wrote nothing"
fi

# 3. The fingerprint of each member against substrate.env of the environment.
"$GH" variable get SUBSTRATE_ENV_FILE --env "$ENV" --repo "$REPO_SLUG" > "$WORK/substrate.env.read" 2>/dev/null \
  || die "could not read the environment variable SUBSTRATE_ENV_FILE of $ENV with gh"
changed=()
while IFS= read -r line; do
  case "$line" in KEYRING_FINGERPRINT_*=*) ;; *) continue ;; esac
  name="${line%%=*}"; member="${name#KEYRING_FINGERPRINT_}"
  want="$(grep -E "^${name}=" "$WORK/substrate.env.read" | head -n1 | cut -d= -f2- || true)"
  [ "${line#*=}" = "$want" ] || changed+=("$member")
done <<<"$fp"
unaccepted=()
for member in "${changed[@]}"; do
  case " $ACCEPT " in *" $member "*) ;; *) unaccepted+=("$member") ;; esac
done
if [ "${#unaccepted[@]}" -gt 0 ]; then
  printf '! [recover-keyring] these members do not match the fingerprint in substrate.env:\n' >&2
  printf '    %s\n' "${unaccepted[@]}" >&2
  rerun="scripts/recover-keyring.sh ${ENV}"
  for m in "${unaccepted[@]}"; do rerun="$rerun --accept-changed $m"; done
  die "The cluster holds a different value for each of them. If the rotation changed them, run: ${rerun}. Stopped, and wrote nothing"
fi

# 4. substrate.env with the new fingerprints, then the one write-back code.
{
  grep -vE '^(KEYRING_FINGERPRINT|KEYRING_FILE)' "$WORK/substrate.env.read" || true
  printf 'KEYRING_FILE=%s\n' "$KR"
  printf '%s\n' "$fp"
} > "$WORK/substrate.env"
GITHUB_REPOSITORY="$REPO_SLUG" GH="$GH" "$WRITEBACK" "$WORK" "$ENV"
say "BRINGUP_KEYRING of ${ENV} is rebuilt from the cluster (${#changed[@]} member(s) changed since substrate.env). Run the rotate-credentials workflow again"
