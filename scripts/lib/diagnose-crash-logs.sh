#!/usr/bin/env bash
# diagnose-crash-logs.sh — what a crashlooping container said before it died.
#
# Run 34345134204 (2026-09-09): the fresh bringup never converged because
# gibson-0 (the platform neo4j) restarted 21 times in 86 minutes with exit
# code 64, and the diagnose step had events and no container log. This
# prints the last 40 lines of the PREVIOUS container for every container
# that restarted, and the current log for every container that is not
# Ready in a Running pod. Bounded to 12 pods so a wide outage does not
# drown the log. Read-only: kubectl get and kubectl logs.
set -uo pipefail
LIMIT="${1:-12}"
kubectl get pods -A -o json 2>/dev/null | python3 -c '
import json, sys
limit = int(sys.argv[1]); seen = 0
for p in json.load(sys.stdin).get("items", []):
    ns, name = p["metadata"]["namespace"], p["metadata"]["name"]
    for c in p.get("status", {}).get("containerStatuses", []) or []:
        if seen >= limit:
            break
        if c.get("restartCount", 0) > 0:
            print(ns, name, c["name"], "previous"); seen += 1
        elif not c.get("ready", False) and p["status"].get("phase") == "Running":
            print(ns, name, c["name"], "current"); seen += 1
' "$LIMIT" | while read -r ns pod c which; do
  echo "--- $ns/$pod [$c] ($which)"
  if [ "$which" = previous ]; then
    kubectl -n "$ns" logs "$pod" -c "$c" --previous --tail=40 2>&1 | cut -c1-300 || true
  else
    kubectl -n "$ns" logs "$pod" -c "$c" --tail=40 2>&1 | cut -c1-300 || true
  fi
done
