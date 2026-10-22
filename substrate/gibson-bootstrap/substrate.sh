#!/usr/bin/env bash
# substrate.sh — stage 0, the substrate bootstrap, for an AWS environment
# (ADR-0083, docs/bringup.md, deploy#1742).
#
# The one entry point for this workspace. `make substrate ENV=<env>` calls it
# with the environment's state directory and name, and it:
#
#   1. inits this workspace on its state in the durable bucket, under
#      tfstate/stage0/ (backend.tf, scripts/stage0-store.sh),
#   2. plans envs/<env>.tfvars and REFUSES a plan that deletes anything.
#      Stage 0 outlives every cluster; no path through it destroys,
#   3. applies the plan: the durable bucket, the platform and SMTP
#      credentials, the DNS sub-zone and its delegation, the setec disk
#      registry and its push credential,
#   4. writes the bringup keyring once, from three Terraform outputs (the
#      bucket credential and the SMTP password) plus two generated randoms
#      (scripts/keyring.sh generate with a provided file),
#   5. writes substrate.env, the one artifact stage 1 may read.
#
# Files under <state-dir> (SUBSTRATE_DIR/<env>, default /bulk/substrate/<env>):
#
#   terraform.tfstate   only for the first apply of a new environment, until
#                       the bucket exists. The state holds the access keys
#   key-slots.tfvars.json  the active access key slot of each substrate
#                       user (ADR-0171). substrate.sh writes the default once;
#                       scripts/substrate-rotate.sh changes it
#   keyring.env         the bringup keyring, mode 0600
#   substrate.env       endpoints, names, fingerprints. No secrets
#
# Idempotent: a second run plans nothing, keeps the keyring, and rewrites
# substrate.env with the same values. A keyring that no longer matches the
# platform credential in state is an error, never silently replaced. The
# access keys rotate with scripts/substrate-rotate.sh (ADR-0171).
#
# Usage: substrate.sh <state-dir> <env>
set -euo pipefail

STATE="${1:-}"
ENV="${2:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
KEYRING="$REPO/scripts/keyring.sh"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
say()  { printf '%s  ✓%s [substrate] %s\n' "$GREEN" "$NC" "$*"; }
step() { printf '%s▶%s [substrate] %s\n' "$GREEN" "$NC" "$*"; }
die()  { printf '%s!%s [substrate] %s\n' "$RED" "$NC" "$*" >&2; exit 2; }

[ -n "$STATE" ] && [ -n "$ENV" ] || die "usage: substrate.sh <state-dir> <env>"
case "$ENV" in staging|prod|drill) ;; *) die "ENV=$ENV is not an AWS environment of this workspace (staging, prod, drill)" ;; esac
VARFILE="envs/$ENV.tfvars"
[ -r "$HERE/$VARFILE" ] || die "$HERE/$VARFILE is missing"
for tool in terraform aws python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done
[ -x "$KEYRING" ] || die "$KEYRING is missing"

umask 077
mkdir -p "$STATE"
chmod 0700 "$STATE"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

tf() { terraform -chdir="$HERE" "$@"; }

# The test inbox (inbox.tf) adds a rule to the ONE active SES receipt rule set
# of the account, which substrate/apex-zone owns (hosted#647). Without it the
# plan fails on a data source with a provider message; this says what to do.
step "the active SES receipt rule set (owned by substrate/apex-zone)"
active_set="$(aws ses describe-active-receipt-rule-set --region "${AWS_REGION:-us-east-1}" \
    --query 'Metadata.Name' --output text 2>/dev/null || true)"
case "$active_set" in
  ''|None) die "the account has no active SES receipt rule set. Apply substrate/apex-zone first: it owns the one rule set, and this stage adds its inbox rule to it (hosted#647)" ;;
esac
say "active rule set ${active_set}"

# ---------------------------------------------------------------------------
# Terraform: init on the env's local state, plan, refuse deletes, apply.
# ---------------------------------------------------------------------------
# The stage 0 state, the key slots and the rotation record live in the
# durable bucket under tfstate/stage0/ (scripts/stage0-store.sh, ADR-0083). A
# new environment has no bucket yet: its first apply uses a local state file,
# and stage0_migrate moves it into the bucket after the apply.
# shellcheck source=../../scripts/stage0-store.sh
. "$REPO/scripts/stage0-store.sh"
step "terraform init (state in s3://zeroroot-ai-$ENV-durable-<account>/tfstate/stage0/)"
stage0_pull "$ENV" "$STATE"
stage0_init "$HERE" "$ENV" "$STATE"
say "initialized"

# The access key slots (variables.tf key_slots). Written once with the
# default, then changed only by scripts/substrate-rotate.sh in its workflow.
SLOTS="$STATE/key-slots.tfvars.json"
if [ ! -f "$SLOTS" ]; then
  printf '%s\n' '{"key_slots": {"platform": {"active": "a", "keep": ["a"]}, "smtp": {"active": "a", "keep": ["a"]}, "dns": {"active": "a", "keep": ["a"]}, "setec-disk-builder": {"active": "a", "keep": ["a"]}}}' > "$SLOTS"
  say "wrote the default access key slots to $SLOTS"
fi
# A slot file from before a user existed gets that user with the default,
# and no slot of a user it already names changes.
python3 - "$SLOTS" <<'PYSLOTS'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
added = [u for u in ("platform", "smtp", "dns", "setec-disk-builder") if u not in d["key_slots"]]
for u in added:
    d["key_slots"][u] = {"active": "a", "keep": ["a"]}
if added:
    json.dump(d, open(p, "w"))
    print("  added the default key slots of " + ", ".join(added))
PYSLOTS

step "terraform plan $VARFILE"
tf plan -input=false -no-color -var-file="$VARFILE" -var-file="$SLOTS" -out="$WORK/plan.out" | grep -E '^(Plan:|No changes)' || true
tf show -json "$WORK/plan.out" > "$WORK/plan.json"
deletes="$(python3 -c '
import json, sys
plan = json.load(open(sys.argv[1]))
for rc in plan.get("resource_changes", []):
    if "delete" in rc["change"]["actions"]:
        print(rc["address"])' "$WORK/plan.json")"
# The rule set of the account is substrate/apex-zone's (hosted#647).
python3 "$REPO/scripts/check-ses-rule-set-owner.py" --plan "$WORK/plan.json" \
  || die "the stage 0 plan changes the SES receipt rule set of the account. Only substrate/apex-zone changes it"
if [ -n "$deletes" ]; then
  printf '%s\n' "$deletes" >&2
  die "the plan deletes or replaces the resources above. Stage 0 outlives every cluster and never deletes; an access key rotation deletes its old key through scripts/substrate-rotate.sh. Read the plan by hand: terraform -chdir=$HERE plan -var-file=$VARFILE -var-file=$SLOTS"
fi

step "terraform apply"
tf apply -input=false -no-color "$WORK/plan.out" | grep -E '^(Apply complete|aws_[a-z0-9_]+\.[a-z0-9_\[\]"]+: (Creating|Creation complete|Modifying|Modifications complete))' || true
say "applied"
stage0_migrate "$HERE" "$ENV" "$STATE"

out()      { tf output -raw "$1"; }
out_list() { tf output -json "$1" | python3 -c 'import json, sys; print(",".join(json.load(sys.stdin)))'; }

BUCKET_NAME="$(out bucket_name)"
BUCKET_REGION="$(out bucket_region)"
BUCKET_ENDPOINT="$(out bucket_endpoint)"
SMTP_HOST="$(out smtp_host)"
SMTP_PORT="$(out smtp_port)"
SMTP_USER="$(out smtp_user)"
ZONE_NAME="$(out zone_name)"
ZONE_ID="$(out zone_id)"
ZONE_NAMESERVER="$(out zone_nameserver)"
APEX_ZONE_NAME="$(out apex_zone_name)"
APEX_ZONE_NAMESERVER="$(out apex_zone_nameserver)"
APEX_DKIM_SELECTORS="$(out_list apex_dkim_selectors)"
GITHUB_APP_ID="$(out argocd_github_app_id)"
GITHUB_APP_INSTALLATION_ID="$(out argocd_github_app_installation_id)"
SETEC_DISK_REPO="$(out setec_disk_repo)"
BELIEF_TRAINER_REPO="$(out belief_trainer_repo)"
INBOX_DOMAIN="$(out inbox_domain)"
INBOX_BUCKET="$(out inbox_bucket)"
EDGE_CERT_SECRET="$(out edge_cert_secret)"

# ---------------------------------------------------------------------------
# Keyring. Written once. The three members the substrate issues come from
# Terraform outputs through a provided file that lives only in $WORK. The
# DNS credential is an input member: `set` after generate, so a keyring
# written before stage 0 minted one gains it on the next run and nothing
# else in the keyring changes (a rotation is still a new keyring).
# ---------------------------------------------------------------------------
step "keyring"
if [ -f "$STATE/keyring.env" ]; then
  have="$("$KEYRING" get "$STATE/keyring.env" BUCKET_ACCESS_KEY)"
  want="$(out platform_access_key_id)"
  [ "$have" = "$want" ] || die "$STATE/keyring.env holds BUCKET_ACCESS_KEY $have but the platform user's key is $want. The keyring and the state disagree. Rotation is a new keyring: see README.md § Rotation"
  have="$("$KEYRING" get "$STATE/keyring.env" SMTP_PASSWORD)"
  [ "$have" = "$(out smtp_password)" ] || die "$STATE/keyring.env holds an SMTP_PASSWORD that is not the relay credential in state. See README.md § Rotation"
  say "keyring present at $STATE/keyring.env and matches the state"
else
  {
    printf 'BUCKET_ACCESS_KEY=%s\n' "$(out platform_access_key_id)"
    printf 'BUCKET_SECRET_KEY=%s\n' "$(out platform_secret_access_key)"
    printf 'SMTP_PASSWORD=%s\n' "$(out smtp_password)"
  } > "$WORK/provided"
  "$KEYRING" generate "$STATE/keyring.env" "$WORK/provided"
fi
# The setec disk builder push credential (D85, ecr.tf) is an input member
# for the same reason as the DNS credential.
for member in DNS_ACCESS_KEY:dns_access_key_id DNS_SECRET_KEY:dns_secret_access_key \
              SETEC_DISK_PUSH_ACCESS_KEY:setec_disk_builder_access_key_id \
              SETEC_DISK_PUSH_SECRET_KEY:setec_disk_builder_secret_access_key; do
  name="${member%%:*}"; want="$(out "${member#*:}")"
  have="$("$KEYRING" get "$STATE/keyring.env" "$name")"
  [ "$have" = "$want" ] || "$KEYRING" set "$STATE/keyring.env" "$name" "$want" >/dev/null
done
say "DNS credential $(out dns_access_key_id) and disk push credential $(out setec_disk_builder_access_key_id) in the keyring"

# ---------------------------------------------------------------------------
# substrate.env: the one artifact stage 1 may read. No secrets. Atomic write.
# ---------------------------------------------------------------------------
step "substrate.env"
fingerprints="$("$KEYRING" fingerprints "$STATE/keyring.env")"
{
  printf '# substrate.env for ENV=%s, stage 0 of ADR-0083. Written %s by substrate/gibson-bootstrap/substrate.sh.\n' "$ENV" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# No secrets here. preflight reads this file and KEYRING_FILE, nothing else.\n'
  printf 'SUBSTRATE_ENV=%s\n' "$ENV"
  printf 'BUCKET_ENDPOINT=%s\n' "$BUCKET_ENDPOINT"
  printf 'BUCKET_REGION=%s\n' "$BUCKET_REGION"
  printf 'BUCKET_NAME=%s\n' "$BUCKET_NAME"
  printf 'KEYRING_FILE=%s\n' "$STATE/keyring.env"
  printf '%s\n' "$fingerprints"
  printf 'SMTP_HOST=%s\n' "$SMTP_HOST"
  printf 'SMTP_PORT=%s\n' "$SMTP_PORT"
  printf 'SMTP_USER=%s\n' "$SMTP_USER"
  printf 'ZONE_NAME=%s\n' "$ZONE_NAME"
  printf 'ZONE_ID=%s\n' "$ZONE_ID"
  printf 'ZONE_NAMESERVER=%s\n' "$ZONE_NAMESERVER"
  printf 'APEX_ZONE_NAME=%s\n' "$APEX_ZONE_NAME"
  printf 'APEX_ZONE_NAMESERVER=%s\n' "$APEX_ZONE_NAMESERVER"
  printf 'APEX_DKIM_SELECTORS=%s\n' "$APEX_DKIM_SELECTORS"
  # The Argo CD GitHub App's two PUBLIC ids. Its private key is a secret and
  # stays in the keyring. Both are written even when empty, so preflight can
  # tell "this env needs no App" from "somebody forgot".
  printf 'GITHUB_APP_ID=%s\n' "$GITHUB_APP_ID"
  printf 'GITHUB_APP_INSTALLATION_ID=%s\n' "$GITHUB_APP_INSTALLATION_ID"
  # The repository of the signed setec sandbox disks (D85, ecr.tf). The env
  # overlay names the same URL as setec.launcher.diskRepo, and
  # scripts/check-overlay-disk-repo.py proves the two agree.
  printf 'SETEC_DISK_REPO=%s\n' "$SETEC_DISK_REPO"
  # The repository of the belief trainer image copy (gibson#31, ecr.tf).
  # scripts/belief-trainer-image.sh copies the image that the overlay pins
  # into it, and scripts/check-overlay-belief-trainer.py proves the overlay
  # names it.
  printf 'BELIEF_TRAINER_REPO=%s\n' "$BELIEF_TRAINER_REPO"
  # The test inbox (hosted#647, inbox.tf). The signup driver signs up as
  # <slug>@INBOX_DOMAIN and reads the mail from INBOX_BUCKET.
  printf 'INBOX_DOMAIN=%s\n' "$INBOX_DOMAIN"
  printf 'INBOX_BUCKET=%s\n' "$INBOX_BUCKET"
  # The edge TLS certificate kept across recreates (edge-cert.tf,
  # scripts/lib/edge-cert.sh).
  printf 'EDGE_CERT_SECRET=%s\n' "$EDGE_CERT_SECRET"
} > "$WORK/substrate.env"
chmod 0644 "$WORK/substrate.env"
mv "$WORK/substrate.env" "$STATE/substrate.env"
say "wrote $STATE/substrate.env"
stage0_push "$ENV" "$STATE"
say "kept the key slots of $ENV in the durable bucket, and the keyring and substrate.env in the secret $(out keyring_secret)"

printf '    bucket   %s/%s\n' "$BUCKET_ENDPOINT" "$BUCKET_NAME"
printf '    smtp     %s:%s as %s\n' "$SMTP_HOST" "$SMTP_PORT" "$SMTP_USER"
printf '    zone     %s (%s) at %s\n' "$ZONE_NAME" "$ZONE_ID" "$ZONE_NAMESERVER"
printf '    apex     %s at %s, DKIM %s\n' "$APEX_ZONE_NAME" "$APEX_ZONE_NAMESERVER" "$APEX_DKIM_SELECTORS"
printf '    disks    %s\n' "$SETEC_DISK_REPO"
printf '    trainer  %s\n' "$BELIEF_TRAINER_REPO"
printf '    inbox    %s -> s3://%s\n' "$INBOX_DOMAIN" "$INBOX_BUCKET"
printf '    edge tls %s\n' "$EDGE_CERT_SECRET"
printf '    argo app %s (installation %s)\n' "${GITHUB_APP_ID:-<none>}" "${GITHUB_APP_INSTALLATION_ID:-<none>}"
printf '    keyring  %s\n' "$STATE/keyring.env"
printf '    next     make preflight ENV=%s\n' "$ENV"
