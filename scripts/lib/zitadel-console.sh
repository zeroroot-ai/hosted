# shellcheck shell=bash
# zitadel-console.sh: the private path to the Zitadel console (ADR-0093,
# hosted#437). Sourced by scripts/zitadel-console.sh (the verb) and by the
# exit tests that sign the Platform owner in.
#
#   console_path_start APP_HOST ZITADEL_PORT LOGIN_PORT LISTEN_PORT WORKDIR
#       Make a certificate for APP_HOST that lives for this run, and start
#       lib/console-proxy.py on 127.0.0.1:LISTEN_PORT in front of two local
#       ports: the Zitadel core forward and the Zitadel login forward. Sets
#       CONSOLE_PROXY_PID and CONSOLE_SPKI (the base64 SHA-256 of the key,
#       the value Chromium's --ignore-certificate-errors-spki-list takes).
#       Returns 1 when the proxy does not answer.
#   console_path_stop
#   console_browser_args APP_HOST LISTEN_PORT
#       Print the Chromium arguments that send APP_HOST to the proxy and
#       trust its one key.
#
# Nothing here reads a cluster. The caller opens the two port-forwards.

console_path_start() {
  local host="$1" zport="$2" lport="$3" listen="$4" work="$5"
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=${host}" -addext "subjectAltName=DNS:${host}" \
    -keyout "${work}/console.key" -out "${work}/console.crt" >/dev/null 2>&1 \
    || return 1
  chmod 600 "${work}/console.key"
  CONSOLE_SPKI="$(openssl x509 -in "${work}/console.crt" -pubkey -noout \
    | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"
  python3 "${here}/console-proxy.py" --listen "$listen" --host "$host" \
    --zitadel "$zport" --login "$lport" \
    --cert "${work}/console.crt" --key "${work}/console.key" 2>>"${work}/console-proxy.log" &
  CONSOLE_PROXY_PID=$!
  for _ in $(seq 1 30); do
    if curl -sk -o /dev/null --max-time 2 --resolve "${host}:${listen}:127.0.0.1" \
         "https://${host}:${listen}/.well-known/openid-configuration"; then
      return 0
    fi
    kill -0 "$CONSOLE_PROXY_PID" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

console_path_stop() {
  if [ -n "${CONSOLE_PROXY_PID:-}" ]; then
    kill "$CONSOLE_PROXY_PID" 2>/dev/null || true
    wait "$CONSOLE_PROXY_PID" 2>/dev/null || true
    CONSOLE_PROXY_PID=""
  fi
}

console_browser_args() {
  printf -- '--host-resolver-rules=MAP %s 127.0.0.1:%s --ignore-certificate-errors-spki-list=%s' \
    "$1" "$2" "$CONSOLE_SPKI"
}
