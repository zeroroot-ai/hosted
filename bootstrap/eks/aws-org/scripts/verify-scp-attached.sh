#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# verify-scp-attached.sh
#
# Asserts both SCPs are attached to the workload OU.
#
# Required env / authentication:
#   - aws CLI v2.
#   - Active AWS session against zeroroot-ai-mgmt with permission to call
#     organizations:ListPoliciesForTarget.
#
# Usage:
#   WORKLOAD_OU_ID=ou-xxxx-yyyyyyyy ./verify-scp-attached.sh
#
# Or, with terraform output piped in:
#   cd ../  # workspace root
#   WORKLOAD_OU_ID=$(terraform output -raw workload_ou_id) ./scripts/verify-scp-attached.sh
#
# Exit codes:
#   0 — both SCPs attached.
#   1 — one or more SCPs missing; missing list printed to stderr.
#   2 — usage / environmental error.
# ----------------------------------------------------------------------------

set -euo pipefail

readonly EXPECTED_SCPS=(
  "DenyRootUserActions"
  "DenyRegionsExceptUSEast1"
)

if [[ -z "${WORKLOAD_OU_ID:-}" ]]; then
  echo "ERROR: WORKLOAD_OU_ID env var must be set (ou-xxxx-yyyyyyyy)." >&2
  echo "Hint: WORKLOAD_OU_ID=\$(terraform output -raw workload_ou_id) $0" >&2
  exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found in PATH." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found in PATH." >&2
  exit 2
fi

# Identity check — give the operator a sanity print of which account they're hitting.
caller_arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "UNKNOWN")
echo "[verify-scp-attached] running as: ${caller_arn}"
echo "[verify-scp-attached] checking OU: ${WORKLOAD_OU_ID}"

# Pull the attached policy names.
attached_json=$(aws organizations list-policies-for-target \
  --target-id "${WORKLOAD_OU_ID}" \
  --filter SERVICE_CONTROL_POLICY \
  --output json)

attached_names=$(echo "${attached_json}" | jq -r '.Policies[].Name' | sort -u)
echo "[verify-scp-attached] currently attached:"
echo "${attached_names}" | sed 's/^/  - /'

missing=()
for expected in "${EXPECTED_SCPS[@]}"; do
  if ! grep -qx "${expected}" <<< "${attached_names}"; then
    missing+=("${expected}")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "" >&2
  echo "ERROR: missing SCPs on workload OU ${WORKLOAD_OU_ID}:" >&2
  for m in "${missing[@]}"; do
    echo "  - ${m}" >&2
  done
  echo "" >&2
  echo "Remediation: run \`terraform apply\` in enterprise/deploy/bootstrap/eks/aws-org/ from a session with org-management permissions." >&2
  exit 1
fi

echo ""
echo "[verify-scp-attached] OK: both SCPs attached."
exit 0
