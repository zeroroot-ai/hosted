#!/usr/bin/env bash
# Wrapper: 100 concurrent missions for 5 minutes against prod or a Kind
# cluster. Expects GIBSON_API_KEY + a pre-registered MissionDefinition.
#
# Usage:
#   bash 100-concurrent-missions.sh \
#     --target api.zeroroot.ai:443 \
#     --mission-def-id <id> \
#     --target-id <id>

set -euo pipefail

TARGET="${TARGET:-api.zeroroot.ai:443}"
MISSION_DEF_ID=""
TARGET_ID=""
CONCURRENCY="${CONCURRENCY:-100}"
DURATION="${DURATION:-5m}"
INSECURE="${INSECURE:-}"
REPORT="${REPORT:-load-report-$(date +%Y%m%d-%H%M%S).md}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)         TARGET="$2"; shift 2 ;;
    --mission-def-id) MISSION_DEF_ID="$2"; shift 2 ;;
    --target-id)      TARGET_ID="$2"; shift 2 ;;
    --concurrency)    CONCURRENCY="$2"; shift 2 ;;
    --duration)       DURATION="$2"; shift 2 ;;
    --insecure)       INSECURE="--insecure"; shift ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$MISSION_DEF_ID" ] || [ -z "$TARGET_ID" ]; then
  echo "error: --mission-def-id and --target-id required" >&2
  exit 1
fi

if [ -z "${GIBSON_API_KEY:-}" ]; then
  echo "error: GIBSON_API_KEY env var is required (do NOT pass the key on the CLI — it ends up in ps listings)" >&2
  exit 1
fi

cd "$(dirname "$0")"

go run . \
  -target "$TARGET" \
  -mission-def-id "$MISSION_DEF_ID" \
  -target-id "$TARGET_ID" \
  -concurrency "$CONCURRENCY" \
  -duration "$DURATION" \
  -api-key-env GIBSON_API_KEY \
  $INSECURE \
  -report "$REPORT"

echo "Report written to $REPORT"
