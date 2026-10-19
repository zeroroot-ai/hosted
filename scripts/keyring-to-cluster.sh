#!/usr/bin/env bash
# keyring-to-cluster.sh — write the bringup keyring into the cluster (ADR-0083).
#
# The ONE producer of the in-cluster keyring Secrets. `make recreate` owns
# this step (deploy#1737); scripts/baseline-up.sh calls the same script for an
# install on a cluster the operator brought. The interim producers this
# replaces are deleted: bootstrap/kind/gibson/keyring.tf and the inline server-side
# apply blocks baseline-up.sh carried (deploy#1730, deploy#1731, deploy#1732,
# deploy#1734).
#
# What it writes, from the keyring file substrate.env names:
#
#   Secret <NS>/bringup-keyring          bucket-access-key, bucket-secret-key,
#                                        openbao-seal-key, openbao-seal-previous-key,
#                                        velero-repo-password,
#                                        ghcr-pull-token, smtp-username,
#                                        smtp-password, stripe-secret-key,
#                                        stripe-publishable-key,
#                                        stripe-webhook-secret,
#                                        setec-disk-signing-seed
#   Secret <NS>/route53-credential       access-key-id, secret-access-key: the
#                                        Route53 credential cert-manager (DNS-01)
#                                        and external-dns read (keyring members
#                                        DNS_ACCESS_KEY, DNS_SECRET_KEY; empty
#                                        on kind)
#   Secret <NS>/setec-disk-push-credential  access-key-id, secret-access-key:
#                                        the push credential of the setec disk
#                                        builder (keyring members
#                                        SETEC_DISK_PUSH_ACCESS_KEY,
#                                        SETEC_DISK_PUSH_SECRET_KEY; empty on
#                                        kind, whose registry needs none)
#   Secret argocd/zeroroot-ai-creds      GitHub App repo-creds for Argo's clone
#                                        of every zeroroot-ai repo. Written only
#                                        when GITHUB_APP_* are in the environment
#                                        (EKS); kind sets none and syncs Argo
#                                        from the bucket.
#   Secret velero/velero-repo-credentials    key repository-password. The name
#                                        and the key are fixed by Velero
#                                        (pkg/repository/keys/keys.go).
#   Secret velero/velero-bucket-credential   key cloud, an AWS shared-credentials
#                                        file built from the bucket members.
#
# Server-side apply, one field manager per producer concern, so the members
# never overwrite each other and a future producer of one member owns exactly
# that member. Empty seed inputs are written empty: that is the documented
# "not supplied" value, and the openbao-auto-init sidecar seeds the key empty
# so the ExternalSecret resolves and the platform starts.
#
# EVERY data value below is QUOTED. `base64 -w0` of an empty member prints an
# empty string, and an unquoted empty YAML scalar is `null`, not "". The API
# server refuses that outright — `unknown object type "nil" in
# Secret.data.<key>` — so the documented "not supplied" value was the one
# value this script could not write (measured live on staging, deploy#1746:
# the staging keyring carries an empty GHCR_PULL_TOKEN).
# A new member added here must be quoted too, and
# tests/harness/keyring-to-cluster.bats fails when one is not.
#
# Usage: keyring-to-cluster.sh <substrate.env>
# Env:   NS            release namespace (default gibson)
#        KEYRING_FILE  override the keyring path substrate.env names
set -euo pipefail

SUBSTRATE_ENV="${1:-}"
[ -n "$SUBSTRATE_ENV" ] || { echo "usage: keyring-to-cluster.sh <substrate.env>" >&2; exit 2; }
[ -s "$SUBSTRATE_ENV" ] || { echo "FATAL: no substrate.env at ${SUBSTRATE_ENV}. Run make substrate ENV=<env> first (ADR-0083)." >&2; exit 2; }
NS="${NS:-gibson}"

log() { printf '\033[1;32m▶\033[0m %s\n' "$*"; }

# A key that is not in substrate.env yields the empty string. Without the
# `|| true` grep exits 1, `pipefail` carries that out of the pipeline, and
# under `set -e` an ABSENT OPTIONAL key kills the script with no message at
# all. Every key read here before the GitHub App was required, so the trap
# was dormant.
substrate_get() { grep -E "^$1=" "$SUBSTRATE_ENV" | head -n1 | cut -d= -f2- || true; }
BUCKET_ENDPOINT="$(substrate_get BUCKET_ENDPOINT)"
BUCKET_NAME="$(substrate_get BUCKET_NAME)"
KEYRING_FILE="${KEYRING_FILE:-$(substrate_get KEYRING_FILE)}"
[ -n "$BUCKET_ENDPOINT" ] && [ -n "$BUCKET_NAME" ] && [ -s "$KEYRING_FILE" ] \
  || { echo "FATAL: ${SUBSTRATE_ENV} is missing BUCKET_ENDPOINT, BUCKET_NAME or a readable KEYRING_FILE" >&2; exit 2; }
keyring_get() { grep -E "^$1=" "$KEYRING_FILE" | head -n1 | cut -d= -f2- || true; }

BUCKET_ACCESS_KEY="$(keyring_get BUCKET_ACCESS_KEY)"
BUCKET_SECRET_KEY="$(keyring_get BUCKET_SECRET_KEY)"
[ -n "$BUCKET_ACCESS_KEY" ] && [ -n "$BUCKET_SECRET_KEY" ] \
  || { echo "FATAL: ${KEYRING_FILE} has no BUCKET_ACCESS_KEY / BUCKET_SECRET_KEY member" >&2; exit 1; }

# The OpenBao seal member (deploy#1731). OpenBao runs the static seal and the
# chart mounts exactly this key from the bringup-keyring Secret. A store
# started under any other key comes up sealed and stays sealed.
OPENBAO_SEAL_KEY="$(keyring_get OPENBAO_SEAL_KEY)"
[ "${#OPENBAO_SEAL_KEY}" -eq 44 ] \
  || { echo "FATAL: ${KEYRING_FILE} has no 44-character OPENBAO_SEAL_KEY member (base64 of 32 bytes); rotate the keyring (docs/runbooks/substrate-kind.md)" >&2; exit 1; }
# The previous seal key during a rotation (scripts/keyring.sh rotate), empty
# otherwise. The chart always mounts the key, so it is always written.
OPENBAO_SEAL_KEY_PREVIOUS="$(keyring_get OPENBAO_SEAL_KEY_PREVIOUS)"
[ -z "$OPENBAO_SEAL_KEY_PREVIOUS" ] || [ "${#OPENBAO_SEAL_KEY_PREVIOUS}" -eq 44 ] \
  || { echo "FATAL: ${KEYRING_FILE} has an OPENBAO_SEAL_KEY_PREVIOUS member that is not 44 characters (base64 of 32 bytes)" >&2; exit 1; }

# The Velero repository password (deploy#1734). Velero seals its kopia
# repository with it. Velero's Role carries no create on secrets, so a
# missing Secret stops the server instead of letting it seal the repository
# with its built-in default.
VELERO_REPO_PASSWORD="$(keyring_get VELERO_REPO_PASSWORD)"
[ "${#VELERO_REPO_PASSWORD}" -eq 44 ] \
  || { echo "FATAL: ${KEYRING_FILE} has no 44-character VELERO_REPO_PASSWORD member (base64 of 32 bytes); rotate the keyring (docs/runbooks/substrate-kind.md)" >&2; exit 1; }

log "keyring ${KEYRING_FILE} (sha256:$(sha256sum < "$KEYRING_FILE" | cut -c1-16)) -> Secret ${NS}/bringup-keyring"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# The two bucket members, under their own field manager.
kubectl apply --server-side --field-manager=bringup-bucket-credential -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: bringup-keyring
  namespace: ${NS}
data:
  bucket-access-key: "$(printf '%s' "$BUCKET_ACCESS_KEY" | base64 -w0)"
  bucket-secret-key: "$(printf '%s' "$BUCKET_SECRET_KEY" | base64 -w0)"
YAML

log "OpenBao seal key -> Secret ${NS}/bringup-keyring key openbao-seal-key (sha256:$(printf '%s' "$OPENBAO_SEAL_KEY" | sha256sum | cut -c1-16))"
if [ -n "$OPENBAO_SEAL_KEY_PREVIOUS" ]; then
  log "previous OpenBao seal key -> key openbao-seal-previous-key (sha256:$(printf '%s' "$OPENBAO_SEAL_KEY_PREVIOUS" | sha256sum | cut -c1-16)); a rotation runs"
fi
kubectl apply --server-side --field-manager=bringup-openbao-seal -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: bringup-keyring
  namespace: ${NS}
data:
  openbao-seal-key: "$(printf '%s' "$OPENBAO_SEAL_KEY" | base64 -w0)"
  openbao-seal-previous-key: "$(printf '%s' "$OPENBAO_SEAL_KEY_PREVIOUS" | base64 -w0)"
YAML

# The setec disk signing seed (D85, hosted#521, ADR-0166). The chart seeds it
# into OpenBao at secret/data/setec-disk-signing, and the setec disk builder
# signs each disk with it. A keyring without it is a keyring from before D85:
# the chart cannot sign a disk, and each launcher refuses every disk.
SETEC_DISK_SIGNING_SEED="$(keyring_get SETEC_DISK_SIGNING_SEED)"
[ "${#SETEC_DISK_SIGNING_SEED}" -eq 44 ] \
  || { echo "FATAL: ${KEYRING_FILE} has no 44-character SETEC_DISK_SIGNING_SEED member (base64 of 32 bytes); generate a new keyring with scripts/keyring.sh generate" >&2; exit 1; }
log "setec disk signing seed -> Secret ${NS}/bringup-keyring key setec-disk-signing-seed (sha256:$(printf '%s' "$SETEC_DISK_SIGNING_SEED" | sha256sum | cut -c1-16))"
kubectl apply --server-side --field-manager=bringup-setec-disk-signing -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: bringup-keyring
  namespace: ${NS}
data:
  setec-disk-signing-seed: "$(printf '%s' "$SETEC_DISK_SIGNING_SEED" | base64 -w0)"
YAML
SETEC_DISK_SIGNING_SEED=""

# The two seed inputs (deploy#1732), each value allowed to be empty.
GHCR_PULL_TOKEN_VALUE="$(keyring_get GHCR_PULL_TOKEN)"
if [ -n "$GHCR_PULL_TOKEN_VALUE" ]; then
  log "GHCR pull token -> Secret ${NS}/bringup-keyring key ghcr-pull-token (sha256:$(printf '%s' "$GHCR_PULL_TOKEN_VALUE" | sha256sum | cut -c1-16))"
else
  log "keyring member GHCR_PULL_TOKEN is empty; first-party images will not pull until printf '%s\\n' \"\$token\" | make baseline-set-secret KEY=ghcr-pull-secret PROP=pat"
fi
kubectl apply --server-side --field-manager=bringup-seed-inputs -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: bringup-keyring
  namespace: ${NS}
data:
  ghcr-pull-token: "$(printf '%s' "$GHCR_PULL_TOKEN_VALUE" | base64 -w0)"
YAML
GHCR_PULL_TOKEN_VALUE=""

# The SMTP relay credential: the user from substrate.env, the password from
# the keyring. Two more seed inputs, so the openbao-auto-init sidecar seeds
# `ses-smtp-credentials` (username, password) and the daemon and the
# dashboard read one relay credential through their ExternalSecrets.
SMTP_USER_VALUE="$(substrate_get SMTP_USER || true)"
SMTP_PASSWORD_VALUE="$(keyring_get SMTP_PASSWORD)"
if [ -n "$SMTP_USER_VALUE" ] && [ -n "$SMTP_PASSWORD_VALUE" ]; then
  log "SMTP relay credential (user ${SMTP_USER_VALUE}) -> Secret ${NS}/bringup-keyring keys smtp-username, smtp-password"
else
  log "substrate.env names no SMTP_USER or the keyring has no SMTP_PASSWORD; ses-smtp-credentials is seeded empty and no mail leaves the platform"
fi
kubectl apply --server-side --field-manager=bringup-smtp-inputs -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: bringup-keyring
  namespace: ${NS}
data:
  smtp-username: "$(printf '%s' "$SMTP_USER_VALUE" | base64 -w0)"
  smtp-password: "$(printf '%s' "$SMTP_PASSWORD_VALUE" | base64 -w0)"
YAML
SMTP_USER_VALUE=""; SMTP_PASSWORD_VALUE=""

# The Stripe account of the environment (hosted#450): three more seed
# inputs. The openbao-auto-init sidecar copies each non-empty one into the
# OpenBao key gibson-stripe-credentials (secret_key, publishable_key,
# webhook_secret), so a rebuild keeps them. An empty member is written empty:
# the sidecar then keeps the chart's test-mode placeholder for that property,
# and preflight has already failed an environment that bills.
STRIPE_SECRET_KEY_VALUE="$(keyring_get STRIPE_SECRET_KEY)"
STRIPE_PUBLISHABLE_KEY_VALUE="$(keyring_get STRIPE_PUBLISHABLE_KEY)"
STRIPE_WEBHOOK_SECRET_VALUE="$(keyring_get STRIPE_WEBHOOK_SECRET)"
if [ -n "$STRIPE_SECRET_KEY_VALUE" ] && [ -n "$STRIPE_PUBLISHABLE_KEY_VALUE" ] && [ -n "$STRIPE_WEBHOOK_SECRET_VALUE" ]; then
  log "Stripe account (secret key sha256:$(printf '%s' "$STRIPE_SECRET_KEY_VALUE" | sha256sum | cut -c1-16)) -> Secret ${NS}/bringup-keyring keys stripe-secret-key, stripe-publishable-key, stripe-webhook-secret"
else
  log "the keyring has no complete Stripe account; gibson-stripe-credentials keeps the chart's placeholder for each member not supplied"
fi
kubectl apply --server-side --field-manager=bringup-stripe-inputs -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: bringup-keyring
  namespace: ${NS}
data:
  stripe-secret-key: "$(printf '%s' "$STRIPE_SECRET_KEY_VALUE" | base64 -w0)"
  stripe-publishable-key: "$(printf '%s' "$STRIPE_PUBLISHABLE_KEY_VALUE" | base64 -w0)"
  stripe-webhook-secret: "$(printf '%s' "$STRIPE_WEBHOOK_SECRET_VALUE" | base64 -w0)"
YAML
STRIPE_SECRET_KEY_VALUE=""; STRIPE_PUBLISHABLE_KEY_VALUE=""; STRIPE_WEBHOOK_SECRET_VALUE=""

# The time each vendor value was set (keyring.sh records KEYRING_SET_AT_<MEMBER>),
# as one annotation per member on the keyring Secret. The monthly drill fails
# a value older than its lifetime (ADR-0171, row vendor-issued-inputs). A
# member with no recorded time gets no annotation.
set_at_annotations=()
for member in GHCR_PULL_TOKEN GITHUB_APP_PRIVATE_KEY STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY STRIPE_WEBHOOK_SECRET; do
  at="$(keyring_get "KEYRING_SET_AT_${member}")"
  [ -n "$at" ] || continue
  set_at_annotations+=("keyring.zeroroot.ai/set-at.$(printf '%s' "$member" | tr 'A-Z_' 'a-z-')=${at}")
done
if [ "${#set_at_annotations[@]}" -gt 0 ]; then
  kubectl -n "$NS" annotate secret bringup-keyring --overwrite "${set_at_annotations[@]}" >/dev/null
  log "the set times of ${#set_at_annotations[@]} vendor values -> annotations of Secret ${NS}/bringup-keyring"
fi

# The Route53 credential for cert-manager (DNS-01) and external-dns: ONE
# Secret in the release namespace, never a member of bringup-keyring, because
# both operators read it by this name (helm/gibson/values-eks.yaml). Empty
# members mean no credential (kind has no zone): the Secret is still written,
# with empty keys, so a pod that mounts it starts and the render never
# depends on whether stage 0 minted one.
DNS_ACCESS_KEY_VALUE="$(keyring_get DNS_ACCESS_KEY)"
DNS_SECRET_KEY_VALUE="$(keyring_get DNS_SECRET_KEY)"
if [ -n "$DNS_ACCESS_KEY_VALUE" ] && [ -n "$DNS_SECRET_KEY_VALUE" ]; then
  log "Route53 credential (key ${DNS_ACCESS_KEY_VALUE}) -> Secret ${NS}/route53-credential"
else
  log "keyring members DNS_ACCESS_KEY / DNS_SECRET_KEY are empty; ${NS}/route53-credential is written empty (no DNS-01 and no published records)"
fi
kubectl apply --server-side --field-manager=bringup-route53-credential -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: route53-credential
  namespace: ${NS}
data:
  access-key-id: "$(printf '%s' "$DNS_ACCESS_KEY_VALUE" | base64 -w0)"
  secret-access-key: "$(printf '%s' "$DNS_SECRET_KEY_VALUE" | base64 -w0)"
YAML
DNS_ACCESS_KEY_VALUE=""; DNS_SECRET_KEY_VALUE=""

# The push credential of the setec disk builder (D85): ONE Secret in the
# release namespace, the same shape as route53-credential. Empty members mean
# no credential (kind's registry needs none): the Secret is still written,
# with empty keys, so the render never depends on whether stage 0 minted one.
# The chart turns it into the registry Secret of the disk builder
# (zeroroot-ai/charts#574).
SETEC_DISK_PUSH_ACCESS_KEY_VALUE="$(keyring_get SETEC_DISK_PUSH_ACCESS_KEY)"
SETEC_DISK_PUSH_SECRET_KEY_VALUE="$(keyring_get SETEC_DISK_PUSH_SECRET_KEY)"
if [ -n "$SETEC_DISK_PUSH_ACCESS_KEY_VALUE" ] && [ -n "$SETEC_DISK_PUSH_SECRET_KEY_VALUE" ]; then
  log "setec disk push credential (key ${SETEC_DISK_PUSH_ACCESS_KEY_VALUE}) -> Secret ${NS}/setec-disk-push-credential"
else
  log "keyring members SETEC_DISK_PUSH_ACCESS_KEY / SETEC_DISK_PUSH_SECRET_KEY are empty; ${NS}/setec-disk-push-credential is written empty (a registry with no credential, as on kind)"
fi
kubectl apply --server-side --field-manager=bringup-setec-disk-push-credential -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: setec-disk-push-credential
  namespace: ${NS}
data:
  access-key-id: "$(printf '%s' "$SETEC_DISK_PUSH_ACCESS_KEY_VALUE" | base64 -w0)"
  secret-access-key: "$(printf '%s' "$SETEC_DISK_PUSH_SECRET_KEY_VALUE" | base64 -w0)"
YAML
SETEC_DISK_PUSH_ACCESS_KEY_VALUE=""; SETEC_DISK_PUSH_SECRET_KEY_VALUE=""

# The org GitHub App (ADR-0083). On EKS it has ONE consumer: Argo clones
# every https://github.com/zeroroot-ai repo with the native githubApp
# repo-creds below. It is not the image pull credential: an App installation
# token reads public packages only, so the pull credential is the keyring
# member GHCR_PULL_TOKEN above (ADR-0084, amended 2026-09-11).
#
# Where the App creds come from, in order:
#
#   1. the ENVIRONMENT, which is how recreate.yml passes them: GITHUB_APP_ID
#      and GITHUB_APP_INSTALLATION_ID as variables, GITHUB_APP_PRIVATE_KEY as
#      a secret holding the raw PEM.
#   2. the SUBSTRATE, which is how a workstation bringup gets them: the two
#      public ids from substrate.env, the private key from the keyring member
#      GITHUB_APP_PRIVATE_KEY, base64-encoded because this file is one
#      KEY=value line per member and a PEM is not one line.
#
# Reading only the environment is what made a bringup from a clean checkout
# impossible. `make recreate ENV=staging` skipped this block in silence, Argo
# could not clone its own source — "failed to list refs: authentication
# required: Repository not found" — and stage 2 stalled to its cap with one
# Application and an error nobody was reading. Measured 2026-09-14. An
# operator had to know to export three variables that nothing named.
#
# kind supplies neither, so the block is skipped and kind syncs Argo from the
# bucket.
GITHUB_APP_ID_VALUE="${GITHUB_APP_ID:-$(substrate_get GITHUB_APP_ID)}"
GITHUB_APP_INSTALLATION_ID_VALUE="${GITHUB_APP_INSTALLATION_ID:-$(substrate_get GITHUB_APP_INSTALLATION_ID)}"
GITHUB_APP_PRIVATE_KEY_VALUE="${GITHUB_APP_PRIVATE_KEY:-}"
if [ -z "$GITHUB_APP_PRIVATE_KEY_VALUE" ]; then
  # The keyring holds it base64-encoded; the Secret field wants the raw PEM,
  # which is then base64-encoded again below like every other value here.
  GITHUB_APP_PRIVATE_KEY_VALUE="$(keyring_get GITHUB_APP_PRIVATE_KEY | base64 -d 2>/dev/null || true)"
fi
if [ -n "$GITHUB_APP_ID_VALUE" ] && [ -n "$GITHUB_APP_INSTALLATION_ID_VALUE" ] && [ -n "$GITHUB_APP_PRIVATE_KEY_VALUE" ]; then
  log "GitHub App (id ${GITHUB_APP_ID_VALUE}) -> Secret argocd/zeroroot-ai-creds (repo-creds)"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply --server-side --field-manager=bringup-argocd-repo-creds -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: zeroroot-ai-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
data:
  type: "$(printf 'git' | base64 -w0)"
  url: "$(printf '%s' 'https://github.com/zeroroot-ai' | base64 -w0)"
  githubAppID: "$(printf '%s' "$GITHUB_APP_ID_VALUE" | base64 -w0)"
  githubAppInstallationID: "$(printf '%s' "$GITHUB_APP_INSTALLATION_ID_VALUE" | base64 -w0)"
  githubAppPrivateKey: "$(printf '%s' "$GITHUB_APP_PRIVATE_KEY_VALUE" | base64 -w0)"
YAML
else
  log "no GITHUB_APP_* in the environment; skipping Argo repo-creds (kind syncs Argo from the bucket)"
fi
GITHUB_APP_ID_VALUE=""; GITHUB_APP_INSTALLATION_ID_VALUE=""; GITHUB_APP_PRIVATE_KEY_VALUE=""

# The Velero member in the release namespace, so one Secret carries the whole
# keyring, and its two consumers in Velero's own namespace. The velero
# namespace holds exactly these two objects: the velero server reads its
# repository password through a cache restricted to its own namespace, so its
# namespace is a namespace where it can read every Secret
# (helm/gibson-velero/Chart.yaml).
kubectl apply --server-side --field-manager=bringup-velero-keyring -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: bringup-keyring
  namespace: ${NS}
data:
  velero-repo-password: "$(printf '%s' "$VELERO_REPO_PASSWORD" | base64 -w0)"
YAML
log "Velero repository password and bucket credential -> namespace velero"
kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply --server-side --field-manager=bringup-velero-credentials -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: velero-repo-credentials
  namespace: velero
data:
  repository-password: "$(printf '%s' "$VELERO_REPO_PASSWORD" | base64 -w0)"
---
apiVersion: v1
kind: Secret
metadata:
  name: velero-bucket-credential
  namespace: velero
data:
  cloud: "$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$BUCKET_ACCESS_KEY" "$BUCKET_SECRET_KEY" | base64 -w0)"
YAML
log "bringup keyring written: ${NS}/bringup-keyring, ${NS}/route53-credential, ${NS}/setec-disk-push-credential, velero/velero-repo-credentials, velero/velero-bucket-credential"
