#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# reap-throwaway.sh — the backstop for the one window the instance's own
# ceiling cannot cover (ADR-0095).
#
#   reap-throwaway.sh <env> [--apply]     default is a dry run
#
# A throwaway environment has three things between it and an unnoticed bill, in
# order of how little they depend on:
#
#   1. the instance terminates itself, armed by its own cloud-init on every boot
#      (self_terminate_after_minutes). This needs no network and no credential,
#      so it survives a dead runner, a cancelled job and a lost state file.
#   2. the workflow tears the environment down, and ec2-post-destroy-verify.sh
#      asks the account what survived.
#   3. this, on a schedule.
#
# WHAT IS LEFT FOR 3. Two things 1 cannot do.
#
# An instance exists from the moment the API returns, and arms its ceiling when
# cloud-init runs, seconds to a minute later. A run that dies in that window
# leaves an instance that will never terminate itself. Small window, unbounded
# cost.
#
# And an Elastic IP is not an instance. It bills MORE when nothing is attached,
# which is the state a self-terminated instance leaves it in, and no amount of
# instance-side cleverness releases it.
#
# IT WILL NOT TOUCH A PERMANENT ENVIRONMENT. It refuses any env that is not on
# the throwaway list, because the whole point of ADR-0095 is that staging stays
# up, and a reaper that can be pointed at staging is a loaded gun. The list is
# here in the code, not in an argument.
# ---------------------------------------------------------------------------
set -uo pipefail

# Permanent environments are not on this list and must never be added. A reaper
# that accepts ENV=staging deletes the estate the owner asked to keep. The list
# is lib/throwaway-envs.sh, shared with the restore catch-up (D91).
# shellcheck source=lib/throwaway-envs.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/throwaway-envs.sh"

ENV_NAME="${1:-}"
APPLY="${2:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MAX_AGE_MINUTES="${MAX_AGE_MINUTES:-360}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
die() { printf "${RED}✗${NC} [reap] %s\n" "$*" >&2; exit 1; }

[ -n "$ENV_NAME" ] || die "usage: reap-throwaway.sh <env> [--apply]"
case " $THROWAWAY_ENVS " in
  *" $ENV_NAME "*) ;;
  *) die "ENV=$ENV_NAME is not a throwaway environment. This reaper deletes things; the only envs it accepts are: ${THROWAWAY_ENVS}. A permanent environment is never reaped (ADR-0095)" ;;
esac

if [ "$APPLY" = "--apply" ]; then
  mode="APPLY"
else
  mode="DRY RUN"
fi
echo "▶ [reap] ${mode}: Environment=${ENV_NAME} older than ${MAX_AGE_MINUTES}m in ${AWS_REGION}"

cutoff="$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$MAX_AGE_MINUTES")" \
  || die "could not compute the cutoff"

# A query that fails must not read as "nothing to do". Every list below is
# checked for a non-zero exit before it is acted on, because an empty result
# from expired credentials looks exactly like a clean account.
ids="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Environment,Values=${ENV_NAME}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[?LaunchTime<='${cutoff}'].InstanceId" --output text)" \
  || die "could not list instances. Nothing was reaped: a failed query is not an empty account"
ids="$(printf '%s' "$ids" | tr '\t' '\n' | grep -v '^$' || true)"

if [ -z "$ids" ]; then
  printf '%s  ✓%s no instance older than %sm\n' "$GREEN" "$NC" "$MAX_AGE_MINUTES"
else
  for id in $ids; do
    if [ "$mode" = APPLY ]; then
      echo "  terminating $id"
      aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$id" >/dev/null \
        || die "could not terminate ${id}. It is still billing; this needs a human"
    else
      echo "  would terminate $id"
    fi
  done
fi

# An unassociated Elastic IP is pure cost with nothing to show for it, so it is
# reaped regardless of age: for a throwaway environment there is no state in
# which one should be sitting there detached.
allocs="$(aws ec2 describe-addresses --region "$AWS_REGION" \
  --filters "Name=tag:Environment,Values=${ENV_NAME}" \
  --query 'Addresses[?AssociationId==null].AllocationId' --output text)" \
  || die "could not list addresses. Nothing further was reaped"
allocs="$(printf '%s' "$allocs" | tr '\t' '\n' | grep -v '^$' || true)"

if [ -z "$allocs" ]; then
  printf '%s  ✓%s no unassociated Elastic IP\n' "$GREEN" "$NC"
else
  for a in $allocs; do
    if [ "$mode" = APPLY ]; then
      echo "  releasing $a"
      aws ec2 release-address --region "$AWS_REGION" --allocation-id "$a" >/dev/null \
        || die "could not release ${a}. It is still billing; this needs a human"
    else
      echo "  would release $a"
    fi
  done
fi

printf '%s✓%s [reap] %s complete for Environment=%s\n' "$GREEN" "$NC" "$mode" "$ENV_NAME"
