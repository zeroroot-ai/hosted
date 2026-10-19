#!/usr/bin/env bats
#
# preflight.bats — proves scripts/preflight.sh FAILS CLOSED (deploy#1736, ADR-0083).
#
# WHY THIS SUITE EXISTS
# ---------------------
# preflight is the gate between stage 0 and stage 1. Its dangerous failure
# mode is not a red run but a green one with an input missing: a keyring with
# a member gone, a bucket that quietly lost versioning, a platform credential
# that can delete backups. docs/bringup.md says it plainly: "A preflight that
# passes with one of these missing is a defect in preflight." This suite is
# what makes that sentence checkable on every merge.
#
# Offline, by construction. `aws` and `dig` are stubs on PATH driven by a
# control file, and the SMTP relay is a fake speaking just enough ESMTP for
# EHLO and AUTH PLAIN. The keyring, its fingerprints and substrate.env come
# from the real scripts/keyring.sh, so the shape under test is the shipped
# shape and not a copy of it.
#
# The contract under test:
#   exit 2 = could not run (NOT a pass)
#   exit 1 = ran, found a miss, named it, stopped there
#   exit 0 = ran, every line proved live
#
# The default substrate.env has the AWS shape (deploy#1742): it names an apex
# zone, so line 7 (the apex mail records) runs. The kind shape names none and
# line 7 prints as skipped; one test proves that path.
#
# Run:
#   bats tests/harness/preflight.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PREFLIGHT="$REPO_ROOT/scripts/preflight.sh"
KEYRING="$REPO_ROOT/scripts/keyring.sh"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STATE="$BATS_TEST_TMPDIR/state"
  CTL="$BATS_TEST_TMPDIR/aws.ctl"
  CALLS="$BATS_TEST_TMPDIR/aws.calls"
  mkdir -p "$STUB_DIR" "$STATE"
  PATH="$STUB_DIR:$PATH"
  export PATH CTL CALLS
  : > "$CALLS"

  "$KEYRING" generate "$STATE/keyring.env" >/dev/null

  write_aws_stub
  write_dig_stub
  start_fake_smtp
  write_substrate_env
  # Defaults: a complete, healthy stage 0.
  set_ctl versioning Enabled
  set_ctl delete deny
  set_ctl lifecycle "backups/ audit/ tfstate/ preflight/"
}

teardown() {
  if [ -n "${SMTP_PID:-}" ]; then kill "$SMTP_PID" 2>/dev/null || true; fi
}

# set_ctl KEY VALUE — one knob of the aws stub.
set_ctl() {
  grep -v "^$1=" "$CTL" 2>/dev/null > "$CTL.new" || true
  printf '%s=%s\n' "$1" "$2" >> "$CTL.new"
  mv "$CTL.new" "$CTL"
}

write_substrate_env() {
  {
    printf 'SUBSTRATE_ENV=%s\n' "${FIXTURE_ENV:-test}"
    printf 'BUCKET_ENDPOINT=http://198.51.100.10:9000\n'
    printf 'BUCKET_REGION=us-east-1\n'
    printf 'BUCKET_NAME=gibson-test\n'
    printf 'KEYRING_FILE=%s\n' "$STATE/keyring.env"
    "$KEYRING" fingerprints "$STATE/keyring.env"
    printf 'SMTP_HOST=127.0.0.1\n'
    printf 'SMTP_PORT=%s\n' "$SMTP_PORT"
    printf 'SMTP_USER=gibson\n'
    printf 'ZONE_NAME=test.zeroroot.test\n'
    printf 'ZONE_ID=Z0TESTZONE00000000\n'
    printf 'ZONE_NAMESERVER=198.51.100.53\n'
    printf 'APEX_ZONE_NAME=zeroroot.test\n'
    printf 'APEX_ZONE_NAMESERVER=198.51.100.54\n'
    printf 'APEX_DKIM_SELECTORS=google,tok1\n'
    # The Argo CD GitHub App's two PUBLIC ids. Empty by default, which is the
    # kind shape: check 9 then skips.
    printf 'GITHUB_APP_ID=%s\n' "${FIXTURE_APP_ID:-}"
    printf 'GITHUB_APP_INSTALLATION_ID=%s\n' "${FIXTURE_APP_INSTALLATION_ID:-}"
  } > "$STATE/substrate.env"
}

# set_github_app — the substrate and keyring an AWS env carries once an
# operator has made the App. The PEM is a real RSA key, because preflight
# base64-decodes it and hands it to the probe.
set_github_app() {
  # ${x-default}, never ${x:-default}: a test passes "" on purpose to say
  # "this one is missing", and :- would hand back the default instead.
  FIXTURE_APP_ID="${1-4900007}"
  FIXTURE_APP_INSTALLATION_ID="${2-160662894}"
  if [ "${3:-with-key}" = with-key ]; then
    openssl genrsa -out "$BATS_TEST_TMPDIR/app.pem" 2048 >/dev/null 2>&1
    "$KEYRING" set "$STATE/keyring.env" GITHUB_APP_PRIVATE_KEY \
      "$(base64 -w0 < "$BATS_TEST_TMPDIR/app.pem")" >/dev/null
  fi
  write_substrate_env
}

# A probe that answers the way the real one does, without reaching GitHub.
# PROBE_RC decides whether the App can read the repository.
write_probe_stub() {
  cat > "$BATS_TEST_TMPDIR/probe.py" <<'PY'
import sys
app_id, install, pem, repo = sys.argv[1:5]
open(pem).read()               # preflight must hand it a readable PEM
if __import__("os").environ.get("PROBE_RC", "0") != "0":
    sys.stderr.write("GET /repos/%s: HTTP 404 Not Found\n" % repo)
    raise SystemExit(1)
sys.stdout.write("app %s (zeroroot-argocd) installation %s reads %s (private=true)\n"
                 % (app_id, install, repo))
PY
  export GITHUB_APP_PROBE="$BATS_TEST_TMPDIR/probe.py"
}

# The aws stub. Records every s3api operation in $CALLS, stores the body of
# put-object so get-object returns the same bytes, and answers the three
# property queries from the control file.
write_aws_stub() {
  cat > "$STUB_DIR/aws" <<'SH'
#!/usr/bin/env bash
ctl() { grep -E "^$1=" "$CTL" | head -n1 | cut -d= -f2-; }
op=""; body=""; out=""; prev=""
for a in "$@"; do
  case "$prev" in
    --body) body="$a" ;;
  esac
  case "$a" in
    put-object|get-object|delete-object|get-bucket-versioning|get-bucket-lifecycle-configuration|list-resource-record-sets) op="$a" ;;
  esac
  prev="$a"
done
echo "$op" >> "$CALLS"
case "$op" in
  put-object)
    cp "$body" "$CALLS.object"; echo '{"ETag": "\"stub\""}' ;;
  get-object)
    # The output file is the last positional argument.
    out="${@: -1}"; cp "$CALLS.object" "$out"; echo '{"ContentLength": 1}' ;;
  delete-object)
    if [ "$(ctl delete)" = "allow" ]; then exit 0; fi
    echo "An error occurred (AccessDenied) when calling the DeleteObject operation: Access Denied." >&2; exit 254 ;;
  get-bucket-versioning)
    echo "$(ctl versioning)" ;;
  list-resource-record-sets)
    # Route53 has one endpoint. With AWS_ENDPOINT_URL still exported from the
    # bucket checks the real CLI sent this call to the S3 endpoint, which
    # answered with the S3 signing error below (staging 2026-09-10).
    if [ -n "${AWS_ENDPOINT_URL:-}" ]; then
      echo "An error occurred (InvalidRequest) when calling the ListResourceRecordSets operation: Missing required header for this request: x-amz-content-sha256" >&2; exit 254
    fi
    if [ "$(ctl dns)" = "deny" ] || [ "$AWS_ACCESS_KEY_ID" != "AKIADNSTESTKEY000000" ]; then
      echo "An error occurred (AccessDenied) when calling the ListResourceRecordSets operation: User is not authorized" >&2; exit 254
    fi
    echo "test.zeroroot.test." ;;
  get-bucket-lifecycle-configuration)
    rules="$(ctl lifecycle)"
    if [ -z "$rules" ]; then
      echo "An error occurred (NoSuchLifecycleConfiguration) when calling the GetBucketLifecycleConfiguration operation: The lifecycle configuration does not exist" >&2; exit 254
    fi
    printf '%s\n' "$rules" | tr ' ' '\t' ;;
  *) echo "aws stub: unexpected invocation: $*" >&2; exit 99 ;;
esac
SH
  chmod +x "$STUB_DIR/aws"
}

# dig answers one NS record for the zone from the configured nameserver, and
# the apex mail records from the apex nameserver. The control key
# apex_missing=<MX|SPF|DKIM:selector> makes one of them answer empty.
write_dig_stub() {
  cat > "$STUB_DIR/dig" <<'SH'
#!/usr/bin/env bash
missing="$(grep -E '^apex_missing=' "$CTL" 2>/dev/null | head -n1 | cut -d= -f2-)"
case "$*" in
  *"@198.51.100.53 NS test.zeroroot.test"*) echo "ns.test.zeroroot.test." ;;
  *"@198.51.100.54 MX zeroroot.test"*)  [ "$missing" = MX ]  || echo "1 smtp.google.com." ;;
  *"@198.51.100.54 TXT zeroroot.test"*) [ "$missing" = SPF ] || echo '"v=spf1 include:_spf.google.com include:amazonses.com ~all"' ;;
  *"@198.51.100.54 TXT google._domainkey.zeroroot.test"*) [ "$missing" = DKIM:google ] || echo '"v=DKIM1; k=rsa; p=MIIB" "AQEFAA"' ;;
  *"@198.51.100.54 TXT tok1._domainkey.zeroroot.test"*)   [ "$missing" = DKIM:tok1 ]   || echo "tok1.dkim.amazonses.com." ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$STUB_DIR/dig"
}

# A fake ESMTP relay on a free loopback port. Accepts AUTH PLAIN for
# gibson:<the keyring's SMTP_PASSWORD> and refuses everything else. It
# offers no TLS. $1 is the bind address (default 127.0.0.1).
start_fake_smtp() {
  local password bind="${1:-127.0.0.1}"
  password="$("$KEYRING" get "$STATE/keyring.env" SMTP_PASSWORD)"
  cat > "$BATS_TEST_TMPDIR/fake-smtp.py" <<'PY'
import base64, socket, sys
port_file, user, password, bind = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((bind, 0)); srv.listen(5)
with open(port_file, "w") as f: f.write(str(srv.getsockname()[1]))
want = base64.b64encode(b"\0" + user.encode() + b"\0" + password.encode()).decode()
while True:
    conn, _ = srv.accept()
    f = conn.makefile("rwb", buffering=0)
    f.write(b"220 fake ESMTP\r\n")
    for raw in f:
        line = raw.decode(errors="replace").rstrip("\r\n")
        verb = line.split(" ", 1)[0].upper()
        if verb == "EHLO":
            f.write(b"250-fake\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n")
        elif verb == "AUTH":
            parts = line.split(" ")
            if len(parts) >= 3 and parts[1].upper() == "PLAIN" and parts[2] == want:
                f.write(b"235 2.7.0 Authentication successful\r\n")
            else:
                f.write(b"535 5.7.8 Authentication credentials invalid\r\n")
        elif verb == "QUIT":
            f.write(b"221 bye\r\n"); break
        else:
            f.write(b"502 not implemented\r\n")
    conn.close()
PY
  local port_file="$BATS_TEST_TMPDIR/smtp.port"
  rm -f "$port_file"
  python3 "$BATS_TEST_TMPDIR/fake-smtp.py" "$port_file" gibson "$password" "$bind" &
  SMTP_PID=$!
  local i
  for i in $(seq 1 50); do
    [ -s "$port_file" ] && break
    sleep 0.1
  done
  [ -s "$port_file" ]
  SMTP_PORT="$(cat "$port_file")"
}

run_preflight() { run bash "$PREFLIGHT" "$STATE/substrate.env"; }

# set_dns_credential — the keyring gains the DNS pair stage 0 mints on AWS,
# and substrate.env its fingerprints, as `make substrate` leaves them.
set_dns_credential() {
  "$KEYRING" set "$STATE/keyring.env" DNS_ACCESS_KEY AKIADNSTESTKEY000000 >/dev/null
  "$KEYRING" set "$STATE/keyring.env" DNS_SECRET_KEY dns-secret-key-for-the-bats-suite >/dev/null
  write_substrate_env
}

# ---------------------------------------------------------------------------
# The positive path: every line live, exit 0, eight ticks.
# ---------------------------------------------------------------------------

@test "complete stage 0: exit 0, all eight lines proved, PASS printed" {
  run_preflight
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 keyring"* ]]
  # This fixture supplies neither input member, so preflight must SAY so
  # rather than call them present. Reporting "8 members present" is how a
  # missing GHCR_PULL_TOKEN read as green while two first-party images could
  # not pull (deploy#1795).
  [[ "$output" == *"6 of 15 members supplied, lengths right, fingerprints match"* ]]
  [[ "$output" == *"NOT SUPPLIED: GHCR_PULL_TOKEN,DNS_ACCESS_KEY,DNS_SECRET_KEY"* ]]
  [[ "$output" == *"2 bucket"* ]]
  [[ "$output" == *"delete denied for the platform credential"* ]]
  [[ "$output" == *"3 versioning"* ]]
  [[ "$output" == *"4 lifecycle"* ]]
  [[ "$output" == *"5 smtp"* ]]
  [[ "$output" == *"AUTH ok as gibson"* ]]
  [[ "$output" == *"6 zone"* ]]
  [[ "$output" == *"ns.test.zeroroot.test."* ]]
  [[ "$output" == *"7 apex"* ]]
  [[ "$output" == *"zeroroot.test carries MX, SPF and DKIM (google,tok1)"* ]]
  # No DNS credential in this keyring (kind): the line is skipped and says so.
  [[ "$output" == *"8 dns"* ]]
  [[ "$output" == *"carries no DNS credential"* ]]
  [[ "$output" == *"preflight PASS"* ]]
  # The bucket was written, read back and a delete attempted, in that order.
  [ "$(grep -c . "$CALLS")" -eq 5 ]
  [ "$(sed -n 1p "$CALLS")" = "put-object" ]
  [ "$(sed -n 2p "$CALLS")" = "get-object" ]
  [ "$(sed -n 3p "$CALLS")" = "delete-object" ]
}

@test "DNS credential in the keyring: the zone is listed with it, 8 dns proved" {
  set_dns_credential
  run_preflight
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"8 of 15 members supplied"* ]]
  [[ "$output" == *"credential AKIADNSTESTKEY000000 lists zone test.zeroroot.test (Z0TESTZONE00000000), first record test.zeroroot.test."* ]]
  [[ "$output" == *"preflight PASS"* ]]
  [ "$(grep -c . "$CALLS")" -eq 6 ]
  [ "$(sed -n 6p "$CALLS")" = "list-resource-record-sets" ]
}

@test "DNS credential refused by Route53: exit 1, dns named, no PASS" {
  set_dns_credential
  set_ctl dns deny
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"8 dns"* ]]
  [[ "$output" == *"cannot list zone test.zeroroot.test (Z0TESTZONE00000000)"* ]]
  [[ "$output" == *"AccessDenied"* ]]
  [[ "$output" != *"preflight PASS"* ]]
}

# ---------------------------------------------------------------------------
# Failing fixture 1: one keyring member removed. Named, and nothing after it
# runs: no bucket call was made.
# ---------------------------------------------------------------------------

@test "keyring with VELERO_REPO_PASSWORD removed: exit 1, member named, bucket never touched" {
  grep -v '^VELERO_REPO_PASSWORD=' "$STATE/keyring.env" > "$STATE/keyring.short" && mv "$STATE/keyring.short" "$STATE/keyring.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"member VELERO_REPO_PASSWORD missing from"* ]]
  [[ "$output" == *"preflight FAIL at 1 keyring"* ]]
  [[ "$output" != *"preflight PASS"* ]]
  [ ! -s "$CALLS" ]
}

@test "keyring member with a changed value: exit 1, fingerprint mismatch names the member" {
  sed -i "s|^OPENBAO_SEAL_KEY=.*|OPENBAO_SEAL_KEY=$(head -c 32 /dev/zero | base64 -w0)|" "$STATE/keyring.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"member OPENBAO_SEAL_KEY does not match its recorded fingerprint"* ]]
  [ ! -s "$CALLS" ]
}

@test "keyring member with the wrong length: exit 1, length named" {
  sed -i 's|^BUCKET_ACCESS_KEY=.*|BUCKET_ACCESS_KEY=SHORT|' "$STATE/keyring.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"member BUCKET_ACCESS_KEY has length 5, want 20"* ]]
}

@test "keyring file missing: exit 1, path named" {
  rm "$STATE/keyring.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"keyring file $STATE/keyring.env is missing or unreadable"* ]]
}

# ---------------------------------------------------------------------------
# Failing fixture 2: bucket versioning off. Named, and the relay and the zone
# are never asked.
# ---------------------------------------------------------------------------

@test "bucket versioning off: exit 1, versioning named, smtp and zone not attempted" {
  set_ctl versioning None
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bucket gibson-test versioning is 'None', want Enabled"* ]]
  [[ "$output" == *"preflight FAIL at 3 versioning"* ]]
  [[ "$output" != *"5 smtp"* ]]
  [[ "$output" != *"6 zone"* ]]
  # Bucket write/read/delete ran (2 bucket passed), lifecycle did not.
  ! grep -q get-bucket-lifecycle-configuration "$CALLS"
}

@test "platform credential allowed to delete: exit 1, the delete is the miss" {
  set_ctl delete allow
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the platform credential DELETED"* ]]
  [[ "$output" == *"preflight FAIL at 2 bucket"* ]]
}

@test "lifecycle rule missing for tfstate/: exit 1, prefix named" {
  set_ctl lifecycle "backups/ audit/"
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no enabled lifecycle rule for prefix tfstate/"* ]]
}

@test "no lifecycle configuration at all: exit 1, lifecycle named" {
  set_ctl lifecycle ""
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no lifecycle configuration"* ]]
}

@test "relay refuses the credential: exit 1, smtp named" {
  sed -i "s|^SMTP_PASSWORD=.*|SMTP_PASSWORD=$(head -c 30 /dev/zero | base64 -w0)|" "$STATE/keyring.env"
  # Re-record the fingerprints so the keyring line passes and the relay is reached.
  write_substrate_env
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused AUTH for gibson"* ]]
  [[ "$output" == *"preflight FAIL at 5 smtp"* ]]
}

@test "FAILING FIXTURE: a relay with AUTH and no TLS on a host that is not localhost fails at 5 smtp" {
  # The daemon's Go client sends no credential in clear text to another
  # host, so it cannot send through this relay. A preflight that passes it
  # tells the operator a relay works that the platform cannot use (hosted#126).
  kill "$SMTP_PID" 2>/dev/null || true
  start_fake_smtp 127.0.0.2
  write_substrate_env
  sed -i 's|^SMTP_HOST=.*|SMTP_HOST=127.0.0.2|' "$STATE/substrate.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"offers no TLS"* ]]
  [[ "$output" == *"preflight FAIL at 5 smtp"* ]]
}

@test "kind shape, no SMTP rows: smtp line skipped, exit 0" {
  sed -i -e 's|^SUBSTRATE_ENV=.*|SUBSTRATE_ENV=kind|' -e '/^SMTP_/d' "$STATE/substrate.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"5 smtp        skipped: kind has no SMTP relay"* ]]
  [[ "$output" == *"preflight PASS"* ]]
}

@test "a substrate that is not kind with no SMTP rows could not run, it never skips" {
  sed -i '/^SMTP_/d' "$STATE/substrate.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"substrate.env lacks SMTP_HOST"* ]]
  [[ "$output" != *"skipped: kind has no SMTP relay"* ]]
}

@test "zone answers no NS records: exit 1, zone named" {
  sed -i 's|^ZONE_NAMESERVER=.*|ZONE_NAMESERVER=198.51.100.99|' "$STATE/substrate.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"test.zeroroot.test returned no NS records from 198.51.100.99"* ]]
}

# ---------------------------------------------------------------------------
# Line 7, the apex mail records (deploy#1742). Runs when substrate.env names
# an apex, skips when it does not (kind), and fails on each missing record.
# ---------------------------------------------------------------------------

@test "kind shape, no APEX_ZONE_NAME: apex line skipped, exit 0" {
  sed -i '/^APEX_/d' "$STATE/substrate.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"7 apex        skipped: substrate.env names no APEX_ZONE_NAME"* ]]
  [[ "$output" == *"preflight PASS"* ]]
}

@test "apex without an MX record: exit 1, apex named, mail called gone" {
  set_ctl apex_missing MX
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"zeroroot.test has no MX record at 198.51.100.54"* ]]
  [[ "$output" == *"preflight FAIL at 7 apex"* ]]
}

@test "apex without an SPF record: exit 1, SPF named" {
  set_ctl apex_missing SPF
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"zeroroot.test has no SPF record (v=spf1)"* ]]
}

@test "apex missing one DKIM selector: exit 1, the selector named" {
  set_ctl apex_missing DKIM:tok1
  run_preflight
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no DKIM record for selector tok1"* ]]
  [[ "$output" != *"preflight PASS"* ]]
}

@test "APEX_ZONE_NAME set but APEX_DKIM_SELECTORS missing: exit 2, NOT a pass" {
  sed -i '/^APEX_DKIM_SELECTORS=/d' "$STATE/substrate.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"substrate.env lacks APEX_DKIM_SELECTORS"* ]]
}

# ---------------------------------------------------------------------------
# Could-not-run is exit 2, never a pass.
# ---------------------------------------------------------------------------

@test "no substrate.env: exit 2, NOT a pass" {
  run bash "$PREFLIGHT" "$STATE/does-not-exist.env"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no substrate.env at"* ]]
  [[ "$output" == *"NOT a pass"* ]]
}

@test "substrate.env lacking a key: exit 2 naming the key, nothing probed" {
  sed -i '/^SMTP_HOST=/d' "$STATE/substrate.env"
  run_preflight
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"substrate.env lacks SMTP_HOST"* ]]
  [ ! -s "$CALLS" ]
}

# `--max-items` is the aws CLI's OWN paginator, not a service parameter. When
# it truncates, the CLI prints the query result and THEN a second line holding
# the next token — which for a finished listing is the literal `None`. On
# staging 2026-09-14 that line landed in preflight's output between check 8 and
# PASS, as a bare `None` nobody could source. Preflight's output is what an
# operator reads before spending forty minutes on a bringup, so a line nobody
# can account for is a defect in preflight.
#
# The same paginator broke the Postgres archive gate the same day, which is why
# this is asserted on the SCRIPT and not only on one stubbed run: any check
# that grows a listing must not reach for it.
@test "FAILING FIXTURE: preflight never uses the CLI paginator" {
  # Executable lines only: the comment above the call explains why it is
  # absent, and a comment must not satisfy the assertion.
  run grep -vE '^[[:space:]]*#' "$PREFLIGHT"
  [[ "$output" != *"--max-items"* ]]
}

@test "preflight prints nothing it cannot account for" {
  run_preflight
  [ "$status" -eq 0 ]
  ! grep -qx 'None' <<<"$output"
  [[ "$output" == *"preflight PASS"* ]]
}

# ---------------------------------------------------------------------------
# 9 argo — the Argo CD GitHub App reads the gitops repo.
#
# Argo CD's app-of-apps clones the gitops repo, which is private. Without a
# working credential the clone fails with "failed to list refs: authentication
# required: Repository not found", and the bringup shows it as stage 2
# stalling to its cap with ONE Application: forty minutes spent, nothing
# converged, and an error nobody is reading. Measured on the 2026-09-14
# staging bringup, where the cause was three environment variables that
# nothing named.
# ---------------------------------------------------------------------------
@test "a substrate with a working GitHub App passes check 9 and names the repo" {
  set_github_app
  write_probe_stub
  run_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"9 argo"* ]]
  [[ "$output" == *"reads zeroroot-ai/hosted"* ]]
  [[ "$output" == *"preflight PASS"* ]]
}

@test "a substrate with no GitHub App skips check 9 and says why" {
  run_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"9 argo"* ]]
  [[ "$output" == *"names no GitHub App"* ]]
  [[ "$output" == *"preflight PASS"* ]]
}

# FAILING FIXTURE: the App cannot read the repository. The installation exists
# and the repository is simply not in its selection, which is the shape that
# reads as configured and fails at clone time.
@test "FAILING FIXTURE: an App that cannot read the gitops repo fails preflight" {
  set_github_app
  write_probe_stub
  PROBE_RC=1 run bash "$PREFLIGHT" "$STATE/substrate.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read zeroroot-ai/hosted"* ]]
  [[ "$output" == *"preflight FAIL at 9 argo"* ]]
}

# FAILING FIXTURE: half a credential. Any one of the three present means this
# environment MEANS to use an App, so a missing other one is an error and
# never a skip — a skip here is how a bringup reaches stage 2 before anyone
# finds out.
@test "FAILING FIXTURE: an App id with no private key fails, and never skips" {
  set_github_app 4900007 160662894 no-key
  write_probe_stub
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"keyring carries no GITHUB_APP_PRIVATE_KEY"* ]]
  [[ "$output" != *"names no GitHub App"* ]]
}

@test "FAILING FIXTURE: a private key with no installation id fails, and never skips" {
  set_github_app 4900007 "" with-key
  write_probe_stub
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"no GITHUB_APP_INSTALLATION_ID"* ]]
  [[ "$output" != *"names no GitHub App"* ]]
}

# The keyring is one KEY=value line per member, so a raw PEM cannot go in it
# at all: `keyring.sh set` refuses the whitespace. That refusal is the reason
# the member holds base64, and it is worth pinning — without it the file would
# be silently corrupted by a newline in the middle of a value.
@test "FAILING FIXTURE: the keyring refuses a raw PEM, which is why the member is base64" {
  run "$KEYRING" set "$STATE/keyring.env" GITHUB_APP_PRIVATE_KEY '-----BEGIN RSA PRIVATE KEY-----'
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains whitespace"* ]]
}

@test "FAILING FIXTURE: a GITHUB_APP_PRIVATE_KEY that is not base64 fails" {
  set_github_app 4900007 160662894 no-key
  "$KEYRING" set "$STATE/keyring.env" GITHUB_APP_PRIVATE_KEY '@@@notbase64@@@' >/dev/null
  write_substrate_env
  write_probe_stub
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not base64"* ]]
}

# ---------------------------------------------------------------------------
# 10 stripe — the Stripe account of the environment (hosted#450).
#
# A rebuild put the chart's test-mode placeholders back into
# gibson-stripe-credentials, because the keyring had no Stripe member. Each
# paid signup on staging then stopped at the card step: "Invalid API Key
# provided: sk_test_*******lder". The keyring now carries the account, and an
# environment that bills fails preflight without it. The values below are
# fixtures, not keys.
# ---------------------------------------------------------------------------

# set_stripe <sk> <pk> <whsec> — the three members, then the fingerprints
# that make substrate records after a keyring set.
set_stripe() {
  "$KEYRING" set "$STATE/keyring.env" STRIPE_SECRET_KEY "$1" >/dev/null
  "$KEYRING" set "$STATE/keyring.env" STRIPE_PUBLISHABLE_KEY "$2" >/dev/null
  "$KEYRING" set "$STATE/keyring.env" STRIPE_WEBHOOK_SECRET "$3" >/dev/null
  write_substrate_env
}

# A Stripe that answers the way the real one does. STRIPE_PROBE_RC decides
# whether the key works.
write_stripe_probe_stub() {
  cat > "$BATS_TEST_TMPDIR/stripe-probe.py" <<'PY'
import os, sys
key = os.environ.get("STRIPE_SECRET_KEY", "")
if not key:
    raise SystemExit(2)
if os.environ.get("STRIPE_PROBE_RC", "0") != "0":
    sys.stderr.write("GET /v1/prices: HTTP 401 Invalid API Key provided\n")
    raise SystemExit(1)
sys.stdout.write("the Stripe secret key reads the account (test mode, 1 price(s) listed)\n")
PY
  export STRIPE_KEY_PROBE="$BATS_TEST_TMPDIR/stripe-probe.py"
}

@test "FAILING FIXTURE: staging with no Stripe member fails preflight, so the placeholder never ships" {
  FIXTURE_ENV=staging write_substrate_env
  write_stripe_probe_stub
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"keyring carries no STRIPE_SECRET_KEY"* ]]
  [[ "$output" == *"keeps the chart's placeholder"* ]]
  [[ "$output" == *"preflight FAIL at 10 stripe"* ]]
}

@test "staging with a working Stripe account passes check 10" {
  FIXTURE_ENV=staging
  set_stripe sk_test_batsfixture000 pk_test_batsfixture000 whsec_batsfixture000
  write_stripe_probe_stub
  set_ghcr ghp_batsfixture0000000000000000000000000
  write_ghcr_probe_stub
  run_preflight
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"10 stripe"* ]]
  [[ "$output" == *"reads the account"* ]]
  [[ "$output" != *"sk_test_batsfixture000"* ]]
  [[ "$output" == *"preflight PASS"* ]]
}

@test "FAILING FIXTURE: a key that Stripe refuses fails preflight" {
  FIXTURE_ENV=staging
  set_stripe sk_test_batsfixture000 pk_test_batsfixture000 whsec_batsfixture000
  write_stripe_probe_stub
  STRIPE_PROBE_RC=1 run bash "$PREFLIGHT" "$STATE/substrate.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Stripe refused the keyring's STRIPE_SECRET_KEY"* ]]
}

@test "FAILING FIXTURE: the chart's placeholder copied into the keyring fails preflight" {
  FIXTURE_ENV=staging
  set_stripe sk_test_placeholder pk_test_placeholder whsec_placeholder
  write_stripe_probe_stub
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"is the chart's placeholder"* ]]
}

@test "FAILING FIXTURE: a live publishable key beside a test secret key fails preflight" {
  FIXTURE_ENV=staging
  set_stripe sk_test_batsfixture000 pk_live_batsfixture000 whsec_batsfixture000
  write_stripe_probe_stub
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a pk_test_ key"* ]]
}

@test "FAILING FIXTURE: half a Stripe account fails on an environment that does not bill" {
  set_stripe sk_test_batsfixture000 "" ""
  write_stripe_probe_stub
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"keyring carries no STRIPE_PUBLISHABLE_KEY"* ]]
}

@test "an environment that does not bill and has no Stripe member skips check 10" {
  run_preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"10 stripe"* ]]
  [[ "$output" == *"does not bill"* ]]
}

# ---------------------------------------------------------------------------
# 11 ghcr — the image pull token works (hosted#601). A revoked token passed
# check 1 on 2026-10-11, and the staging recreate and the drill then stopped
# at the image copy with a 403 from GHCR.
# ---------------------------------------------------------------------------
set_ghcr() {
  "$KEYRING" set "$STATE/keyring.env" GHCR_PULL_TOKEN "$1" >/dev/null
  write_substrate_env
}

# A GHCR that answers the way the real one does. GHCR_PROBE_RC decides
# whether the token works.
write_ghcr_probe_stub() {
  cat > "$BATS_TEST_TMPDIR/ghcr-probe.py" <<'PY'
import os, sys
if not os.environ.get("GHCR_PULL_TOKEN", ""):
    raise SystemExit(2)
if os.environ.get("GHCR_PROBE_RC", "0") != "0":
    sys.stderr.write("GET /token for zeroroot-ai/billing: HTTP 403\n")
    raise SystemExit(1)
sys.stdout.write("GHCR grants the keyring token pull on zeroroot-ai/billing\n")
PY
  export GHCR_PULL_PROBE="$BATS_TEST_TMPDIR/ghcr-probe.py"
}

staging_with_stripe() {
  FIXTURE_ENV=staging
  set_stripe sk_test_batsfixture000 pk_test_batsfixture000 whsec_batsfixture000
  write_stripe_probe_stub
  write_ghcr_probe_stub
}

@test "FAILING FIXTURE: a pull token that GHCR refuses fails preflight at 11 ghcr" {
  staging_with_stripe
  set_ghcr ghp_batsfixture0000000000000000000000000
  GHCR_PROBE_RC=1 run bash "$PREFLIGHT" "$STATE/substrate.env"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GHCR refused the keyring's GHCR_PULL_TOKEN (GET /token for zeroroot-ai/billing: HTTP 403)"* ]]
  [[ "$output" == *"preflight FAIL at 11 ghcr"* ]]
  [[ "$output" != *"ghp_batsfixture"* ]]
  [[ "$output" != *"preflight PASS"* ]]
}

@test "FAILING FIXTURE: staging with no pull token fails preflight at 11 ghcr" {
  staging_with_stripe
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"the keyring carries no GHCR_PULL_TOKEN"* ]]
  [[ "$output" == *"preflight FAIL at 11 ghcr"* ]]
}

@test "staging with a pull token that GHCR accepts passes check 11" {
  staging_with_stripe
  set_ghcr ghp_batsfixture0000000000000000000000000
  run_preflight
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"11 ghcr"*"GHCR grants the keyring token pull"* ]]
  [[ "$output" != *"ghp_batsfixture"* ]]
}

@test "an environment that pulls no private image and has no token skips check 11" {
  run_preflight
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"ghcr"*"skipped"* ]]
}
