#!/usr/bin/env bash
# preflight.sh — the preflight verb (ADR-0083, docs/bringup.md § What preflight proves).
#
# The gate between stage 0 (the substrate bootstrap) and stage 1 (the
# cluster). It reads substrate.env and the keyring file that substrate.env
# names, and NOTHING else: no kubeconfig, no cloud profile, no repo state.
# It proves every line of substrate.env live and prints a checklist:
#
#   1 keyring     every member present, the right length, matching its recorded fingerprint
#   2 bucket      a write with the platform credential reads back, and a delete is denied
#   3 versioning  the bucket has versioning on
#   4 lifecycle   an enabled lifecycle rule exists for backups/, audit/ and tfstate/
#   5 smtp        the relay accepts a TCP connection, EHLO and AUTH with the keyring credential,
#                 over TLS unless the host is localhost, because the daemon's Go
#                 client sends no credential in clear text to another host. kind
#                 has no relay (hosted#126): its substrate.env names no SMTP_HOST,
#                 and the line prints as skipped. Every other env must name one.
#   6 zone        the DNS sub-zone answers NS records from its nameserver
#   7 apex        the apex zone still carries its mail records: MX, SPF and one
#                 DKIM record per selector. Only when substrate.env names an
#                 APEX_ZONE_NAME (AWS envs). kind sets none: its zone is a test
#                 TLD that carries no mail, and the line prints as skipped.
#   8 dns         the DNS credential (keyring DNS_ACCESS_KEY / DNS_SECRET_KEY)
#                 lists the environment's zone by its ZONE_ID. cert-manager's
#                 DNS-01 solver and external-dns are the two readers of that
#                 credential; a keyring without one (kind) prints as skipped.
#   9 argo        the Argo CD GitHub App (substrate.env GITHUB_APP_ID /
#                 GITHUB_APP_INSTALLATION_ID, keyring GITHUB_APP_PRIVATE_KEY)
#                 mints an installation token and reads the gitops repo.
#                 Argo's app-of-apps clones that repo and it is private; a
#                 substrate with no App prints as skipped, which is what kind
#                 does.
#  10 stripe      the keyring's Stripe members (STRIPE_SECRET_KEY,
#                 STRIPE_PUBLISHABLE_KEY, STRIPE_WEBHOOK_SECRET) are all
#                 set, have the right prefixes and one mode, and the secret
#                 key reads the account. Required on an environment that
#                 bills (staging, drill, prod). Elsewhere a keyring with no
#                 Stripe member prints as skipped, and half an account fails.
#  11 ghcr        GHCR grants the keyring's GHCR_PULL_TOKEN pull on the private
#                 first-party package (hosted#601). Check 1 proves only that
#                 the token is present. Required on staging, drill and prod.
#                 Elsewhere a keyring with no token prints as skipped.
#
# It stops at the first miss and names it. A preflight that passes with one
# of these missing is a defect in preflight.
#
# Usage: preflight.sh <substrate.env>        (make preflight ENV=<env> calls it)
#
# Exit codes, the house convention (scripts/lib/cluster-probe.sh):
#   0  every line proved live
#   1  a line failed, named in the output
#   2  could not run (a tool or a substrate.env key is missing). NOT a pass.
#
# Tools: aws (any S3-compatible endpoint), dig, python3 (standard library)
# and openssl, which signs the GitHub App's JWT in check 9. The same four run
# on a workstation and on an ubuntu runner.

set -uo pipefail

ENV_FILE="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYRING="$HERE/keyring.sh"
SMTP_PROBE="$HERE/lib/smtp-auth-probe.py"

# Colour on a terminal only, so a CI log and a bats assertion see plain text.
if [ -t 1 ]; then GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'; else GREEN=''; RED=''; NC=''; fi

n=0
ok()     { n=$((n + 1)); printf '  %s✓%s %d %-11s %s\n' "$GREEN" "$NC" "$n" "$1" "$2"; }
miss()   { n=$((n + 1)); printf '  %s✗%s %d %-11s %s\n' "$RED" "$NC" "$n" "$1" "$2"; printf '%spreflight FAIL%s at %d %s\n' "$RED" "$NC" "$n" "$1"; exit 1; }
cannot() { printf '  %s!%s %s\n' "$RED" "$NC" "$1"; printf '%spreflight could not run%s (NOT a pass)\n' "$RED" "$NC"; exit 2; }
skip()   { n=$((n + 1)); printf '  -   %d %-11s skipped: %s\n' "$n" "$1" "$2"; }

[ -n "$ENV_FILE" ] || cannot "usage: preflight.sh <substrate.env>"
[ -r "$ENV_FILE" ] || cannot "no substrate.env at $ENV_FILE. Run make substrate ENV=<env> first"
for tool in aws dig python3 openssl; do
  command -v "$tool" >/dev/null 2>&1 || cannot "$tool is not on PATH"
done
[ -x "$KEYRING" ] || cannot "$KEYRING is missing"
[ -r "$SMTP_PROBE" ] || cannot "$SMTP_PROBE is missing"

# cfg KEY — set the shell variable KEY to its value in substrate.env. A
# missing or empty key is a could-not-run, because substrate.env is the whole
# input. Assigns in the current shell on purpose: inside `$(...)` the exit
# would end the subshell only and the error text would become the value.
cfg() {
  local line
  line="$(grep -E "^$1=" "$ENV_FILE" | head -n1)" || cannot "substrate.env lacks $1"
  local value="${line#*=}"
  [ -n "$value" ] || cannot "substrate.env has an empty $1"
  printf -v "$1" '%s' "$value"
}

for key in SUBSTRATE_ENV BUCKET_ENDPOINT BUCKET_REGION BUCKET_NAME KEYRING_FILE \
           ZONE_NAME ZONE_NAMESERVER; do
  cfg "$key"
done
# kind has no SMTP relay (hosted#126): the chart's in-cluster sink carries its
# mail. Every other substrate must name its relay, so a missing row there is
# a could-not-run and never a skip.
SMTP_HOST=""
if [ "$SUBSTRATE_ENV" != kind ] || grep -qE '^SMTP_HOST=' "$ENV_FILE"; then
  for key in SMTP_HOST SMTP_PORT SMTP_USER; do
    cfg "$key"
  done
fi

printf 'preflight ENV=%s (%s)\n' "$SUBSTRATE_ENV" "$ENV_FILE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1 keyring
# ---------------------------------------------------------------------------
if out="$("$KEYRING" verify "$KEYRING_FILE" "$ENV_FILE" 2>&1)"; then
  ok keyring "$out"
else
  rc=$?
  [ "$rc" -eq 1 ] || cannot "keyring verify: $out"
  miss keyring "$out"
fi

# ---------------------------------------------------------------------------
# 2 bucket — with the PLATFORM credential, never an admin one. Path-style
# addressing, so an IP endpoint (MinIO on kind) and a hostname endpoint both
# work. No shared credentials file, no profile, no instance metadata: the
# only credential in play is the keyring's.
# ---------------------------------------------------------------------------
printf '[default]\ns3 =\n  addressing_style = path\n' > "$WORK/aws-config"
export AWS_CONFIG_FILE="$WORK/aws-config"
export AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""
export AWS_ENDPOINT_URL="$BUCKET_ENDPOINT"
export AWS_DEFAULT_REGION="$BUCKET_REGION"
AWS_ACCESS_KEY_ID="$("$KEYRING" get "$KEYRING_FILE" BUCKET_ACCESS_KEY)" || cannot "keyring get BUCKET_ACCESS_KEY"
AWS_SECRET_ACCESS_KEY="$("$KEYRING" get "$KEYRING_FILE" BUCKET_SECRET_KEY)" || cannot "keyring get BUCKET_SECRET_KEY"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
unset AWS_PROFILE AWS_SESSION_TOKEN

s3() { aws --cli-connect-timeout 5 --cli-read-timeout 20 s3api "$@"; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
key="preflight/${stamp}-$$-${RANDOM}"
body="preflight ${stamp} ${SUBSTRATE_ENV}"
printf '%s' "$body" > "$WORK/put"
if ! err="$(s3 put-object --bucket "$BUCKET_NAME" --key "$key" --body "$WORK/put" 2>&1 >/dev/null)"; then
  miss bucket "write to s3://$BUCKET_NAME/$key at $BUCKET_ENDPOINT failed: ${err##*$'\n'}"
fi
if ! err="$(s3 get-object --bucket "$BUCKET_NAME" --key "$key" "$WORK/get" 2>&1 >/dev/null)"; then
  miss bucket "read back of s3://$BUCKET_NAME/$key failed: ${err##*$'\n'}"
fi
if [ "$(cat "$WORK/get")" != "$body" ]; then
  miss bucket "s3://$BUCKET_NAME/$key read back different bytes than were written"
fi
if err="$(s3 delete-object --bucket "$BUCKET_NAME" --key "$key" 2>&1 >/dev/null)"; then
  miss bucket "the platform credential DELETED s3://$BUCKET_NAME/$key. It must be denied s3:DeleteObject"
fi
case "$err" in
  *AccessDenied*) ;;
  *) miss bucket "delete of s3://$BUCKET_NAME/$key failed for a reason other than AccessDenied: ${err##*$'\n'}" ;;
esac
ok bucket "wrote and read back s3://$BUCKET_NAME/$key, delete denied for the platform credential"

# ---------------------------------------------------------------------------
# 3 versioning
# ---------------------------------------------------------------------------
if ! status="$(s3 get-bucket-versioning --bucket "$BUCKET_NAME" --query Status --output text 2>&1)"; then
  miss versioning "get-bucket-versioning on $BUCKET_NAME failed: ${status##*$'\n'}"
fi
[ "$status" = "Enabled" ] || miss versioning "bucket $BUCKET_NAME versioning is '${status}', want Enabled"
ok versioning "Enabled on $BUCKET_NAME"

# ---------------------------------------------------------------------------
# 4 lifecycle — one enabled rule per required prefix. A rule may carry the
# prefix as Filter.Prefix (current S3) or as Prefix (legacy), so both columns
# are read and the absent one prints as None.
# ---------------------------------------------------------------------------
if ! prefixes="$(s3 get-bucket-lifecycle-configuration --bucket "$BUCKET_NAME" \
      --query "Rules[?Status=='Enabled'].[Filter.Prefix, Prefix]" --output text 2>&1)"; then
  miss lifecycle "bucket $BUCKET_NAME has no lifecycle configuration: ${prefixes##*$'\n'}"
fi
for want in backups/ audit/ tfstate/; do
  if ! printf '%s\n' "$prefixes" | tr '\t' '\n' | grep -qx "$want"; then
    miss lifecycle "bucket $BUCKET_NAME has no enabled lifecycle rule for prefix $want"
  fi
done
ok lifecycle "enabled rules for backups/ audit/ tfstate/ on $BUCKET_NAME"

# ---------------------------------------------------------------------------
# 5 smtp
# ---------------------------------------------------------------------------
if [ -z "$SMTP_HOST" ]; then
  skip smtp "kind has no SMTP relay; the chart's in-cluster Mailpit sink carries its mail (hosted#126)"
else
  smtp_password="$("$KEYRING" get "$KEYRING_FILE" SMTP_PASSWORD)" || cannot "keyring get SMTP_PASSWORD"
  if out="$(printf '%s' "$smtp_password" | python3 "$SMTP_PROBE" "$SMTP_HOST" "$SMTP_PORT" "$SMTP_USER" 2>&1)"; then
    ok smtp "$out"
  else
    rc=$?
    [ "$rc" -eq 1 ] || cannot "smtp probe: $out"
    miss smtp "$out"
  fi
fi

# ---------------------------------------------------------------------------
# 6 zone
# ---------------------------------------------------------------------------
ns="$(dig +short +time=3 +tries=1 "@$ZONE_NAMESERVER" NS "$ZONE_NAME" 2>&1 | grep -E '\.$' || true)"
[ -n "$ns" ] || miss zone "$ZONE_NAME returned no NS records from $ZONE_NAMESERVER"
ok zone "$ZONE_NAME NS $(printf '%s' "$ns" | tr '\n' ' ') via $ZONE_NAMESERVER"

# ---------------------------------------------------------------------------
# 7 apex — the mail records on the apex zone are company property
# (substrate/apex-zone) and stage 1 must not start without them: signup mail is
# sent as the apex domain. Asked of the apex's own nameserver, so no resolver
# cache can answer for a record that is gone. A DKIM selector may be a TXT
# record (Google Workspace) or a CNAME to the relay's key (SES Easy DKIM); a
# TXT query returns either, and an empty answer is the miss.
# ---------------------------------------------------------------------------
if grep -qE '^APEX_ZONE_NAME=' "$ENV_FILE"; then
  cfg APEX_ZONE_NAME
  cfg APEX_ZONE_NAMESERVER
  cfg APEX_DKIM_SELECTORS
  apex_dig() { dig +short +time=3 +tries=1 "@$APEX_ZONE_NAMESERVER" "$1" "$2" 2>&1; }
  mx="$(apex_dig MX "$APEX_ZONE_NAME" | grep -E '\.$' || true)"
  [ -n "$mx" ] || miss apex "$APEX_ZONE_NAME has no MX record at $APEX_ZONE_NAMESERVER. Company mail is gone, see substrate/apex-zone"
  spf="$(apex_dig TXT "$APEX_ZONE_NAME" | grep -F 'v=spf1' || true)"
  [ -n "$spf" ] || miss apex "$APEX_ZONE_NAME has no SPF record (v=spf1) at $APEX_ZONE_NAMESERVER"
  for sel in ${APEX_DKIM_SELECTORS//,/ }; do
    dkim="$(apex_dig TXT "${sel}._domainkey.$APEX_ZONE_NAME" | grep -E 'DKIM1|\.$' || true)"
    [ -n "$dkim" ] || miss apex "$APEX_ZONE_NAME has no DKIM record for selector $sel at $APEX_ZONE_NAMESERVER"
  done
  ok apex "$APEX_ZONE_NAME carries MX, SPF and DKIM ($APEX_DKIM_SELECTORS) via $APEX_ZONE_NAMESERVER"
else
  skip apex "substrate.env names no APEX_ZONE_NAME (a kind zone carries no mail)"
fi

# ---------------------------------------------------------------------------
# 8 dns — the DNS credential, with the DNS credential and never the bucket
# one. A read of the zone proves the key pair is live and scoped to this
# zone; the writes (ChangeResourceRecordSets) are cert-manager's and
# external-dns's to make. Skipped, and said so, when the keyring carries no
# credential: kind has no zone.
#
# AWS_ENDPOINT_URL is UNSET for this call. The bucket checks export it as
# the bucket endpoint (path-style S3, MinIO on kind), and the CLI applies
# it to EVERY service: a Route53 call with it set lands on the S3 endpoint,
# which answers "InvalidRequest: Missing required header for this request:
# x-amz-content-sha256" (measured on staging 2026-09-10, the first run of
# this check). Route53 has one endpoint and it is the CLI's own.
#
# --max-items is deliberately ABSENT. It is the CLI's OWN paginator, not a
# Route53 parameter: when it truncates, the CLI prints the query result and
# then a second line carrying the next token, which here is the literal
# `None`. That line landed in preflight's output between check 8 and PASS,
# as a bare `None` nobody could source. The query already takes one name.
# ---------------------------------------------------------------------------
dns_access_key="$("$KEYRING" get "$KEYRING_FILE" DNS_ACCESS_KEY)" || cannot "keyring get DNS_ACCESS_KEY"
dns_secret_key="$("$KEYRING" get "$KEYRING_FILE" DNS_SECRET_KEY)" || cannot "keyring get DNS_SECRET_KEY"
if [ -n "$dns_access_key" ] && [ -n "$dns_secret_key" ]; then
  cfg ZONE_ID
  if out="$(env -u AWS_ENDPOINT_URL AWS_ACCESS_KEY_ID="$dns_access_key" AWS_SECRET_ACCESS_KEY="$dns_secret_key" AWS_SESSION_TOKEN="" aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" --query 'ResourceRecordSets[0].Name' --output text 2>&1)"; then
    ok dns "credential $dns_access_key lists zone $ZONE_NAME ($ZONE_ID), first record $out"
  else
    miss dns "credential $dns_access_key cannot list zone $ZONE_NAME ($ZONE_ID): ${out##*$'\n'}"
  fi
else
  skip dns "the keyring carries no DNS credential (kind has no zone; on AWS, run make substrate ENV=<env> to mint one)"
fi
dns_access_key=""; dns_secret_key=""

# ---------------------------------------------------------------------------
# 9 argo — the Argo CD GitHub App reads the gitops repo.
#
# Argo CD's app-of-apps clones GITOPS_REPO, which is private. Without a
# working credential the clone fails with "failed to list refs: authentication
# required: Repository not found" and the bringup shows it as stage 2 stalling
# to its cap with ONE Application: forty minutes spent, nothing converged, and
# an error nobody is reading. Measured on the 2026-09-14 staging bringup,
# where the cause was three environment variables that nothing named.
#
# The two ids are PUBLIC and come from substrate.env. The private key is a
# secret and comes from the keyring, base64-encoded because the keyring is one
# KEY=value line per member and a PEM is not one line. A substrate with no App
# is skipped and says so: kind's Argo syncs from the bucket.
# ---------------------------------------------------------------------------
GITOPS_REPO="${GITOPS_REPO:-zeroroot-ai/hosted}"
# cfg() is for REQUIRED keys: it stops the run when one is absent. These three
# are optional as a group, so they are read directly.
optional_cfg() { grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true; }
app_id="$(optional_cfg GITHUB_APP_ID)"
app_install="$(optional_cfg GITHUB_APP_INSTALLATION_ID)"
app_key_b64="$("$KEYRING" get "$KEYRING_FILE" GITHUB_APP_PRIVATE_KEY 2>/dev/null || true)"
if [ -n "$app_id" ] || [ -n "$app_install" ] || [ -n "$app_key_b64" ]; then
  # Any one of the three present means this environment MEANS to use an App,
  # so a missing other one is an error and never a skip. Half a credential is
  # the shape that reads as "configured" and fails at clone time.
  [ -n "$app_id" ]      || miss argo "substrate.env carries no GITHUB_APP_ID, but the App is otherwise configured. Record it in substrate/gibson-bootstrap/envs/<env>.tfvars and re-run make substrate"
  [ -n "$app_install" ] || miss argo "substrate.env carries no GITHUB_APP_INSTALLATION_ID, but the App is otherwise configured. Record it in substrate/gibson-bootstrap/envs/<env>.tfvars and re-run make substrate"
  [ -n "$app_key_b64" ] || miss argo "the keyring carries no GITHUB_APP_PRIVATE_KEY, but the App is otherwise configured. Run: scripts/keyring.sh set ${KEYRING_FILE} GITHUB_APP_PRIVATE_KEY \"\$(base64 -w0 < <app>.pem)\""
  app_pem="$(mktemp)"
  chmod 0600 "$app_pem"
  printf '%s' "$app_key_b64" | base64 -d > "$app_pem" 2>/dev/null \
    || { rm -f "$app_pem"; miss argo "the keyring's GITHUB_APP_PRIVATE_KEY is not base64. Its value is the PEM, base64-encoded: base64 -w0 < <app>.pem"; }
  # The probe is resolved through a variable so the harness can point at a
  # fake GitHub. Every other caller gets the real one.
  GITHUB_APP_PROBE="${GITHUB_APP_PROBE:-$HERE/lib/github-app-probe.py}"
  if out="$(python3 "$GITHUB_APP_PROBE" "$app_id" "$app_install" "$app_pem" "$GITOPS_REPO" 2>&1)"; then
    rm -f "$app_pem"
    ok argo "$out"
  else
    rm -f "$app_pem"
    miss argo "the Argo CD GitHub App cannot read ${GITOPS_REPO}: ${out##*$'\n'}"
  fi
  app_key_b64=""
else
  skip argo "substrate.env names no GitHub App (kind's Argo syncs from the bucket, not from a private repo)"
fi

# ---------------------------------------------------------------------------
# 10 stripe — the Stripe account of the environment (hosted#450).
#
# The bringup copies the three keyring members into OpenBao
# (gibson-stripe-credentials). A member that is not supplied leaves the
# chart's test-mode placeholder there, the bringup finishes, and each paid
# signup stops at the card step: "Invalid API Key provided:
# sk_test_*******lder". Measured on staging on 2026-10-05. So an environment
# that bills must carry all three, and the secret key must work.
# ---------------------------------------------------------------------------
stripe_sk="$("$KEYRING" get "$KEYRING_FILE" STRIPE_SECRET_KEY 2>/dev/null || true)"
stripe_pk="$("$KEYRING" get "$KEYRING_FILE" STRIPE_PUBLISHABLE_KEY 2>/dev/null || true)"
stripe_wh="$("$KEYRING" get "$KEYRING_FILE" STRIPE_WEBHOOK_SECRET 2>/dev/null || true)"
case "$SUBSTRATE_ENV" in
  staging|drill|prod) stripe_required=1 ;;
  *) stripe_required=0 ;;
esac
stripe_set_hint="scripts/keyring.sh set ${KEYRING_FILE} <MEMBER> <value>, then make substrate ENV=${SUBSTRATE_ENV}"
if [ "$stripe_required" = 1 ] || [ -n "$stripe_sk" ] || [ -n "$stripe_pk" ] || [ -n "$stripe_wh" ]; then
  [ -n "$stripe_sk" ] || miss stripe "the keyring carries no STRIPE_SECRET_KEY, so gibson-stripe-credentials keeps the chart's placeholder and no paid signup can finish. Run: ${stripe_set_hint}"
  [ -n "$stripe_pk" ] || miss stripe "the keyring carries no STRIPE_PUBLISHABLE_KEY, so gibson-stripe-credentials keeps the chart's placeholder. Run: ${stripe_set_hint}"
  [ -n "$stripe_wh" ] || miss stripe "the keyring carries no STRIPE_WEBHOOK_SECRET, so gibson-stripe-credentials keeps the chart's placeholder. Run: ${stripe_set_hint}"
  case "$stripe_sk" in
    sk_test_*|rk_test_*) stripe_mode="test" ;;
    sk_live_*|rk_live_*) stripe_mode="live" ;;
    *) miss stripe "the keyring's STRIPE_SECRET_KEY does not start with sk_test_, sk_live_, rk_test_ or rk_live_" ;;
  esac
  case "$stripe_pk" in
    "pk_${stripe_mode}_"*) ;;
    *) miss stripe "the keyring's STRIPE_PUBLISHABLE_KEY is not a pk_${stripe_mode}_ key, so it does not match the ${stripe_mode} secret key" ;;
  esac
  case "$stripe_wh" in
    whsec_*) ;;
    *) miss stripe "the keyring's STRIPE_WEBHOOK_SECRET does not start with whsec_" ;;
  esac
  case "$stripe_sk$stripe_pk$stripe_wh" in
    *placeholder*) miss stripe "a Stripe member of the keyring is the chart's placeholder, not a key of the account" ;;
  esac
  # The probe is resolved through a variable so the harness can point at a
  # fake Stripe. Every other caller gets the real one.
  STRIPE_KEY_PROBE="${STRIPE_KEY_PROBE:-$HERE/lib/stripe-key-probe.py}"
  if out="$(STRIPE_SECRET_KEY="$stripe_sk" python3 "$STRIPE_KEY_PROBE" 2>&1)"; then
    ok stripe "$out"
  else
    miss stripe "Stripe refused the keyring's STRIPE_SECRET_KEY: ${out##*$'\n'}"
  fi
else
  skip stripe "the keyring carries no Stripe account (${SUBSTRATE_ENV} does not bill)"
fi
stripe_sk=""; stripe_pk=""; stripe_wh=""

# ---------------------------------------------------------------------------
# 11 ghcr — the image pull token works (hosted#601).
#
# A revoked GHCR_PULL_TOKEN passed check 1 on 2026-10-11, and the staging
# recreate and the drill stopped at the image copy with a 403 from GHCR. The
# cluster pulls the private images with the same token. So preflight asks
# GHCR for pull with it before the bringup starts.
# ---------------------------------------------------------------------------
ghcr_token="$("$KEYRING" get "$KEYRING_FILE" GHCR_PULL_TOKEN 2>/dev/null || true)"
case "$SUBSTRATE_ENV" in
  staging|drill|prod) ghcr_required=1 ;;
  *) ghcr_required=0 ;;
esac
ghcr_set_hint="make a new classic token with read:packages for the machine user (docs/bringup-inputs.md step 3), then scripts/keyring.sh set ${KEYRING_FILE} GHCR_PULL_TOKEN <token> and make substrate ENV=${SUBSTRATE_ENV}"
if [ -n "$ghcr_token" ]; then
  # Resolved through a variable so the harness can point at a fake GHCR.
  GHCR_PULL_PROBE="${GHCR_PULL_PROBE:-$HERE/lib/ghcr-pull-probe.py}"
  if out="$(GHCR_PULL_TOKEN="$ghcr_token" python3 "$GHCR_PULL_PROBE" 2>&1)"; then
    ok ghcr "$out"
  else
    miss ghcr "GHCR refused the keyring's GHCR_PULL_TOKEN (${out##*$'\n'}). The token is revoked, expired or has no Read on the package. Fix: ${ghcr_set_hint}"
  fi
elif [ "$ghcr_required" = 1 ]; then
  miss ghcr "the keyring carries no GHCR_PULL_TOKEN, so no private first-party image can be pulled. Fix: ${ghcr_set_hint}"
else
  skip ghcr "the keyring carries no GHCR_PULL_TOKEN (${SUBSTRATE_ENV} pulls no private image)"
fi
ghcr_token=""

printf '%spreflight PASS%s ENV=%s\n' "$GREEN" "$NC" "$SUBSTRATE_ENV"
