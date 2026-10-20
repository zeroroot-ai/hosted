#!/usr/bin/env bats
#
# keyring-to-cluster.bats — the ONE producer of the in-cluster keyring writes
# an EMPTY member as an empty string, not as null (deploy#1746).
#
# WHY THIS SUITE EXISTS
# ---------------------
# `scripts/keyring-to-cluster.sh` documents empty seed inputs as the
# "not supplied" value: the openbao-auto-init sidecar seeds the key empty so
# the ExternalSecret resolves and the platform starts. `base64 -w0` of an
# empty member prints an empty string, and an unquoted empty YAML scalar is
# `null`. The API server refuses that outright:
#
#   error validating data: unknown object type "nil" in Secret.data.ghcr-pull-token
#
# So the documented value was the one value this script could not write. It
# was measured live on staging, whose keyring carries an empty
# GHCR_PULL_TOKEN — kind's does not, which is why kind never showed it.
#
# HOW IT IS OFFLINE
# ----------------
# `kubectl` is stubbed on PATH and records every manifest applied to it. The
# assertion is on the YAML the script emits, and on the real `kubectl create
# --dry-run=client` validation of it, so a null value fails here exactly as
# it failed on the cluster.
#
# Run:
#   bats tests/harness/keyring-to-cluster.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/keyring-to-cluster.sh"

SEAL_KEY="YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE="
# RFC 8032 test vector 1, the seed of the setec disk signing key (D85).
DISK_SEED="nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A="

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR" "$STATE"
  PATH="$STUB_DIR:$PATH"
  export STATE

  KEYRING="$BATS_TEST_TMPDIR/keyring.env"
  SUBSTRATE="$BATS_TEST_TMPDIR/substrate.env"
  cat > "$SUBSTRATE" <<EOF
SUBSTRATE_ENV=staging
BUCKET_ENDPOINT=https://s3.us-east-1.amazonaws.com
BUCKET_NAME=zeroroot-ai-staging-durable-000000000000
KEYRING_FILE=$KEYRING
SMTP_HOST=email-smtp.us-east-1.amazonaws.com
SMTP_PORT=587
SMTP_USER=AKIASMTPUSERBATS0000
EOF

  cat > "$STUB_DIR/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"apply"*"-f -"*) cat >> "$STATE/applied.yaml"; printf -- '---\n' >> "$STATE/applied.yaml"; exit 0 ;;
  *"annotate"*) echo "$*" >> "$STATE/annotate.log"; exit 0 ;;
  *"create namespace"*) printf 'apiVersion: v1\nkind: Namespace\n'; exit 0 ;;
  *) echo "kubectl stub: undeclared call: $*" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$STUB_DIR/kubectl"
}

# write_keyring <ghcr> [<dns-access-key> <dns-secret-key> [<push-access-key>
# <push-secret-key>]] — the input members. A real staging keyring left the
# token empty; the DNS pair and the disk push pair are empty on kind and set
# on AWS.
write_keyring() {
  cat > "$KEYRING" <<EOF
OPENBAO_SEAL_KEY=$SEAL_KEY
VELERO_REPO_PASSWORD=dmVsZXJvLXJlcG8tcGFzc3dvcmQtZm9yLXRoZS1iYXRz
BUCKET_ACCESS_KEY=AKIAEXAMPLEBATS00000
BUCKET_SECRET_KEY=YnVja2V0LXNlY3JldC1rZXktZm9yLWJhdHMtc3Vp
SMTP_PASSWORD=smtp-password-for-the-bats-suite
SETEC_DISK_SIGNING_SEED=$DISK_SEED
GHCR_PULL_TOKEN=$1
DNS_ACCESS_KEY=${2:-}
DNS_SECRET_KEY=${3:-}
SETEC_DISK_PUSH_ACCESS_KEY=${4:-}
SETEC_DISK_PUSH_SECRET_KEY=${5:-}
EOF
}

# secret_data <namespace> <name> <key> — the decoded value of one key of one
# applied Secret, from the last apply that carried it.
secret_data() {
  python3 - "$STATE/applied.yaml" "$1" "$2" "$3" <<'PY'
import sys, base64, yaml
_, path, ns, name, key = sys.argv
value = None
for doc in yaml.safe_load_all(open(path)):
    if not doc or doc.get("kind") != "Secret":
        continue
    if doc["metadata"].get("namespace") != ns or doc["metadata"]["name"] != name:
        continue
    if key in (doc.get("data") or {}):
        value = doc["data"][key]
if value is None:
    sys.exit("no apply of Secret %s/%s carried key %s" % (ns, name, key))
print(base64.b64decode(value).decode())
PY
}

# every_data_value_is_a_string — the property that matters. A YAML value that
# parses to None is the defect; anything else is fine.
every_data_value_is_a_string() {
  python3 - "$STATE/applied.yaml" <<'PY'
import sys, yaml
bad = []
seen = 0
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc or doc.get("kind") != "Secret":
        continue
    for k, v in (doc.get("data") or {}).items():
        seen += 1
        if v is None:
            bad.append("%s/%s data.%s" % (doc["metadata"]["namespace"], doc["metadata"]["name"], k))
if seen == 0:
    sys.exit("no Secret data value was applied, so this check proves nothing")
if bad:
    sys.exit("Secret data value(s) parsed as null, which the API server refuses\n"
             "with `unknown object type \"nil\"`: %s" % ", ".join(bad))
print("OK  %d Secret data value(s), every one a string" % seen)
PY
}

@test "an empty keyring member is written as an empty string, not null" {
  write_keyring ""
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run every_data_value_is_a_string
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"every one a string"* ]]
}

@test "a keyring with every member set still round-trips" {
  write_keyring "ghp_exampletoken"
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run every_data_value_is_a_string
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q "$(printf '%s' 'ghp_exampletoken' | base64 -w0)" "$STATE/applied.yaml"
}

@test "FAILING FIXTURE: an unquoted empty value is caught as null" {
  # This is the manifest the script emitted before deploy#1746 quoted its
  # values, verbatim in shape. The check must reject it, or it would not have
  # caught the defect that broke the first live staging recreate.
  cat > "$STATE/applied.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: bringup-keyring
  namespace: gibson
data:
  ghcr-pull-token:
  smtp-username:
YAML
  run every_data_value_is_a_string
  [ "$status" -ne 0 ]
  [[ "$output" == *"parsed as null"* ]]
  [[ "$output" == *"ghcr-pull-token"* ]]
}

@test "the SMTP relay credential lands in the keyring Secret as two seed inputs" {
  write_keyring ""
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run secret_data gibson bringup-keyring smtp-username
  [ "$status" -eq 0 ] && [ "$output" = "AKIASMTPUSERBATS0000" ]
  run secret_data gibson bringup-keyring smtp-password
  [ "$status" -eq 0 ] && [ "$output" = "smtp-password-for-the-bats-suite" ]
}

@test "the DNS credential lands in route53-credential when the keyring carries it" {
  write_keyring "" AKIADNSKEYBATS000000 dns-secret-key-for-the-bats-suite
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Route53 credential (key AKIADNSKEYBATS000000) -> Secret gibson/route53-credential"* ]]
  run secret_data gibson route53-credential access-key-id
  [ "$status" -eq 0 ] && [ "$output" = "AKIADNSKEYBATS000000" ]
  run secret_data gibson route53-credential secret-access-key
  [ "$status" -eq 0 ] && [ "$output" = "dns-secret-key-for-the-bats-suite" ]
}

@test "a keyring without the DNS pair (kind, or one written before stage 0 minted it) still writes route53-credential, empty and as strings" {
  write_keyring ""
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"DNS_ACCESS_KEY / DNS_SECRET_KEY are empty"* ]]
  run secret_data gibson route53-credential access-key-id
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run every_data_value_is_a_string
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# The setec disk inputs (D85, hosted#521). The chart seeds the signing seed
# into OpenBao from bringup-keyring, and the disk builder reads its push
# credential from setec-disk-push-credential.
# ---------------------------------------------------------------------------
@test "the setec disk signing seed lands in the keyring Secret" {
  write_keyring ""
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run secret_data gibson bringup-keyring setec-disk-signing-seed
  [ "$status" -eq 0 ] && [ "$output" = "$DISK_SEED" ]
}

@test "FAILING FIXTURE: a keyring from before D85, with no disk signing seed, stops the bringup" {
  write_keyring ""
  sed -i '/^SETEC_DISK_SIGNING_SEED=/d' "$KEYRING"
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no 44-character SETEC_DISK_SIGNING_SEED member"* ]]
}

@test "the disk push credential lands in setec-disk-push-credential when the keyring carries it" {
  write_keyring "" "" "" AKIAPUSHKEYBATS00000 push-secret-key-for-the-bats-suite
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run secret_data gibson setec-disk-push-credential access-key-id
  [ "$status" -eq 0 ] && [ "$output" = "AKIAPUSHKEYBATS00000" ]
  run secret_data gibson setec-disk-push-credential secret-access-key
  [ "$status" -eq 0 ] && [ "$output" = "push-secret-key-for-the-bats-suite" ]
}

@test "a keyring with no disk push pair (kind) writes setec-disk-push-credential empty and as strings" {
  write_keyring ""
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"setec-disk-push-credential is written empty"* ]]
  run secret_data gibson setec-disk-push-credential access-key-id
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run every_data_value_is_a_string
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# The Stripe account (hosted#450). Each rebuild put the chart's placeholders
# back, because the keyring had no Stripe member. The three members now reach
# the keyring Secret, and the openbao-auto-init sidecar copies each non-empty
# one into gibson-stripe-credentials. The values below are fixtures, not keys.
# ---------------------------------------------------------------------------
@test "the Stripe members land in the keyring Secret as three seed inputs" {
  write_keyring ""
  printf 'STRIPE_SECRET_KEY=%s\n' sk_test_batsfixture000 >> "$KEYRING"
  printf 'STRIPE_PUBLISHABLE_KEY=%s\n' pk_test_batsfixture000 >> "$KEYRING"
  printf 'STRIPE_WEBHOOK_SECRET=%s\n' whsec_batsfixture000 >> "$KEYRING"
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Stripe account (secret key sha256:"* ]]
  [[ "$output" != *"sk_test_batsfixture000"* ]]
  run secret_data gibson bringup-keyring stripe-secret-key
  [ "$status" -eq 0 ] && [ "$output" = "sk_test_batsfixture000" ]
  run secret_data gibson bringup-keyring stripe-publishable-key
  [ "$status" -eq 0 ] && [ "$output" = "pk_test_batsfixture000" ]
  run secret_data gibson bringup-keyring stripe-webhook-secret
  [ "$status" -eq 0 ] && [ "$output" = "whsec_batsfixture000" ]
}

@test "a keyring with no Stripe member writes the three keys empty, so the placeholder stays" {
  write_keyring ""
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"keeps the chart's placeholder"* ]]
  for k in stripe-secret-key stripe-publishable-key stripe-webhook-secret; do
    run secret_data gibson bringup-keyring "$k"
    [ "$status" -eq 0 ] && [ -z "$output" ]
  done
  run every_data_value_is_a_string
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# ---------------------------------------------------------------------------
# The Argo CD repository credential (2026-09-14).
#
# Argo CD's app-of-apps clones the gitops repo, which is private. This block
# used to read the ENVIRONMENT only, so `make recreate ENV=staging` from a
# clean checkout skipped it in silence: Argo could not clone its own source
# ("failed to list refs: authentication required: Repository not found") and
# stage 2 stalled to its cap with ONE Application and an error nobody was
# reading. An operator had to know to export three variables that nothing
# named. Measured on the 2026-09-14 staging bringup.
#
# The substrate now carries all three: the two PUBLIC ids in substrate.env,
# the private key in the keyring, base64 because this file is one KEY=value
# line per member and a PEM is not one line.
# ---------------------------------------------------------------------------
app_fixture() {
  write_keyring ""
  printf 'GITHUB_APP_ID=4900007\n' >> "$SUBSTRATE"
  printf 'GITHUB_APP_INSTALLATION_ID=160662894\n' >> "$SUBSTRATE"
  printf 'GITHUB_APP_PRIVATE_KEY=%s\n' "$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIBOgIB\n-----END RSA PRIVATE KEY-----\n' | base64 -w0)" >> "$KEYRING"
}

# field <name> — one base64 data field out of the applied repo-creds Secret.
field() {
  python3 -c '
import sys, base64, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("metadata", {}).get("name") == "zeroroot-ai-creds":
        sys.stdout.write(base64.b64decode(d["data"][sys.argv[2]]).decode())
        break
' "$STATE/applied.yaml" "$1"
}

@test "the Argo repo credential comes from the substrate, with nothing exported" {
  app_fixture
  run env -u GITHUB_APP_ID -u GITHUB_APP_INSTALLATION_ID -u GITHUB_APP_PRIVATE_KEY \
    bash "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GitHub App (id 4900007)"* ]]
  [ "$(field githubAppID)" = 4900007 ]
  [ "$(field githubAppInstallationID)" = 160662894 ]
  # The Secret carries the RAW PEM. The keyring holds it base64-encoded, and
  # decoding it is the whole point of the member being base64.
  [[ "$(field githubAppPrivateKey)" == *"-----BEGIN RSA PRIVATE KEY-----"* ]]
  [ "$(field url)" = "https://github.com/zeroroot-ai" ]
}

# The environment still wins, because recreate.yml passes the App that way and
# a workflow must be able to use a different installation than the substrate
# records.
@test "an App in the environment overrides the one in the substrate" {
  app_fixture
  run env GITHUB_APP_ID=999 GITHUB_APP_INSTALLATION_ID=888 GITHUB_APP_PRIVATE_KEY=raw-pem \
    bash "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ]
  [ "$(field githubAppID)" = 999 ]
  [ "$(field githubAppInstallationID)" = 888 ]
  [ "$(field githubAppPrivateKey)" = raw-pem ]
}

# FAILING FIXTURE: kind. No App anywhere, so no Secret and no failure — kind's
# Argo syncs from the bucket, not from a private repo.
@test "FAILING FIXTURE: a substrate with no App writes no repo-creds Secret" {
  write_keyring ""
  run env -u GITHUB_APP_ID -u GITHUB_APP_INSTALLATION_ID -u GITHUB_APP_PRIVATE_KEY \
    bash "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no GITHUB_APP"* ]]
  ! grep -q 'zeroroot-ai-creds' "$STATE/applied.yaml" || { echo "a line that must not be there matched"; false; }
}

@test "the set time of a vendor value lands as an annotation of the keyring Secret (ADR-0171)" {
  write_keyring "ghp_exampletoken"
  printf 'KEYRING_SET_AT_GHCR_PULL_TOKEN=1760000000\n' >> "$KEYRING"
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  grep -q "annotate secret bringup-keyring --overwrite keyring.zeroroot.ai/set-at.ghcr-pull-token=1760000000" "$STATE/annotate.log"
}

@test "a keyring with no recorded set time writes no annotation" {
  write_keyring ""
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$STATE/annotate.log" ]
}

@test "a keyring with no previous seal key writes openbao-seal-previous-key empty, so the chart volume mounts" {
  write_keyring ""
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run secret_data gibson bringup-keyring openbao-seal-previous-key
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'openbao-seal-previous-key: ""' "$STATE/applied.yaml"
}

@test "during a rotation the previous seal key lands next to the new one (ADR-0171)" {
  write_keyring ""
  printf 'OPENBAO_SEAL_KEY_PREVIOUS=%s\n' "YmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmI=" >> "$KEYRING"
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run secret_data gibson bringup-keyring openbao-seal-previous-key
  [ "$output" = "YmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmI=" ]
  run secret_data gibson bringup-keyring openbao-seal-key
  [ "$output" = "$SEAL_KEY" ]
}

@test "FAILING FIXTURE: a previous seal key of the wrong length stops the script" {
  write_keyring ""
  printf 'OPENBAO_SEAL_KEY_PREVIOUS=short\n' >> "$KEYRING"
  run env NS=gibson "$SCRIPT" "$SUBSTRATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"OPENBAO_SEAL_KEY_PREVIOUS member that is not 44 characters"* ]]
}
