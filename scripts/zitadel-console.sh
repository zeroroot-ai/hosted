#!/usr/bin/env bash
# zitadel-console.sh: open the Zitadel console of a cluster through a private
# path (ADR-0093, hosted#437). `make zitadel-console ENV=<env>` calls it with
# KUBECONFIG set for that cluster.
#
# The public edge has no route for the console or the Zitadel admin APIs.
# This script opens two port-forwards (Zitadel core and the Zitadel login),
# and puts lib/console-proxy.py in front of them on 127.0.0.1. A browser that
# maps the app host to that proxy then opens https://<app host>/ui/console,
# and Zitadel selects the right instance from the claimed host (ADR-0092).
# The Platform owner signs in there with MFA, the same as on the public host.
#
#   zitadel-console.sh                 print the browser command, then hold
#                                      the path open until Ctrl-C
#   zitadel-console.sh -- CMD [ARGS]   run CMD while the path is open, with
#                                      CONSOLE_URL, CONSOLE_PROXY_PORT and
#                                      CONSOLE_BROWSER_ARGS in its env
#
# Env: NS (default gibson), RELEASE (default gibson), CONSOLE_PORT (default
# 18443), ZITADEL_LOCAL_PORT (default 18480), LOGIN_LOCAL_PORT (default 18481)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/zitadel-console.sh
. "$HERE/lib/zitadel-console.sh"
NS="${NS:-gibson}"
RELEASE="${RELEASE:-gibson}"
CONSOLE_PORT="${CONSOLE_PORT:-18443}"
ZITADEL_LOCAL_PORT="${ZITADEL_LOCAL_PORT:-18480}"
LOGIN_LOCAL_PORT="${LOGIN_LOCAL_PORT:-18481}"

log() { printf '\033[0;32m▶\033[0m [zitadel-console] %s\n' "$*" >&2; }
die() { printf '\033[0;31m✗\033[0m [zitadel-console] %s\n' "$*" >&2; exit 1; }

for tool in kubectl python3 openssl curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH"
done
if [ "${1:-}" = "--" ]; then shift; [ "$#" -gt 0 ] || die "usage: zitadel-console.sh [-- CMD [ARGS]]"; fi

APP_HOST="$(kubectl -n "$NS" get configmap gibson-domains -o jsonpath='{.data.appHost}' 2>/dev/null)" || APP_HOST=""
[ -n "$APP_HOST" ] || die "the ConfigMap ${NS}/gibson-domains has no data.appHost, so the instance host is unknown"

WORK="$(mktemp -d)"
PF_PIDS=()
cleanup() {
  console_path_stop
  for pid in "${PF_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

forward() { # <service> <local port> <service port>
  ( while true; do
      kubectl -n "$NS" port-forward --address 127.0.0.1 "svc/$1" "$2:$3" >/dev/null 2>&1 || true
      sleep 1
    done ) &
  PF_PIDS+=($!)
}
log "port-forwarding svc/${RELEASE}-zitadel and svc/${RELEASE}-zitadel-login onto 127.0.0.1"
forward "${RELEASE}-zitadel" "$ZITADEL_LOCAL_PORT" 8080
forward "${RELEASE}-zitadel-login" "$LOGIN_LOCAL_PORT" 3000

console_path_start "$APP_HOST" "$ZITADEL_LOCAL_PORT" "$LOGIN_LOCAL_PORT" "$CONSOLE_PORT" "$WORK" \
  || { cat "$WORK/console-proxy.log" >&2 2>/dev/null; die "the private path did not answer on 127.0.0.1:${CONSOLE_PORT}"; }
CONSOLE_URL="https://${APP_HOST}/ui/console"
CONSOLE_BROWSER_ARGS="$(console_browser_args "$APP_HOST" "$CONSOLE_PORT")"
export CONSOLE_URL CONSOLE_PROXY_PORT="$CONSOLE_PORT" CONSOLE_BROWSER_ARGS
log "the console of ${APP_HOST} answers on the private path"

if [ "$#" -gt 0 ]; then
  "$@"
  exit $?
fi

cat >&2 <<MSG

Open the console in a browser profile of its own. Paste this line:

  google-chrome --user-data-dir="\$(mktemp -d)" ${CONSOLE_BROWSER_ARGS} ${CONSOLE_URL}

Sign in as the Platform owner with your password and your second factor.
The browser reaches ${APP_HOST} only through this path. Close the path with Ctrl-C.
MSG
wait "$CONSOLE_PROXY_PID"
