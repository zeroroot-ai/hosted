#!/usr/bin/env bats
#
# acme-challenge.bats: the teardown deletes the ACME challenge records a dead
# cluster left in the env zone, and the post-destroy check counts them (row 27
# of the drill path audit).
#
# Offline. aws is a stub that holds one zone in a JSON file and answers only
# the calls this suite declares.
#
# Run:
#   bats tests/harness/acme-challenge.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
load assert

setup() {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  export ZONE_FILE="$BATS_TEST_TMPDIR/zone.json" WORK="$BATS_TEST_TMPDIR"
  cat > "$ZONE_FILE" <<'JSON'
{"ResourceRecordSets": [
 {"Name": "drill.example.test.", "Type": "NS", "TTL": 172800, "ResourceRecords": [{"Value": "ns-1."}]},
 {"Name": "drill.example.test.", "Type": "SOA", "TTL": 900, "ResourceRecords": [{"Value": "ns-1. a. 1 7200 900 1209600 86400"}]},
 {"Name": "_acme-challenge.app.drill.example.test.", "Type": "TXT", "TTL": 60, "ResourceRecords": [{"Value": "\"tok1\""}]},
 {"Name": "_acme-challenge.drill.example.test.", "Type": "TXT", "TTL": 60, "ResourceRecords": [{"Value": "\"tok2\""}]},
 {"Name": "app.drill.example.test.", "Type": "TXT", "TTL": 300, "ResourceRecords": [{"Value": "\"heritage=external-dns\""}]}
]}
JSON
  cat > "$BIN/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "route53 list-resource-record-sets --hosted-zone-id ZDRILL --output json")
    [ -z "${STUB_LIST_FAIL:-}" ] || { echo "An error occurred (Throttling)" >&2; exit 254; }
    cat "$ZONE_FILE"; exit 0 ;;
  "route53 change-resource-record-sets --hosted-zone-id ZDRILL --change-batch file://"*)
    f="${*: -1}"; f="${f#file://}"
    python3 - "$ZONE_FILE" "$f" <<'PY'
import json, sys
zone = json.load(open(sys.argv[1])); batch = json.load(open(sys.argv[2]))
gone = [c["ResourceRecordSet"] for c in batch["Changes"] if c["Action"] == "DELETE"]
zone["ResourceRecordSets"] = [r for r in zone["ResourceRecordSets"] if r not in gone]
json.dump(zone, open(sys.argv[1], "w"))
PY
    exit 0 ;;
  "ec2 describe-"*" --query length("*) echo 0; exit 0 ;;
  "resourcegroupstaggingapi get-resources --region us-east-1 --tag-filters Key=Environment,Values=drill --output json")
    echo '{"ResourceTagMappingList": []}'; exit 0 ;;
esac
echo "aws stub: undeclared call: $*" >&2; exit 1
SH
  chmod +x "$BIN/aws"
  export PATH="$BIN:$PATH"
}

lib() { bash -c '. "$1"; shift; "$@"' _ "$REPO_ROOT/scripts/lib/acme-challenge.sh" "$@"; }
names() { python3 -c 'import json,sys; print(" ".join(sorted(r["Name"] for r in json.load(open(sys.argv[1]))["ResourceRecordSets"])))' "$ZONE_FILE"; }

@test "the sweep deletes the ACME challenge TXT records and nothing else" {
  run lib acme_sweep ZDRILL drill.example.test example.test
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_has "deleted 2 ACME challenge record(s)"
  [ "$(names)" = "app.drill.example.test. drill.example.test. drill.example.test." ]
  run lib acme_count ZDRILL
  [ "$output" = 0 ]
}

@test "FAILING FIXTURE: the sweep refuses the apex zone and deletes nothing" {
  run lib acme_sweep ZDRILL example.test example.test
  [ "$status" -eq 2 ]
  assert_output_has "refusing the APEX zone"
  run lib acme_count ZDRILL
  [ "$output" = 2 ]
}

@test "FAILING FIXTURE: a list that fails is a failure, never an empty zone" {
  STUB_LIST_FAIL=1 run lib acme_sweep ZDRILL drill.example.test example.test
  [ "$status" -ne 0 ]
  assert_output_has "could not list the records"
}

@test "FAILING FIXTURE: the post-destroy check counts a challenge record that is left" {
  run env ZONE_ID=ZDRILL "$REPO_ROOT/bootstrap/ec2/gibson/scripts/ec2-post-destroy-verify.sh" drill
  [ "$status" -ne 0 ]
  assert_output_has "ACME challenge records in zone ZDRILL: 2"
}

@test "after the sweep the post-destroy check reads zero challenge records" {
  run lib acme_sweep ZDRILL drill.example.test example.test
  [ "$status" -eq 0 ]
  run env ZONE_ID=ZDRILL "$REPO_ROOT/bootstrap/ec2/gibson/scripts/ec2-post-destroy-verify.sh" drill
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_output_has "ACME challenge records in zone ZDRILL: 0"
}

@test "the EC2 teardown sweeps the env zone before each post-destroy check" {
  run python3 - "$REPO_ROOT/scripts/teardown-ec2.sh" <<'PY'
import sys
t = open(sys.argv[1]).read()
calls = [i for i in range(len(t)) if t.startswith("acme_sweep_env_zone\n", i) and t[i - 1] in " \n"]
verifies = [i for i in range(len(t)) if t.startswith('"$EC2_DIR/scripts/ec2-post-destroy-verify.sh"', i)]
assert len(verifies) == 2, verifies
for v in verifies:
    assert any(c < v and v - c < 2500 for c in calls), "a post-destroy check has no sweep before it"
PY
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
