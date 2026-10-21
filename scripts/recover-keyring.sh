#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# recover-keyring.sh — rebuild the keyring of an environment from the cluster
# (ADR-0083, amendment of 2026-10-21). It runs in the workflow
# rotate-credentials.yml with `step: recover`, under the same environment
# approval, and nowhere else.
#
#   scripts/recover-keyring.sh <staging|prod> <state-dir> [--accept-changed MEMBER]... [--empty MEMBER]...
#
# Use it when the write-back of the workflow failed, or the runner died, after
# the cluster got the new keyring. The environment secret BRINGUP_KEYRING then
# holds an older keyring than the cluster. The workflow has read that old
# keyring and substrate.env into <state-dir> (keyring.env and substrate.env).
# The command:
#
#   1. reads the keyring Secrets of the cluster (scripts/with-cluster.sh for
#      staging, `make eks-kubeconfig` for prod) and rebuilds each member
#      (scripts/keyring-to-cluster.sh writes them);
#   2. takes the two previous values that the cluster does not store from the
#      old keyring. VELERO_REPO_PASSWORD_PREVIOUS and
#      SETEC_DISK_SIGNING_SEED_PREVIOUS keep the old repository and the old disks
#      readable.
#        - when the current value of the cluster differs from the old keyring
#          (a rotation is open), the previous value is the old current value;
#        - when both agree, the previous value is the old previous value;
#        - --empty MEMBER on one of them is refused when that would erase a
#          non-empty old value;
#   3. stops, and names each member, that the cluster cannot give: a Secret that
#      is missing, or a required member with no value. --empty MEMBER says that
#      a previous or input member is empty;
#   4. checks the fingerprint of each member against the old substrate.env. A
#      member that differs is named, and the command stops. A rotation changes a
#      member on purpose, so --accept-changed MEMBER says that this change is the
#      one to keep. It is refused on a previous member, because it would erase the
#      old value;
#   5. writes keyring.env and substrate.env (new fingerprints) into <state-dir>
#      and creates the marker .cluster-keyring-pushed. The workflow then writes
#      BRINGUP_KEYRING and SUBSTRATE_ENV_FILE with scripts/keyring-writeback.sh,
#      the one write-back code.
#
# Env: NS (release namespace, default gibson), and for tests WITH_CLUSTER, KEYRING.
# Exit: 0 rebuilt, 2 stopped (nothing was changed)
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
KEYRING="${KEYRING:-$HERE/keyring.sh}"
WITH_CLUSTER="${WITH_CLUSTER:-$HERE/with-cluster.sh}"
NS="${NS:-gibson}"

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
# The members that the cluster does not store, each with the member it follows.
NOT_IN_CLUSTER="VELERO_REPO_PASSWORD_PREVIOUS SETEC_DISK_SIGNING_SEED_PREVIOUS"
previous_of() { case "$1" in VELERO_REPO_PASSWORD_PREVIOUS) echo VELERO_REPO_PASSWORD ;; SETEC_DISK_SIGNING_SEED_PREVIOUS) echo SETEC_DISK_SIGNING_SEED ;; esac; }
is_stored_nowhere() { case " $NOT_IN_CLUSTER " in *" $1 "*) return 0 ;; esac; return 1; }
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
    if ! printf '%s' "$json" | jq -e --arg k "$key" '.data | has($k)' >/dev/null 2>&1; then
      echo "$member the Secret $ns/$secret has no key $key" >> "$out/missing"; continue
    fi
    value="$(printf '%s' "$json" | jq -r --arg k "$key" '.data[$k]' | base64 -d)"
    [ "$how" != b64 ] || value="$(printf '%s' "$value" | base64 -w0)"
    printf '%s=%s\n' "$member" "$value" >> "$out/found.env"
  done
  json="${cache[$NS/bringup-keyring]:-}"
  if [ -n "$json" ]; then
    for member in $VENDOR_MEMBERS; do
      at="$(printf '%s' "$json" | jq -r --arg k "keyring.zeroroot.ai/set-at.$(printf '%s' "$member" | tr 'A-Z_' 'a-z-')" '.metadata.annotations[$k] // empty')"
      [ -z "$at" ] || printf 'KEYRING_SET_AT_%s=%s\n' "$member" "$at" >> "$out/found.env"
    done
  fi
  exit 0
fi

# ---- the half that decides ---------------------------------------------------
ENV="${1:-}"; STATE="${2:-}"; shift 2 || true
ACCEPT=""; EMPTY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --accept-changed) ACCEPT="$ACCEPT ${2:?--accept-changed needs a member}"; shift 2 ;;
    --empty)          EMPTY="$EMPTY ${2:?--empty needs a member}"; shift 2 ;;
    *) die "unknown argument $1" ;;
  esac
done
case "$ENV" in staging|prod) ;; *) die "usage: recover-keyring.sh <staging|prod> <state-dir> [--accept-changed MEMBER]... [--empty MEMBER]..." ;; esac
[ -s "$STATE/keyring.env" ] && [ -s "$STATE/substrate.env" ] \
  || die "$STATE holds no keyring.env or substrate.env: the workflow reads them from the environment first"
for tool in kubectl jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"; done

WORK="$(umask 077 && mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 0700 "$WORK"
OLD="$STATE/keyring.env"

# 1. Read the cluster.
case "$ENV" in
  staging) "$WITH_CLUSTER" staging "$HERE/recover-keyring.sh" --from-cluster "$WORK" ;;
  prod)    ( cd "$REPO" && make eks-kubeconfig ENV=prod >/dev/null ) \
             && KUBECONFIG="/tmp/eks-prod.kubeconfig" "$HERE/recover-keyring.sh" --from-cluster "$WORK" ;;
esac || die "could not read the keyring Secrets of the cluster of $ENV"
[ -f "$WORK/found.env" ] || die "the cluster read gave no result"

# 2 and 3. Rebuild each member, and name each one the cluster cannot give.
cannot=()
KR="$WORK/keyring.env"
: > "$KR"; chmod 0600 "$KR"
kr_get() { { grep -E "^$2=" "$1" || true; } | head -n1 | cut -d= -f2-; }
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
# The two previous values that the cluster does not store come from the old
# keyring, by the rule in the header.
derived=()
for member in $NOT_IN_CLUSTER; do
  cur="$(previous_of "$member")"
  old_cur="$(kr_get "$OLD" "$cur")"; old_prev="$(kr_get "$OLD" "$member")"
  new_cur="$(kr_get "$KR" "$cur")"
  want_empty=""; case " $EMPTY " in *" $member "*) want_empty=yes ;; esac
  if [ -n "$new_cur" ] && [ "$new_cur" != "$old_cur" ]; then
    # A rotation is open: the old current value is the previous value.
    [ -z "$old_prev" ] || { cannot+=("$member (the old keyring holds a previous value and a rotation is open, so the cluster cannot say which is right)"); continue; }
    [ -z "$want_empty" ] || { cannot+=("$member (--empty would erase the old value of $cur, which the old backups need)"); continue; }
    printf '%s=%s\n' "$member" "$old_cur" >> "$KR"
  else
    if [ -n "$want_empty" ] && [ -n "$old_prev" ]; then
      cannot+=("$member (--empty would erase the non-empty old value; use the retire step when the old one is no longer needed)"); continue
    fi
    printf '%s=%s\n' "$member" "$old_prev" >> "$KR"
  fi
  derived+=("$member")
done
if [ "${#cannot[@]}" -gt 0 ]; then
  printf '! [recover-keyring] the cluster cannot give these members:\n' >&2
  printf '    %s\n' "${cannot[@]}" >&2
  die "Stopped, and changed nothing. If a previous or input member is empty in the keyring, run again with --empty <MEMBER> for it. Anything else must come from the person who holds the keyring"
fi
grep '^KEYRING_SET_AT_' "$WORK/found.env" >> "$KR" || true

# The shape of each member (length, kind). A required member with no value
# stops here, by name.
if ! fp="$("$KEYRING" fingerprints "$KR" 2>&1)"; then
  die "the rebuilt keyring is not a keyring: ${fp}. Stopped, and changed nothing"
fi

# 4. The fingerprint of each member against the old substrate.env.
changed=()
while IFS= read -r line; do
  case "$line" in KEYRING_FINGERPRINT_*=*) ;; *) continue ;; esac
  name="${line%%=*}"; member="${name#KEYRING_FINGERPRINT_}"
  want="$({ grep -E "^${name}=" "$STATE/substrate.env" || true; } | head -n1 | cut -d= -f2-)"
  [ "${line#*=}" = "$want" ] || changed+=("$member")
done <<<"$fp"
unaccepted=(); refused=()
for member in "${changed[@]}"; do
  if is_stored_nowhere "$member"; then
    # It follows its current member: the change is accepted with that one.
    case " $ACCEPT " in *" $member "*) refused+=("$member") ;; esac
    case " $ACCEPT " in *" $(previous_of "$member") "*) ;; *) unaccepted+=("$member") ;; esac
  else
    case " $ACCEPT " in *" $member "*) ;; *) unaccepted+=("$member") ;; esac
  fi
done
if [ "${#refused[@]}" -gt 0 ]; then
  die "--accept-changed on ${refused[*]} is refused: it would erase the old value that the old backups or disks need. A previous value follows its current member. Stopped, and changed nothing"
fi
if [ "${#unaccepted[@]}" -gt 0 ]; then
  printf '! [recover-keyring] these members do not match the fingerprint in substrate.env:\n' >&2
  printf '    %s\n' "${unaccepted[@]}" >&2
  rerun=""
  for m in "${unaccepted[@]}"; do
    if is_stored_nowhere "$m"; then
      echo "    ${m} follows $(previous_of "$m"): accept the change of $(previous_of "$m"). --accept-changed on ${m} itself erases the old value, so it is refused" >&2
    else
      rerun="$rerun --accept-changed $m"
    fi
  done
  if [ -n "$rerun" ]; then
    die "The cluster holds a different value for each of them. If the rotation changed them, run the workflow again with step recover and the accepted members:${rerun}. Stopped, and changed nothing"
  fi
  die "Stopped, and changed nothing"
fi

# 5. keyring.env and substrate.env with the new fingerprints, and the marker.
{
  grep -vE '^(KEYRING_FINGERPRINT|KEYRING_FILE)' "$STATE/substrate.env" || true
  printf 'KEYRING_FILE=%s\n' "$STATE/keyring.env"
  printf '%s\n' "$fp"
} > "$WORK/substrate.env"
cp "$KR" "$STATE/keyring.env"; chmod 0600 "$STATE/keyring.env"
cp "$WORK/substrate.env" "$STATE/substrate.env"
# shellcheck source=lib/keyring-pushed.sh
. "$HERE/lib/keyring-pushed.sh"
: > "$STATE/$PUSHED_MARKER"
say "the keyring of ${ENV} is rebuilt from the cluster (${#changed[@]} member(s) changed since substrate.env; previous values taken from the old keyring: ${derived[*]:-none}). The workflow writes it to the environment"
