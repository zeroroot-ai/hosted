# shellcheck shell=bash
# ---------------------------------------------------------------------------
# acme-challenge.sh — the ACME challenge records that a teardown leaves in the
# env sub-zone (row 27 of the drill path audit).
#
# cert-manager writes a TXT record `_acme-challenge.<host>` for each DNS-01
# challenge and deletes it when the challenge ends. A cluster that dies in the
# middle of a challenge leaves the record. The next issuance for that name
# then sees two TXT values, and Let's Encrypt counts a failed validation.
# Route 53 bills each record set forever. So the teardown deletes them, and
# the post-destroy check counts them.
#
#   acme_sweep <zone id> <zone name> <apex name>   delete each _acme-challenge
#                                                  TXT record of the env zone
#   acme_count <zone id>                           print how many remain
#
# Only the env sub-zone, by id. The apex zone is refused: it carries the mail
# of the estate and the public web surfaces (ADR-0077), and belongs to stage 0.
# Only TXT records whose name starts with `_acme-challenge.`; nothing else in
# the zone changes.
# ---------------------------------------------------------------------------

# _acme_records <zone id> — the JSON list of the challenge record sets.
_acme_records() {
  aws route53 list-resource-record-sets --hosted-zone-id "$1" --output json \
    | python3 -c '
import json, sys
sets = json.load(sys.stdin).get("ResourceRecordSets", [])
print(json.dumps([r for r in sets if r["Type"] == "TXT" and r["Name"].startswith("_acme-challenge.")]))'
}

acme_count() {
  local recs
  recs="$(_acme_records "$1")" || return 1
  printf '%s' "$recs" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'
}

acme_sweep() {
  local zone_id="$1" zone_name="$2" apex="${3:-}" recs n
  [ -n "$zone_id" ] && [ -n "$zone_name" ] || { echo "acme_sweep: no zone id or zone name" >&2; return 2; }
  if [ -n "$apex" ] && [ "${zone_name%.}" = "${apex%.}" ]; then
    echo "acme_sweep: refusing the APEX zone ${apex}: it carries the mail of the estate and belongs to stage 0" >&2
    return 2
  fi
  recs="$(_acme_records "$zone_id")" || { echo "acme_sweep: could not list the records of zone ${zone_id}" >&2; return 1; }
  n="$(printf '%s' "$recs" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')"
  if [ "$n" = 0 ]; then
    printf '  ✓ the %s zone holds no ACME challenge record\n' "$zone_name"
    return 0
  fi
  printf '%s' "$recs" | python3 -c '
import json, sys
print(json.dumps({"Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r in json.load(sys.stdin)]}))' \
    > "${WORK:-/tmp}/acme-batch.json"
  aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" \
      --change-batch "file://${WORK:-/tmp}/acme-batch.json" >/dev/null \
    || { echo "acme_sweep: the delete of ${n} ACME challenge record(s) in ${zone_name} failed" >&2; return 1; }
  printf '  ✓ deleted %s ACME challenge record(s) left in the %s zone\n' "$n" "$zone_name"
}
