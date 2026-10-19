#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ec2-post-destroy-verify.sh — after a teardown of a plain-cluster environment,
# ask AWS what is still there (ADR-0070, ADR-0095).
#
#   ec2-post-destroy-verify.sh <env>
#
# WHY TERRAFORM'S OWN SUCCESS IS NOT THE ANSWER. `terraform destroy` reports on
# what it knows about. The resources that cost money after a failed teardown are
# the ones that outlive state: an Elastic IP whose association went away bills
# MORE unassociated than attached, a volume survives a half-destroy, and a
# resource terraform has no record of is invisible to a state query and fully
# visible on the bill. teardown-ec2.sh asserts that destroy returned 0 and that
# the instance left state. Neither of those is "it is gone".
#
# (The phrase for detaching a resource from state is deliberately not written
# here: scripts/check-no-retain.py keeps the retain vocabulary out of stage 1,
# and this file lives inside the stage 1 root.)
#
# WHY THIS IS TAG-SCOPED AND THE EKS ONE IS NOT. bootstrap/eks/gibson's verify
# asserts ZERO billable resources in the account, which it can because a prod
# teardown leaves nothing behind. A plain-cluster environment shares its account
# with staging, which is permanent by ADR-0095, so an account-wide assertion
# would read staging's own instance, EIP and VPC as survivors and fail every
# drill teardown. This asserts zero resources carrying
# `Environment=<env>`, which is the tag providers.tf puts on everything the root
# creates through default_tags.
#
# FAIL-CLOSED. "Queried successfully, found zero" and "the query failed" are
# different results. Expired credentials, throttling and a denied call all
# produce empty output, and an empty answer printed as a green zero is how a
# teardown that verified nothing reads as verified. Any query that does not
# return a number marks its class UNKNOWN and fails the run.
# ---------------------------------------------------------------------------
set -uo pipefail

ENV_NAME="${1:-}"
[ -n "$ENV_NAME" ] || { echo "usage: ec2-post-destroy-verify.sh <env>" >&2; exit 2; }
AWS_REGION="${AWS_REGION:-us-east-1}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
fail=0
unknown=0

# count <class> <command...> — the command must print one integer on stdout.
count() {
  local class="$1"; shift
  local out rc
  out="$("$@" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | grep -qE '^[0-9]+$'; then
    printf '%s  ? %s: UNKNOWN%s — the query did not return a count. An empty answer is not zero.\n' "$RED" "$class" "$NC"
    unknown=$((unknown + 1)); return
  fi
  if [ "$out" -ne 0 ]; then
    printf '%s  ✗ %s: %s still tagged Environment=%s%s\n' "$RED" "$class" "$out" "$ENV_NAME" "$NC"
    fail=$((fail + 1)); return
  fi
  printf '%s  ✓%s %s: 0\n' "$GREEN" "$NC" "$class"
}

echo "▶ [post-destroy] what still carries Environment=${ENV_NAME} in ${AWS_REGION}?"

# An instance in any state but terminated still bills, and `shutting-down` is a
# state a verify can race, so it counts as a survivor and the caller reruns.
count "instances" aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Environment,Values=${ENV_NAME}" \
            "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
  --query 'length(Reservations[].Instances[])' --output text

# An Elastic IP bills MORE when nothing is attached to it, which is exactly the
# state a terminated instance leaves it in.
count "elastic IPs" aws ec2 describe-addresses --region "$AWS_REGION" \
  --filters "Name=tag:Environment,Values=${ENV_NAME}" \
  --query 'length(Addresses[])' --output text

count "EBS volumes" aws ec2 describe-volumes --region "$AWS_REGION" \
  --filters "Name=tag:Environment,Values=${ENV_NAME}" \
  --query 'length(Volumes[])' --output text

count "VPCs" aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters "Name=tag:Environment,Values=${ENV_NAME}" \
  --query 'length(Vpcs[])' --output text

# The generic backstop (ADR-0070): anything else the root tagged, including
# classes this script does not know about yet, so a new resource in the root is
# covered the day it ships rather than the day somebody remembers it here.
#
# Stage 0 also carries Environment=<env>, and the tagging API returns EC2
# resources for a long time after their delete. tagged-survivors.py drops both,
# and counts the rest. A count of the raw list could never reach zero: the
# first live staging teardown (2026-10-06) failed here on the durable bucket,
# the zone and two terminated instances.
vpcs="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
          --filters "Name=tag:Environment,Values=${ENV_NAME}" \
          --query 'length(Vpcs[])' --output text 2>/dev/null || true)"
survivors() {
  local json
  json="$(aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" \
            --tag-filters "Key=Environment,Values=${ENV_NAME}" --output json)" || return 1
  printf '%s' "$json" | python3 "$HERE/tagged-survivors.py" "$ENV_NAME" "$vpcs" "$@"
}
count "any other tagged resource" survivors

# The ACME challenge records that a dead cluster left in the env zone (row 27
# of the drill path audit). They carry no tag, so the class needs the zone:
# the teardown exports ZONE_ID of substrate.env.
if [ -n "${ZONE_ID:-}" ]; then
  # shellcheck source=../../../../scripts/lib/acme-challenge.sh
  . "$HERE/../../../../scripts/lib/acme-challenge.sh"
  count "ACME challenge records in zone ${ZONE_ID}" acme_count "$ZONE_ID"
fi

if [ "$unknown" -ne 0 ]; then
  printf '%s✗ [post-destroy] %s class(es) UNKNOWN. The teardown is NOT verified: AWS did not answer, which is not the same as nothing being there.%s\n' "$RED" "$unknown" "$NC" >&2
  exit 1
fi
if [ "$fail" -ne 0 ]; then
  survivors --list 2>/dev/null | sed 's/^/    survivor: /' >&2 || true
  printf '%s✗ [post-destroy] %s class(es) still carry Environment=%s. Run the teardown again; it is idempotent.%s\n' "$RED" "$fail" "$ENV_NAME" "$NC" >&2
  exit 1
fi
printf '%s✓ [post-destroy] nothing carries Environment=%s: the environment is gone%s\n' "$GREEN" "$ENV_NAME" "$NC"
