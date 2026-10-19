#!/usr/bin/env bash
# apex-zone-id.sh — print the id of the live zeroroot.ai hosted zone.
#
# substrate/apex-zone takes apex_zone_id as a REQUIRED variable with no
# default, so the live id is never committed (hosted#108, #111). Every plan
# reads it from the account it runs against instead: the exit test through
# the eks-plan-readonly role, an operator through their own credentials. One
# lookup, used by both, so the two never disagree and nothing stores the id.
#
# Usage:
#   TF_VAR_apex_zone_id="$(scripts/apex-zone-id.sh)" \
#     terraform -chdir=substrate/apex-zone plan -input=false -lock=false -detailed-exitcode
#
# Exits 1 with a message on stderr when the zone is not visible to the
# caller, so a wrong account fails here and not inside terraform.
set -euo pipefail

APEX_ZONE_NAME="${APEX_ZONE_NAME:-zeroroot.ai.}"

id="$(aws route53 list-hosted-zones-by-name --dns-name "$APEX_ZONE_NAME" --max-items 1 \
        --query "HostedZones[?Name=='${APEX_ZONE_NAME}'].Id | [0]" --output text)"
id="${id#/hostedzone/}"
if [ -z "$id" ] || [ "$id" = "None" ]; then
  who="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo 'these credentials')"
  echo "apex-zone-id: no hosted zone named ${APEX_ZONE_NAME} is visible to ${who}" >&2
  exit 1
fi
printf '%s\n' "$id"
