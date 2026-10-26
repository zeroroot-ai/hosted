#!/usr/bin/env bash
# exit-test-rotation.sh: rotate each credential class through its normal path,
# and prove the path that uses it (hosted#444).
#
# Run it on a running env through the SSM forward:
#   make with-cluster ENV=drill CMD='test/rotation/exit-test-rotation.sh credential-classes.yaml <results.tsv>'
# drill.yml does that on a rotation dispatch (inputs rotation and rotation_run).
#
# The list is credential-classes.yaml. For each class on it:
#   status: tested   the script calls class_<test> (dashes become
#                    underscores). A failure fails the run.
#   another status   the script records the class as untested, with the
#                    `gap` text of the list. It does not fail the run: the
#                    scope of these classes is an open decision (hosted#444).
# scripts/check-rotation-classes.py keeps the tested classes and the class_*
# functions of this file the same.
#
# Each test changes a value at its SOURCE: an OpenBao key, or a cert-manager
# Certificate. No test writes a Kubernetes Secret (ADR-0014). A test READS a
# Secret only to know the old value, so that it can prove the old value fails.
#
# Output: one line per class in <results.tsv>:
#   <class> TAB pass|fail|untested TAB <reason>
# drill.yml opens one issue for each failed line of that file.
# When a class fails, the script also sends the alert CredentialRotationFailed
# to the Alertmanager of the env, which sends it by email. When no
# Alertmanager takes the alert, the script writes one more failed line for
# the alert itself.
#
# Env:
#   NS            the release namespace (default gibson)
#   RELEASE       the release name (default gibson)
#   MON_NS        the monitoring namespace (default monitoring)
#   CHARTS_ROOT   a checkout of zeroroot-ai/charts, for scripts/baseline-set-secret.sh
#   DAEMON_STS    the daemon StatefulSet (default: the one labeled component=daemon)
#   ROTATION_WAIT seconds to wait for one rotation (default 1500)
# Exit: 0 each tested class passed · 1 a tested class failed · 2 could not run
set -euo pipefail

# The restart of a platform workload is a pod delete (scripts/lib/restart-pods.sh):
# the identity admission policy denies a `rollout restart` of one.
# shellcheck source=../../scripts/lib/restart-pods.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/restart-pods.sh"

NS="${NS:-gibson}"
RELEASE="${RELEASE:-gibson}"
MON_NS="${MON_NS:-monitoring}"
# The daemon StatefulSet, found by its label: the release names it
# <release>-gibson-workloads, never a fixed name.
DAEMON_STS="${DAEMON_STS:-$(kubectl -n "$NS" get statefulset -l app.kubernetes.io/component=daemon \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)}"
DAEMON_STS="${DAEMON_STS:-${RELEASE}-gibson-workloads}"
ROTATION_WAIT="${ROTATION_WAIT:-1500}"
# The named waits of the classes. Each class declares its time bound from the
# same names (time_bound_of), so a wait and the bound cannot drift apart.
CHECK_ROLLOUT_S=60        # a rollout status that only checks a ready workload
ROLLOUT_WAIT_S=300        # a rollout status that waits for a restart
RESTART_WAIT_S=300        # restart_pods of ext-authz after a TLS or key change
EXT_AUTHZ_RESTART_WAIT_S=420  # restart_pods of ext-authz that waits for its registry fetch
RECONCILE_PASS_S=360      # one full reconcile of the platform-operator (every 5 minutes)
SETTLE_S=120              # the callers settle after the last restart
PG_ROLLOUT_S=600          # the most one consumer may take to roll onto a new login role

CLASSES="${1:-}"
RESULTS="${2:-}"
[ -n "$CLASSES" ] && [ -n "$RESULTS" ] || { echo "usage: exit-test-rotation.sh <credential-classes.yaml> <results.tsv>" >&2; exit 2; }
[ -s "$CLASSES" ] || { echo "could not run: no class list at ${CLASSES}" >&2; exit 2; }
# The time budget of this step, and which run of the plan this is (see "the
# time budget" below). drill.yml sets both. No default: a run with no budget
# could be stopped inside a class.
[[ "${ROTATION_BUDGET_S:-}" =~ ^[1-9][0-9]*$ ]] \
  || { echo "could not run: ROTATION_BUDGET_S is '${ROTATION_BUDGET_S:-}', not a number of seconds" >&2; exit 2; }
[[ "${ROTATION_RUN:-}" =~ ^[1-9][0-9]*$ ]] \
  || { echo "could not run: ROTATION_RUN is '${ROTATION_RUN:-}', not a run number" >&2; exit 2; }
START="$(date +%s)"
# A child run of one class (ROTATION_ONE_CLASS, see "the classes of the
# list") must not empty the results of its parent.
[ -n "${ROTATION_ONE_CLASS:-}" ] || : > "$RESULTS"

# A class function prints its steps and returns non-zero with the reason in
# $REASON. It never exits the script, so one failed class does not hide the
# next one.
REASON=""
miss() { REASON="$*"; printf '    ✗ %s\n' "$*" >&2; return 1; }
ok() { printf '    ✓ %s\n' "$*"; }
mask() { [ -z "${GITHUB_ACTIONS:-}" ] || printf '::add-mask::%s\n' "$1"; }

# new_password: 43 letters and digits, the shape of the OpenBao seed kind `pw`.
new_password() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 43; }

# STDIN_LOST and redis_cli: scripts/lib/redis-cli.sh. A reader in the pod
# that got no secret on stdin exits STDIN_LOST, and the caller sends the
# secret again. The same reader serves the restore (hosted#7).
. "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/redis-cli.sh"

# --- redis-password ----------------------------------------------------------
# Source: the OpenBao key gibson-redis-password. Path: ESO, and the CronJob
# <release>-redis-rotation, which restarts the redis clients by a pod delete
# and then removes the old password from the ACL.

# duration_s DURATION: the seconds of a Go duration such as 60s, 1m or 1h0m0s,
# or nothing for a value that is not one.
duration_s() {
  python3 -c '
import re, sys
v = sys.argv[1]
parts = re.findall(r"(\d+)(h|m|s)", v)
if not parts or "".join(n + u for n, u in parts) != v:
    sys.exit(1)
print(sum(int(n) * {"h": 3600, "m": 60, "s": 1}[u] for n, u in parts))' "$1" 2>/dev/null
}

# redis_rotation_wait EXTERNALSECRET: the seconds the class waits for the
# CronJob to finish one rotation. The CronJob ticks each minute, and its Job
# may run for activeDeadlineSeconds. A fixed wait of 1500 s was shorter than
# that limit of 1800 s, so a slow but correct rotation failed the class, and
# the CronJob then went on restarting pods under the next class (audit of
# 2026-10-19). The wait is the limit of the Job, one tick, and two refresh
# intervals of the ExternalSecret that writes the password (review of
# hosted#805). No limit and no interval are errors, never a default.
REDIS_TICK_S=60
redis_rotation_wait() {
  local limit every
  limit="$(kubectl -n "$NS" get cronjob "${RELEASE}-redis-rotation" \
    -o jsonpath='{.spec.jobTemplate.spec.activeDeadlineSeconds}' 2>/dev/null)" || limit=""
  [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ] || return 1
  every="$(kubectl -n "$NS" get externalsecret "$1" -o jsonpath='{.spec.refreshInterval}' 2>/dev/null)" || every=""
  every="$(duration_s "$every")" && [ "${every:-0}" -gt 0 ] || return 1
  printf '%s' $(( limit + REDIS_TICK_S + 2 * every ))
}
# The longest wait that the time bound of the class allows: the Job limit and
# the refresh interval of charts 0.151.1. A chart that raises either one
# changes this line, and the class refuses a longer wait before it starts.
REDIS_WAIT_MAX_S=$(( 1800 + REDIS_TICK_S + 2 * 60 ))

class_redis_password() {
  local es secret key state pod old new rv0 rv last start ips clients ip
  [ -n "${CHARTS_ROOT:-}" ] && [ -x "${CHARTS_ROOT}/scripts/baseline-set-secret.sh" ] \
    || { miss "CHARTS_ROOT holds no scripts/baseline-set-secret.sh, so the test cannot write the OpenBao key"; return 1; }
  es="$(kubectl -n "$NS" get externalsecrets -o json | jq -r '.items[]
        | select([.spec.data[]?.remoteRef.key] | index("gibson-redis-password")) | .metadata.name' | head -n1)"
  [ -n "$es" ] || { miss "no ExternalSecret reads the OpenBao key gibson-redis-password"; return 1; }
  secret="$(kubectl -n "$NS" get externalsecret "$es" -o jsonpath='{.spec.target.name}')"
  [ -n "$secret" ] || secret="$es"
  state="${RELEASE}-redis-rotation-state"
  pod="${RELEASE}-redis-stack-0"
  kubectl -n "$NS" get secret "$state" >/dev/null 2>&1 \
    || { miss "the rotation CronJob has not recorded its first state (${state}), so it would not see a rotation"; return 1; }
  local wait_s
  wait_s="$(redis_rotation_wait "$es")" \
    || { miss "the CronJob ${RELEASE}-redis-rotation has no Job time limit (activeDeadlineSeconds), or the ExternalSecret ${es} has no refresh interval, so the class cannot know how long a rotation may take"; return 1; }
  [ "$wait_s" -le "$REDIS_WAIT_MAX_S" ] \
    || { miss "a rotation may take ${wait_s}s, past the ${REDIS_WAIT_MAX_S}s of the time bound of the class: the chart raised the Job limit or the refresh interval, so raise REDIS_WAIT_MAX_S"; return 1; }

  key="$(kubectl -n "$NS" get externalsecret "$es" -o json | jq -r '(.spec.target.template.data // {}) | keys[0] // empty')"
  [ -n "$key" ] || { miss "the ExternalSecret ${es} names no key of the Secret ${secret}"; return 1; }
  old="$(kubectl -n "$NS" get secret "$secret" -o json | jq -r --arg k "$key" '.data[$k] // empty' | base64 -d)"
  [ -n "$old" ] || { miss "the Secret ${secret} holds no password"; return 1; }
  mask "$old"
  [ "$(redis_cli "$pod" "$old" PING)" = PONG ] || { miss "redis-stack refuses the current password before the rotation"; return 1; }
  rv0="$(kubectl -n "$NS" get secret "$secret" -o jsonpath='{.metadata.resourceVersion}')"
  new="$(new_password)"
  mask "$new"
  start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # 1. Rotate at the source.
  set_at_source gibson-redis-password password "$new" \
    || { miss "the write of the new value to the OpenBao key gibson-redis-password failed"; return 1; }
  ok "wrote a new value to the OpenBao key gibson-redis-password"

  # 2. The path runs: ESO writes the Secret, and the CronJob records the new
  #    version when the restarts are done and the old password is removed.
  local deadline=$(( $(date +%s) + wait_s ))
  while :; do
    rv="$(kubectl -n "$NS" get secret "$secret" -o jsonpath='{.metadata.resourceVersion}')"
    last="$(kubectl -n "$NS" get secret "$state" -o jsonpath='{.data.lastProcessedVersion}' | base64 -d 2>/dev/null || true)"
    if [ "$rv" != "$rv0" ] && [ "$last" = "$rv" ]; then break; fi
    [ "$(date +%s)" -lt "$deadline" ] \
      || { miss "the rotation did not finish in ${wait_s}s (Secret version ${rv0} -> ${rv}, CronJob state ${last:-empty})"; return 1; }
    sleep 15
  done
  ok "ESO wrote the new value, and the CronJob ${RELEASE}-redis-rotation finished its rotation"

  # 3. The service accepts the new value and refuses the old one.
  [ "$(redis_cli "$pod" "$new" PING)" = PONG ] || { miss "redis-stack refuses the new password"; return 1; }
  ok "redis-stack accepts the new password"
  # A refusal is an answer from redis-stack. A command that did not run (no
  # pod, no exec, no redis-cli) is not a refusal, and it fails the class.
  local out rc=0
  out="$(redis_cli "$pod" "$old" PING)" || rc=$?
  case "$out" in
    PONG) miss "redis-stack still accepts the old password after the rotation"; return 1 ;;
    *WRONGPASS*|*NOAUTH*|*"AUTH failed"*) ok "redis-stack refuses the old password" ;;
    *) miss "the check of the old password did not run (exit ${rc}): $(printf '%s' "$out" | head -n1)"; return 1 ;;
  esac

  # 4. The caller: each daemon pod started after the rotation, is Ready, and
  #    holds an authenticated connection to redis-stack.
  kubectl -n "$NS" rollout status statefulset/"$DAEMON_STS" --timeout="${CHECK_ROLLOUT_S}s" >/dev/null \
    || { miss "the daemon StatefulSet ${DAEMON_STS} is not ready after the rotation"; return 1; }
  local sel
  sel="$(kubectl -n "$NS" get statefulset "$DAEMON_STS" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
  ips="$(kubectl -n "$NS" get pods -l "$sel" -o json | jq -r --arg t "$start" \
          '.items[] | select(.status.startTime > $t) | .status.podIP')"
  [ -n "$ips" ] || { miss "no daemon pod started after the rotation, so no caller loaded the new password"; return 1; }
  clients="$(redis_cli "$pod" "$new" CLIENT LIST)"
  for ip in $ips; do
    printf '%s\n' "$clients" | grep -q "addr=${ip}:" \
      || { miss "the daemon pod at ${ip} has no connection to redis-stack after the rotation"; return 1; }
  done
  ok "each daemon pod started after the rotation and holds a connection to redis-stack"

  # 5. The other clients that read the password at start restarted onto it
  #    (charts#528): the tenant-operator, ext-authz and ratelimit.
  local d new_pods
  for d in gibson-tenant-operator gibson-ext-authz gibson-ratelimit; do
    kubectl -n "$NS" rollout status deployment/"$d" --timeout="${CHECK_ROLLOUT_S}s" >/dev/null \
      || { miss "${d} is not ready after the rotation"; return 1; }
    sel="$(kubectl -n "$NS" get deployment "$d" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
    new_pods="$(kubectl -n "$NS" get pods -l "$sel" -o json | jq -r --arg t "$start" \
      '[.items[] | select(.metadata.deletionTimestamp == null)] as $p | ($p | length) as $n | [$p[] | select(.status.startTime > $t)] | length == $n and $n > 0')"
    [ "$new_pods" = true ] || { miss "a pod of ${d} started before the rotation and still holds the old password"; return 1; }
  done
  ok "the tenant-operator, ext-authz and ratelimit restarted onto the new password"
}

# --- edge-tls ----------------------------------------------------------------
# Source: the Certificate gibson-envoy-edge. Path: cert-manager issues a new
# certificate from Let's Encrypt, and Envoy serves it on the public edge.
served_serial() {
  openssl s_client -connect "$1:443" -servername "$1" </dev/null 2>/dev/null \
    | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2
}

class_edge_tls() {
  local cert=gibson-envoy-edge host secret rev0 rev old new served
  command -v cmctl >/dev/null 2>&1 || { miss "cmctl is not on PATH, so the test cannot start the renewal"; return 1; }
  host="$(kubectl -n "$NS" get certificate "$cert" -o jsonpath='{.spec.dnsNames[0]}')"
  secret="$(kubectl -n "$NS" get certificate "$cert" -o jsonpath='{.spec.secretName}')"
  [ -n "$host" ] && [ -n "$secret" ] || { miss "the Certificate ${cert} names no host or no Secret"; return 1; }
  rev0="$(kubectl -n "$NS" get certificate "$cert" -o jsonpath='{.status.revision}')"
  old="$(served_serial "$host")"
  [ -n "$old" ] || { miss "https://${host} serves no certificate before the renewal"; return 1; }

  # 1. Rotate at the source.
  cmctl renew -n "$NS" "$cert" >/dev/null || { miss "cmctl renew ${cert} failed"; return 1; }
  ok "cert-manager started the renewal of ${cert} (revision ${rev0:-none})"

  # 2. The path runs: a new revision is Ready.
  local deadline=$(( $(date +%s) + ROTATION_WAIT ))
  while :; do
    rev="$(kubectl -n "$NS" get certificate "$cert" -o jsonpath='{.status.revision}')"
    if [ "${rev:-0}" -gt "${rev0:-0}" ] \
       && [ "$(kubectl -n "$NS" get certificate "$cert" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; then
      break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { miss "cert-manager did not issue a new revision of ${cert} in ${ROTATION_WAIT}s"; return 1; }
    sleep 15
  done
  # tls.crt is the public certificate. The script does not read the key.
  new="$(kubectl -n "$NS" get secret "$secret" -o jsonpath='{.data.tls\.crt}' | base64 -d \
         | openssl x509 -noout -serial | cut -d= -f2)"
  [ -n "$new" ] && [ "$new" != "$old" ] || { miss "revision ${rev} of ${cert} holds the same certificate as before"; return 1; }
  ok "cert-manager issued revision ${rev}, serial ${new}"

  # 3. The caller: a client on the internet gets the new certificate.
  while :; do
    served="$(served_serial "$host")"
    [ "$served" = "$new" ] && break
    [ "$(date +%s)" -lt "$deadline" ] || { miss "https://${host} still serves serial ${served:-none}, not the new ${new}"; return 1; }
    sleep 15
  done
  ok "https://${host} serves the new certificate"
}

# --- in-cluster listeners ----------------------------------------------------
# pf_serial POD PORT: the serial of the certificate that PORT of POD serves.
# A port-forward reaches a listener inside the cluster through the API, the
# same way each kubectl call of this script does. A listener that asks for a
# client certificate still sends its own certificate first.
pf_serial() {
  local pod="$1" port="$2" lport pid serial=""
  lport=$(( 20000 + RANDOM % 20000 ))
  kubectl -n "$NS" port-forward "pod/${pod}" "${lport}:${port}" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    serial="$(openssl s_client -connect "127.0.0.1:${lport}" </dev/null 2>/dev/null \
      | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2)"
    [ -n "$serial" ] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf '%s' "$serial"
}

# pf_pem POD PORT: the PEM of the certificate that PORT of POD serves.
pf_pem() {
  local pod="$1" port="$2" lport pid pem=""
  lport=$(( 20000 + RANDOM % 20000 ))
  kubectl -n "$NS" port-forward "pod/${pod}" "${lport}:${port}" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pem="$(openssl s_client -connect "127.0.0.1:${lport}" </dev/null 2>/dev/null | openssl x509 2>/dev/null)"
    [ -n "$pem" ] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf '%s\n' "$pem"
}

# pods_of SELECTOR: the names of the Running pods that match SELECTOR.
pods_of() {
  kubectl -n "$NS" get pods -l "$1" --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

# --- component-tls -----------------------------------------------------------
# Source: the cert-manager Certificates of the in-cluster TLS listeners. Path:
# cert-manager issues a new certificate, Reloader restarts the workload, and
# the listener serves the new certificate (ADR-0171). The old certificate is
# not revoked: the selfsigned CA has no revocation list. The old half of the
# check is that no pod serves the old serial any more.
#
# One line per Certificate: <Certificate> <pod selector> <port>.
COMPONENT_TLS="
gibson-daemon-metrics-tls app.kubernetes.io/component=daemon 9090
gibson-ext-authz-health-tls app.kubernetes.io/component=ext-authz 9002
gibson-openfga-http-tls app.kubernetes.io/name=openfga 8080
"

class_component_tls() {
  local cert sel port secret rev0 rev old new pods pod served deadline cafile bad
  cafile="$(mktemp)"
  # One deadline for the class. The daemon restart alone can take 15 minutes.
  deadline=$(( $(date +%s) + 2 * ROTATION_WAIT ))
  while read -r cert sel port; do
    [ -n "$cert" ] || continue
    kubectl -n "$NS" get certificate "$cert" >/dev/null 2>&1 \
      || { miss "the Certificate ${cert} does not exist"; rm -f "$cafile"; return 1; }
    secret="$(kubectl -n "$NS" get certificate "$cert" -o jsonpath='{.spec.secretName}')"
    pods="$(pods_of "$sel")"
    [ -n "$pods" ] || { miss "no Running pod matches ${sel}, so nothing serves ${cert}"; rm -f "$cafile"; return 1; }
    old="$(kubectl -n "$NS" get secret "$secret" -o jsonpath='{.data.tls\.crt}' | base64 -d \
           | openssl x509 -noout -serial | cut -d= -f2)"
    [ -n "$old" ] || { miss "the Secret ${secret} holds no certificate"; rm -f "$cafile"; return 1; }
    for pod in $pods; do
      served="$(pf_serial "$pod" "$port")"
      [ "$served" = "$old" ] || { miss "${pod}:${port} serves serial ${served:-none} before the renewal, not ${old} of ${secret}"; rm -f "$cafile"; return 1; }
    done
    rev0="$(kubectl -n "$NS" get certificate "$cert" -o jsonpath='{.status.revision}')"

    # 1. Rotate at the source.
    cmctl renew -n "$NS" "$cert" >/dev/null || { miss "cmctl renew ${cert} failed"; rm -f "$cafile"; return 1; }
    while :; do
      rev="$(kubectl -n "$NS" get certificate "$cert" -o jsonpath='{.status.revision}')"
      if [ "${rev:-0}" -gt "${rev0:-0}" ] \
         && [ "$(kubectl -n "$NS" get certificate "$cert" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; then
        break
      fi
      [ "$(date +%s)" -lt "$deadline" ] || { miss "cert-manager did not issue a new revision of ${cert} in ${ROTATION_WAIT}s"; rm -f "$cafile"; return 1; }
      sleep 15
    done
    new="$(kubectl -n "$NS" get secret "$secret" -o jsonpath='{.data.tls\.crt}' | base64 -d \
           | openssl x509 -noout -serial | cut -d= -f2)"
    [ -n "$new" ] && [ "$new" != "$old" ] || { miss "revision ${rev} of ${cert} holds the same certificate as before"; rm -f "$cafile"; return 1; }
    ok "cert-manager issued revision ${rev} of ${cert}, serial ${new}"

    # 2. The path runs: each pod serves the new certificate. Reloader
    #    restarts the workload, so the pod names can change.
    #    Each pod must serve the new serial, so no pod serves the old one.
    while :; do
      bad=""
      pods="$(pods_of "$sel")"
      for pod in $pods; do
        served="$(pf_serial "$pod" "$port")"
        [ "$served" = "$new" ] || { bad="${pod} serves ${served:-nothing}"; break; }
      done
      [ -n "$pods" ] && [ -z "$bad" ] && break
      [ "$(date +%s)" -lt "$deadline" ] || { miss "${bad:-no pod of ${sel} runs}: on :${port}, not the new serial ${new}"; rm -f "$cafile"; return 1; }
      sleep 15
    done
    ok "each pod of ${sel} serves the new certificate of ${cert} on :${port}, and none serves the old ${old}"

    # 3. The new certificate chains to the CA in its Secret.
    kubectl -n "$NS" get secret "$secret" -o jsonpath='{.data.ca\.crt}' | base64 -d > "$cafile"
    kubectl -n "$NS" get secret "$secret" -o jsonpath='{.data.tls\.crt}' | base64 -d \
      | openssl verify -CAfile "$cafile" >/dev/null 2>&1 \
      || { miss "the new certificate of ${cert} does not chain to its CA"; rm -f "$cafile"; return 1; }

    # 4. The caller. ext-authz calls OpenFGA over TLS at start: its startup
    #    self-check (fga.SelfCheck in buildChecker) exits on any x509 or TLS
    #    error, so a new ext-authz pod that becomes ready proves the TLS call
    #    with the new certificate. The metrics and health listeners have no
    #    working TLS client today: the Prometheus scrape of both is broken
    #    (charts#543), so the listener half above is their proof.
    if [ "$port" = 8080 ]; then
      restart_ext_authz "$RESTART_WAIT_S" \
        || { miss "ext-authz is not ready after a restart, so its TLS call to OpenFGA fails with the new certificate"; rm -f "$cafile"; return 1; }
      ok "a new ext-authz pod is ready, so its TLS call to OpenFGA works with the new certificate"
    fi
  done <<< "$COMPONENT_TLS"
  rm -f "$cafile"
}

# --- spire-svid --------------------------------------------------------------
# Source: the X.509 authority of the SPIRE server. Path: the authority
# rotation of SPIRE (`spire-server localauthority x509`): prepare a new
# authority, wait for the bundle to reach each agent, activate it, taint the
# old one so that each agent renews each SVID under the new authority, then
# revoke the old one, which removes it from the bundle (ADR-0171).
#
# The caller half: a new ext-authz pod fetches its authz registry from the
# daemon over SPIFFE mTLS at start and exits when that fails. So a restart of
# ext-authz that becomes ready proves mTLS between two workloads, after the
# taint and again after the revoke.
#
# The old half: the bundle of the server holds the old authority before the
# revoke and not after it, and a probe SVID that the test mints under the old
# authority no longer verifies against it, at a time inside the life of the
# probe. The test keeps only the certificate of the probe. mint_probe drops
# its key.
SPIRE_POD="${SPIRE_POD:-${RELEASE}-server-0}"
SPIRE_SOCKET="${SPIRE_SOCKET:-/tmp/spire-server/private/api.sock}"
SPIRE_PROPAGATE="${SPIRE_PROPAGATE:-180}"

spire() {
  kubectl -n "$NS" exec "$SPIRE_POD" -c spire-server -- \
    /opt/spire/bin/spire-server "$@" -socketPath "$SPIRE_SOCKET"
}

# mint_probe TTL TRUST_DOMAIN: print the certificate of a new probe SVID.
# The key that mint also prints is dropped here.
mint_probe() {
  local out
  out="$(spire x509 mint -spiffeID "spiffe://$2/drill/rotation-probe" -ttl "$1")" || return 1
  printf '%s\n' "$out" | openssl x509 2>/dev/null
}

# bundle_skis FILE: the subject key id of each certificate in a PEM bundle.
bundle_skis() {
  awk '/BEGIN CERTIFICATE/{n++} {print > (f "." n)}' f="$1.part" "$1"
  local c
  for c in "$1".part.*; do ski_of < "$c"; done
  rm -f "$1".part.*
}

# restart_ext_authz SECONDS: replace each ext-authz pod. A workload that wants
# 0 pods returns 0 from restart_pods with nothing restarted, and no new pod
# proves the new key or certificate. So the call fails then (hosted#12).
restart_ext_authz() {
  restart_pods "$NS" deployment/"${RELEASE}-ext-authz" "$1" || return 1
  [ "$RESTART_PODS_RESULT" = restarted ] \
    || { echo "ext-authz wants 0 pods, so no new pod started" >&2; return 1; }
}

# ext_authz_restarts_ready: restart ext-authz and wait until it is ready. A
# new ext-authz pod fetches its registry from the daemon over SPIFFE mTLS at
# start, and exits when the fetch fails.
ext_authz_restarts_ready() {
  restart_ext_authz "$EXT_AUTHZ_RESTART_WAIT_S"
}

# spire_bundle FILE: the X.509 roots of the trust bundle, as PEM.
spire_bundle() { spire bundle show -format pem > "$1"; }

# ski_of PEM: the subject key id of the certificate, lower-case hex.
ski_of() { openssl x509 -noout -ext subjectKeyIdentifier 2>/dev/null | tail -n1 | tr -d ' :' | tr 'A-F' 'a-f'; }
# aki_of PEM: the authority key id of the certificate, lower-case hex.
aki_of() { openssl x509 -noout -ext authorityKeyIdentifier 2>/dev/null | tail -n1 | sed 's/^ *keyid://' | tr -d ' :' | tr 'A-F' 'a-f'; }

class_spire_svid() {
  local td work show active prepared deadline pod p aki bad probe_t
  work="$(mktemp -d)"
  td="$(kubectl -n "$NS" get configmap "${RELEASE}-server" -o jsonpath='{.data.server\.conf}' \
        | jq -r '.server.trust_domain // empty')"
  [ -n "$td" ] || { miss "the SPIRE server config names no trust domain"; rm -rf "$work"; return 1; }
  show="$(spire localauthority x509 show -output json)" \
    || { miss "spire-server localauthority x509 show failed"; rm -rf "$work"; return 1; }
  active="$(printf '%s' "$show" | jq -r '(.active // {}) | .authority_id // .authorityId // empty' | tr 'A-F' 'a-f')"
  [ -n "$active" ] || { miss "the SPIRE server reports no active X.509 authority"; rm -rf "$work"; return 1; }

  # The probe under the old authority. The first certificate that mint
  # prints is the SVID. mint_probe drops the key.
  mint_probe 60m "$td" > "$work/probe.pem" \
    || { miss "spire-server x509 mint failed"; rm -rf "$work"; return 1; }
  [ -s "$work/probe.pem" ] || { miss "the minted probe has no certificate"; rm -rf "$work"; return 1; }
  probe_t="$(date +%s)"
  spire_bundle "$work/bundle0.pem" && [ -s "$work/bundle0.pem" ] \
    || { miss "spire-server bundle show failed before the rotation"; rm -rf "$work"; return 1; }
  openssl verify -attime "$probe_t" -CAfile "$work/bundle0.pem" "$work/probe.pem" >/dev/null 2>&1 \
    || { miss "the probe of the active authority does not verify before the rotation"; rm -rf "$work"; return 1; }
  [ "$(bundle_skis "$work/bundle0.pem" | grep -cx "$active")" = 1 ] \
    || { miss "the bundle does not hold the active authority ${active} before the rotation"; rm -rf "$work"; return 1; }

  # 1. Rotate at the source: prepare, wait for the bundle, activate, taint.
  spire localauthority x509 prepare -output json > "$work/prepare.json" \
    || { miss "spire-server localauthority x509 prepare failed"; rm -rf "$work"; return 1; }
  prepared="$(jq -r '(.prepared_authority // .preparedAuthority // {}) | .authority_id // .authorityId // empty' "$work/prepare.json" | tr 'A-F' 'a-f')"
  [ -n "$prepared" ] && [ "$prepared" != "$active" ] \
    || { miss "the prepare step gave no new authority"; rm -rf "$work"; return 1; }
  ok "prepared X.509 authority ${prepared}; waiting ${SPIRE_PROPAGATE}s for the bundle to reach each agent"
  deadline=$(( $(date +%s) + ROTATION_WAIT ))
  sleep "$SPIRE_PROPAGATE"
  spire localauthority x509 activate -authorityID "$prepared" >/dev/null \
    || { miss "spire-server localauthority x509 activate failed"; rm -rf "$work"; return 1; }
  spire localauthority x509 taint -authorityID "$active" >/dev/null \
    || { miss "spire-server localauthority x509 taint failed"; rm -rf "$work"; return 1; }
  ok "activated ${prepared} and tainted ${active}"

  # 2. The path runs: each daemon and ext-authz pod serves an SVID of the
  #    new authority on its SPIFFE listener.
  for p in "app.kubernetes.io/component=daemon 50051" "app.kubernetes.io/component=ext-authz 9001"; do
    set -- $p
    while :; do
      local pods
      bad=""
      pods="$(pods_of "$1")"
      for pod in $pods; do
        aki="$(pf_pem "$pod" "$2" | aki_of)"
        [ "$aki" = "$prepared" ] || { bad="${pod} serves an SVID of authority ${aki:-none}"; break; }
      done
      [ -n "$pods" ] && [ -z "$bad" ] && break
      [ "$(date +%s)" -lt "$deadline" ] || { miss "${bad:-no pod of $1 runs} on :$2, not ${prepared}"; rm -rf "$work"; return 1; }
      sleep 15
    done
    ok "each pod of $1 serves an SVID of the new authority on :$2"
  done
  ext_authz_restarts_ready \
    || { miss "a new ext-authz pod is not ready after the taint, so its mTLS call to the daemon fails"; rm -rf "$work"; return 1; }
  ok "a new ext-authz pod fetched its registry from the daemon over mTLS with SVIDs of the new authority"

  # 3. Revoke the old authority. The probe of the old authority no longer
  #    verifies against the bundle, and a probe of the new one does.
  spire localauthority x509 revoke -authorityID "$active" >/dev/null \
    || { miss "spire-server localauthority x509 revoke failed"; rm -rf "$work"; return 1; }
  spire_bundle "$work/bundle1.pem" && [ -s "$work/bundle1.pem" ] \
    || { miss "spire-server bundle show failed after the revoke"; rm -rf "$work"; return 1; }
  if bundle_skis "$work/bundle1.pem" | grep -qx "$active"; then
    miss "the bundle still holds the revoked authority ${active}"; rm -rf "$work"; return 1
  fi
  # At the mint time, so an expired probe cannot read as a refusal.
  if openssl verify -attime "$probe_t" -CAfile "$work/bundle1.pem" "$work/probe.pem" >/dev/null 2>&1; then
    miss "an SVID of the revoked authority ${active} still verifies against the bundle"; rm -rf "$work"; return 1
  fi
  ok "the bundle no longer holds the old authority, and an SVID of it is refused"
  ext_authz_restarts_ready \
    || { miss "a new ext-authz pod is not ready after the revoke"; rm -rf "$work"; return 1; }
  ok "a new ext-authz pod works with the bundle after the revoke"
  mint_probe 5m "$td" > "$work/probe-new.pem" && [ -s "$work/probe-new.pem" ] \
    || { miss "spire-server x509 mint failed after the revoke"; rm -rf "$work"; return 1; }
  openssl verify -CAfile "$work/bundle1.pem" "$work/probe-new.pem" >/dev/null 2>&1 \
    || { miss "an SVID of the new authority does not verify against the bundle"; rm -rf "$work"; return 1; }
  ok "an SVID of the new authority verifies"
  rm -rf "$work"
}

# --- shared ------------------------------------------------------------------
# secret_value SECRET KEY: the decoded value of KEY of SECRET, or nothing.
secret_value() {
  kubectl -n "$NS" get secret "$1" -o json 2>/dev/null | jq -r --arg k "$2" '.data[$k] // empty' | base64 -d 2>/dev/null
}

# set_at_source KEY PROPERTY VALUE: the write of a rotation at its source, the
# OpenBao key, through the same script that the redis class uses. From charts
# 0.147.0 the script takes the value on stdin only (charts#679).
#
# set_at_source --object KEY JSON: the same call writes several properties of
# KEY in ONE write (charts#738): the setter takes `--object KEY` as its two
# arguments and the JSON object on stdin, and it removes the one trailing
# newline. A slot of the CG signing key is two properties, kid and key. Two
# writes leave a slot with a key and no kid between them, which the daemon
# refuses, and the setter refuses the empty value of a clear.
set_at_source() {
  printf '%s\n' "$3" | NS="$NS" RELEASE="$RELEASE" "${CHARTS_ROOT}/scripts/baseline-set-secret.sh" "$1" "$2" >/dev/null
}

# bootstrap_ready: the PlatformBootstrap of the release reports Ready.
bootstrap_ready() {
  [ "$(kubectl get platformbootstrap -o json 2>/dev/null \
      | jq -r '[.items[0].status.conditions[]? | select(.type == "Ready")][0].status // empty')" = True ]
}

# --- openbao-service-tokens --------------------------------------------------
# Source: the OpenBao key gibson-service-token-rotation, property
# requested_at. Path: the openbao-auto-init sidecar mints a successor of each
# service token, writes its Secret, and revokes the old token by accessor 15
# minutes later (ADR-0171). Reloader restarts the tenant-operator, and the
# platform-operator follows its token file. Each configuration Job reads its
# token Secret when it starts.
SERVICE_TOKEN_SECRETS="gibson-platform-operator-vault gibson-tenant-operator-vault"
# The Job token Secrets. The two approle ones exist only when cert-manager
# reads OpenBao.
JOB_TOKEN_SECRETS="gibson-openbao-jwt-auth-init gibson-openbao-approle-init gibson-openbao-approle-reader"

# bao_token_status TOKEN: "ok" when OpenBao accepts TOKEN, "denied" when it
# answers 403, and "error: <text>" for any other result (no answer, a TLS
# error, a failed exec). The token goes on stdin. The openbao container sets
# BAO_ADDR (https) and BAO_CACERT for the TLS listener (charts#540).
bao_token_status() {
  local out rc
  for _ in 1 2 3 4; do
    rc=0
    out="$(printf '%s\n' "$1" | kubectl -n "$NS" exec -i "${RELEASE}-openbao-0" -c openbao -- \
      sh -c 'read -r t; [ -n "$t" ] || exit 97; BAO_TOKEN="$t" bao token lookup -format=json 2>&1 >/dev/null' 2>&1)" || rc=$?
    [ "$rc" -eq "$STDIN_LOST" ] || break
    sleep 1
  done
  if [ "$rc" -eq 0 ]; then
    printf 'ok'
  elif [ "$rc" -eq "$STDIN_LOST" ]; then
    printf 'error: the token did not reach bao on stdin in 4 tries'
  elif printf '%s' "$out" | grep -q 'Code: 403'; then
    printf 'denied'
  else
    printf 'error: %s' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  fi
}

class_openbao_service_tokens() {
  local s old new deadline start st secrets
  declare -A olds=()
  [ -n "${CHARTS_ROOT:-}" ] && [ -x "${CHARTS_ROOT}/scripts/baseline-set-secret.sh" ] \
    || { miss "CHARTS_ROOT holds no scripts/baseline-set-secret.sh, so the test cannot write the OpenBao key"; return 1; }
  # The two operator Secrets always, and each Job token Secret that exists.
  secrets="$SERVICE_TOKEN_SECRETS"
  for s in $JOB_TOKEN_SECRETS; do
    kubectl -n "$NS" get secret "$s" >/dev/null 2>&1 && secrets="$secrets $s"
  done
  for s in $secrets; do
    old="$(secret_value "$s" VAULT_ADMIN_TOKEN)"
    [ -n "$old" ] || { miss "the Secret ${s} holds no token"; return 1; }
    mask "$old"
    st="$(bao_token_status "$old")"
    [ "$st" = ok ] || { miss "OpenBao does not accept the token of ${s} before the rotation (${st})"; return 1; }
    olds[$s]="$old"
  done
  start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  deadline=$(( $(date +%s) + 2 * ROTATION_WAIT ))

  # 1. Rotate at the source.
  set_at_source gibson-service-token-rotation requested_at "$(date +%s)" \
    || { miss "the write of the rotation request failed"; return 1; }
  ok "asked for a rotation of the service tokens"

  # 2. The path runs: each Secret gets a successor that OpenBao accepts.
  for s in $secrets; do
    while :; do
      new="$(secret_value "$s" VAULT_ADMIN_TOKEN)"
      [ -n "$new" ] && [ "$new" != "${olds[$s]}" ] && break
      [ "$(date +%s)" -lt "$deadline" ] || { miss "the Secret ${s} still holds the old token"; return 1; }
      sleep 15
    done
    mask "$new"
    st="$(bao_token_status "$new")"
    [ "$st" = ok ] || { miss "OpenBao does not accept the new token of ${s} (${st})"; return 1; }
    ok "${s} holds a new token that OpenBao accepts"
  done
  kubectl -n "$NS" rollout status deployment/gibson-tenant-operator --timeout="${ROLLOUT_WAIT_S}s" >/dev/null \
    || { miss "the tenant-operator is not ready after its token changed"; return 1; }

  # 3. The old tokens are refused after the grace. Only a 403 counts as a
  #    refusal: any other failure is no answer, and fails the check.
  for s in $secrets; do
    while :; do
      st="$(bao_token_status "${olds[$s]}")"
      [ "$st" = denied ] && break
      [ "$st" = ok ] || { miss "OpenBao gave no answer about the old token of ${s} (${st})"; return 1; }
      [ "$(date +%s)" -lt "$deadline" ] || { miss "OpenBao still accepts the old token of ${s} after the grace"; return 1; }
      sleep 30
    done
    ok "OpenBao refuses the old token of ${s} (403)"
  done

  # 4. The callers. After the revoke, the platform-operator passes a full
  #    reconcile (every 5 minutes) with OpenBao, and the tenant-operator runs.
  sleep "$RECONCILE_PASS_S"
  bootstrap_ready || { miss "the PlatformBootstrap is not Ready after the old tokens were revoked"; return 1; }
  kubectl -n "$NS" rollout status deployment/gibson-tenant-operator --timeout="${CHECK_ROLLOUT_S}s" >/dev/null \
    || { miss "the tenant-operator is not ready after the old tokens were revoked"; return 1; }
  ok "the platform-operator and the tenant-operator work with the new tokens (since ${start})"
}

# --- zitadel-bringup-tokens --------------------------------------------------
# Source: the OpenBao keys gibson-zitadel-iam-admin-pat and
# gibson-zitadel-login-client-pat. Path: the platform-operator mints a
# successor when a token is older than 30 days, waits until the consumer
# Secret holds it for 10 minutes, and removes each other token of the user
# (ADR-0171). The test makes the token due by writing an old mint time at the
# source.
#
# One line per token: <OpenBao key> <consumer Secret>.
ZITADEL_TOKENS="
gibson-zitadel-iam-admin-pat iam-admin-pat
gibson-zitadel-login-client-pat login-client
"

# zitadel_user_status TOKEN: the HTTP status of GET /auth/v1/users/me with TOKEN
# (the token's own user),
# through a port-forward to the Zitadel Service (ADR-0092: the host travels in
# x-zitadel-instance-host).
zitadel_user_status() {
  local lport pid code="" domain
  domain="$(kubectl get platformbootstrap -o jsonpath='{.items[0].spec.zitadel.externalDomain}')"
  lport=$(( 20000 + RANDOM % 20000 ))
  kubectl -n "$NS" port-forward "svc/${RELEASE}-zitadel" "${lport}:8080" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$1" \
      | curl -s -o /dev/null -w '%{http_code}' -K - -H "x-zitadel-instance-host: ${domain}" \
          "http://127.0.0.1:${lport}/auth/v1/users/me" 2>/dev/null || true)"
    [ -n "$code" ] && [ "$code" != 000 ] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf '%s' "$code"
}

class_zitadel_bringup_tokens() {
  local key secret old new deadline code pending
  declare -A olds=() news=()
  [ -n "${CHARTS_ROOT:-}" ] && [ -x "${CHARTS_ROOT}/scripts/baseline-set-secret.sh" ] \
    || { miss "CHARTS_ROOT holds no scripts/baseline-set-secret.sh, so the test cannot write the OpenBao key"; return 1; }
  deadline=$(( $(date +%s) + 2 * ROTATION_WAIT ))
  # Each token takes about 23 minutes: the operator mints the new one, and it
  # removes the old one 10 minutes after the consumer holds the new one, twice
  # (tokenRetireGrace). One after the other, the two tokens used all of the
  # 50 minutes, and the second missed the deadline (drill run 39125128505).
  # So both tokens are made due first, and both are watched in one loop.
  while read -r key secret; do
    [ -n "$key" ] || continue
    old="$(secret_value "$secret" pat)"
    [ -n "$old" ] || { miss "the Secret ${secret} holds no token"; return 1; }
    mask "$old"
    [ "$(zitadel_user_status "$old")" = 200 ] || { miss "Zitadel refuses the token of ${secret} before the rotation"; return 1; }
    olds[$secret]="$old"
  done <<< "$ZITADEL_TOKENS"

  # 1. Rotate at the source: each token is due.
  while read -r key secret; do
    [ -n "$key" ] || continue
    set_at_source "$key" mintedAt 2000-01-01T00:00:00Z \
      || { miss "the write of an old mint time to ${key} failed"; return 1; }
    ok "made the token of ${key} due for rotation"
  done <<< "$ZITADEL_TOKENS"

  # 2. The path runs: each consumer Secret holds a new token that works.
  # 3. The old token is removed after the consumer holds the new one.
  while :; do
    pending=""
    while read -r key secret; do
      [ -n "$key" ] || continue
      old="${olds[$secret]}"
      if [ -z "${news[$secret]:-}" ]; then
        new="$(secret_value "$secret" pat)"
        if [ -n "$new" ] && [ "$new" != "$old" ]; then
          mask "$new"
          [ "$(zitadel_user_status "$new")" = 200 ] || { miss "Zitadel refuses the new token of ${secret}"; return 1; }
          ok "${secret} holds a new token that Zitadel accepts"
          news[$secret]="$new"
        else
          pending="${pending} ${secret}: still the old token;"
          continue
        fi
      fi
      [ "${news[$secret]}" != "retired" ] || continue
      code="$(zitadel_user_status "$old")"
      if [ "$code" = 401 ]; then
        ok "Zitadel refuses the old token of ${secret}"
        news[$secret]="retired"
      else
        pending="${pending} ${secret}: Zitadel answers ${code:-nothing} to the old token, not 401;"
      fi
    done <<< "$ZITADEL_TOKENS"
    [ -n "$pending" ] || break
    [ "$(date +%s)" -lt "$deadline" ] || { miss "the token rotation did not finish:${pending}"; return 1; }
    sleep 30
  done

  # 4. The callers: the login UI restarted onto the new token, and the
  #    platform-operator passes a full reconcile with the new admin token.
  kubectl -n "$NS" rollout status deployment/gibson-zitadel-login --timeout="${ROLLOUT_WAIT_S}s" >/dev/null \
    || { miss "zitadel-login is not ready after its token changed"; return 1; }
  sleep "$RECONCILE_PASS_S"
  bootstrap_ready || { miss "the PlatformBootstrap is not Ready after the old admin token was removed"; return 1; }
  ok "zitadel-login and the platform-operator work with the new tokens"
}

# --- keyring-generated-keys --------------------------------------------------
# Source: the bringup keyring file that stage 0 wrote on this runner
# (KEYRING_FILE, SUBSTRATE_ENV_FILE). The drill env lives for one run, so the
# check rotates its real keyring. Path: scripts/keyring.sh rotate and retire,
# scripts/keyring-to-cluster.sh (the one producer of the keyring Secret), and
# a restart of OpenBao or Velero (ADR-0171, ADR-0083).
#
# Seal key: the openbao container writes its seal stanza at start and logs
# "[openbao] seal key id keyring-<16 hex>", the first 16 hex of the sha256 of
# the key text (charts). Both halves:
#   - after rotate and retire, OpenBao starts unsealed on the new key alone;
#   - started with only the old key, OpenBao stays sealed.
# Velero password: the repository opens with the keyring password, and a
# backup run with another password does not complete.
OPENBAO_POD="${RELEASE}-openbao-0"

seal_id_of() { printf 'keyring-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-16)"; }

# k2c [KEYRING]: run the producer with the real keyring, or with KEYRING.
k2c() {
  KEYRING_FILE="${1:-$KEYRING_FILE}" NS="$NS" scripts/keyring-to-cluster.sh "$SUBSTRATE_ENV_FILE" >/dev/null
}

# bao_seal_state: "unsealed", "sealed", or "unknown", from the seal status
# that the openbao-auto-init sidecar reads over TLS.
bao_seal_state() {
  local st
  st="$(kubectl -n "$NS" exec "$OPENBAO_POD" -c openbao-auto-init -- \
        sh -c 'curl -sS https://127.0.0.1:8200/v1/sys/seal-status' 2>/dev/null || true)"
  case "$st" in
    *'"initialized":true'*'"sealed":false'*) echo unsealed ;;
    *'"initialized":true'*'"sealed":true'*) echo sealed ;;
    *) echo unknown ;;
  esac
}

# bao_restart WANT: delete the OpenBao pod and wait until it reports WANT.
BAO_DELETE_WAIT_S=180
BAO_STATE_WAIT_S=300
bao_restart() {
  local deadline
  kubectl -n "$NS" delete pod "$OPENBAO_POD" --wait=true --timeout="${BAO_DELETE_WAIT_S}s" >/dev/null || return 1
  deadline=$(( $(date +%s) + BAO_STATE_WAIT_S ))
  until [ "$(bao_seal_state)" = "$1" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# bao_ids: the seal key ids the openbao container runs on, in the shape of
# the line it logs at start ("[openbao] seal key id <cur>[, previous <prev>]").
# Read from the seal stanza the container wrote before `bao server`
# (/tmp/seal.hcl: key ids and file paths, never a key). Not from the log: the
# audit device writes to stdout, and the kubelet rotates the start line out
# in minutes, long before this class runs (second drill sweep, row 18).
bao_ids() {
  local hcl cur prev
  hcl="$(kubectl -n "$NS" exec "$OPENBAO_POD" -c openbao -- cat /tmp/seal.hcl 2>/dev/null || true)"
  cur="$(printf '%s\n' "$hcl" | sed -n 's/^ *current_key_id *= *"\([^"]*\)".*/\1/p' | head -1)"
  prev="$(printf '%s\n' "$hcl" | sed -n 's/^ *previous_key_id *= *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$cur" ] || return 0
  printf '[openbao] seal key id %s%s\n' "$cur" "${prev:+, previous $prev}"
}

# velero_backup: create a Backup of the OpenBao pod volume through the kopia
# repository, and print its final phase.
#
# Velero runs one backup at a time when their namespaces overlap, and every
# backup here covers the release namespace. The hourly Schedule can hold the
# queue for many minutes, and a backup that waits in the queue has no result
# (drill 38484872614, hosted#731). So the function first waits for each backup
# in flight, up to VELERO_QUEUE_WAIT. Its own backup then gets 900 s from the
# moment it leaves the queue, and the time in the queue counts against
# VELERO_QUEUE_WAIT. A timeout prints "timeout:<phase>", which is never a
# result of the repository password.
# 1200 s: an hourly backup of a cluster that is an hour old takes 5 to 8
# minutes (staging, hosted#731). The drill.yml step budget counts this wait.
VELERO_QUEUE_WAIT="${VELERO_QUEUE_WAIT:-1200}"
# The time of the backup itself, from the moment it leaves the queue.
VELERO_RUN_WAIT="${VELERO_RUN_WAIT:-900}"
VELERO_IN_FLIGHT_PHASES="New Queued ReadyToStart InProgress WaitingForPluginOperations WaitingForPluginOperationsPartiallyFailed Finalizing FinalizingPartiallyFailed"

# velero_in_flight: the backups of the velero namespace that have not ended,
# one name a line.
velero_in_flight() {
  local list
  list="$(kubectl -n velero get backups.velero.io -o json)" || return 1
  printf '%s' "$list" \
    | jq -r --arg ph "$VELERO_IN_FLIGHT_PHASES" '
        ($ph | split(" ")) as $p
        | .items[]
        | select((.status.phase // "New") as $s | $p | index($s))
        | .metadata.name'
}

# velero_storage_ready: every BackupStorageLocation of the velero namespace is
# Available, within VELERO_READY_WAIT. A Velero server that restarted a moment
# ago takes backups only after its controllers ran (drill rotation run 1,
# hosted#59 thread: a backup stayed with no phase for 20 minutes).
VELERO_READY_WAIT="${VELERO_READY_WAIT:-180}"
# VELERO_RESTARTED_AT: the start time (UTC, YYYY-MM-DDTHH:MM:SSZ) of the new
# Velero server pod, read from the cluster after the restart (velero_pod_start). The phase of a BackupStorageLocation survives a
# restart, so Available alone can be the phase of the old server. The new
# server validates the location again, and its lastValidationTime is later
# than this time. It is required: empty means not ready.
VELERO_RESTARTED_AT="${VELERO_RESTARTED_AT:-}"
# velero_pod_start: the start time of the newest Velero server pod, from the
# cluster. The reference of velero_storage_ready is a time of the cluster, not
# of the runner, and not the restartedAt annotation, which the client writes.
velero_pod_start() {
  local deadline start
  deadline=$(( $(date +%s) + VELERO_READY_WAIT ))
  while :; do
    start="$(kubectl -n velero get pods -l name=velero \
      -o jsonpath='{range .items[*]}{.status.startTime}{"\n"}{end}' 2>/dev/null | sort | tail -n1)" || start=""
    # An empty answer or a failed read is no reference time: it is read again,
    # then it is a failure. It never turns the time check off.
    [ -z "$start" ] || { printf '%s' "$start"; return 0; }
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

velero_storage_ready() {
  local deadline rows
  # No reference time, no check: a missing time never skips the comparison.
  [ -n "$VELERO_RESTARTED_AT" ] || return 1
  deadline=$(( $(date +%s) + VELERO_READY_WAIT ))
  while :; do
    rows="$(kubectl -n velero get backupstoragelocations.velero.io \
      -o jsonpath='{range .items[*]}{.status.phase} {.status.lastValidationTime}{"\n"}{end}' 2>/dev/null || true)"
    # Each location is Available and, when a restart time is known, validated
    # after it. An ISO time in UTC compares as text.
    if [ -n "$rows" ] && printf '%s\n' "$rows" | awk -v since="$VELERO_RESTARTED_AT" '
         NF == 0 { next }
         { n++ }
         $1 != "Available" { bad = 1 }
         since != "" && ($2 == "" || $2 < since) { bad = 1 }
         END { exit (n > 0 && !bad) ? 0 : 1 }'; then
      return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 10
  done
}

# velero_diagnose NAME: what the Velero server says when a backup is not
# picked up, on stderr. The next run then names the cause.
velero_diagnose() {
  {
    echo "    --- the Velero server, for backup $1 ---"
    kubectl -n velero get pods -o wide 2>&1 | sed 's/^/      /'
    kubectl -n velero get backupstoragelocations.velero.io 2>&1 | sed 's/^/      /'
    kubectl -n velero get backups.velero.io "$1" -o yaml 2>&1 | tail -n 40 | sed 's/^/      /'
    # The pod of the server, not deployment/velero: the node-agent pods carry
    # the labels of the Deployment selector, and kubectl logs takes the first
    # pod of the selector (drill 39461957621 printed the log of the node-agent).
    kubectl -n velero logs -l name=velero --tail=60 2>&1 | sed 's/^/      /'
  } >&2 || true
}

# velero_failed_volumes NAME: each PodVolumeBackup of the backup that did not
# complete, with its pod, volume, phase and message, on stderr. A backup that
# ends PartiallyFailed names no volume of its own: drill rotation run
# 40402546442 failed the keyring class on one, with no cause in the log.
velero_failed_volumes() {
  {
    echo "    --- the PodVolumeBackups of backup $1 that did not complete ---"
    kubectl -n velero get podvolumebackups.velero.io -l "velero.io/backup-name=$1" -o json 2>&1 \
      | jq -r '.items[] | select(.status.phase != "Completed")
               | "      \(.spec.pod.namespace)/\(.spec.pod.name) \(.spec.volume): \(.status.phase // "no phase") \(.status.message // "")"' 2>&1
    kubectl -n velero get backups.velero.io "$1" -o jsonpath='      errors={.status.errors} warnings={.status.warnings}{"\n"}' 2>&1
  } >&2 || true
}

# The name of the last backup that velero_backup made. velero_backup runs in a
# command substitution, so it hands the name over in this file.
VELERO_LAST_FILE="${VELERO_LAST_FILE:-$(mktemp)}"

# VELERO_PICKUP_WAIT: a new backup has a phase of the controller within this
# time. A backup with no phase after it was never picked up, and it is no
# result of the repository password. It is deleted, so that a later restart of
# the server on the right password does not run it, and the backup is made
# once more. A second miss is a timeout with the diagnostics.
VELERO_PICKUP_WAIT="${VELERO_PICKUP_WAIT:-240}"
VELERO_DELETE_WAIT="${VELERO_DELETE_WAIT:-60}"

# velero_delete_backup NAME: delete an unpicked backup and see that it is gone,
# within VELERO_DELETE_WAIT. A backup that stays would run when the server
# restarts on the keyring password, and it would end Completed.
velero_delete_backup() {
  local deadline out rc
  kubectl -n velero delete backups.velero.io "$1" --ignore-not-found --wait=false >/dev/null 2>&1 || return 1
  deadline=$(( $(date +%s) + VELERO_DELETE_WAIT ))
  while :; do
    # --ignore-not-found: exit 0 and no output is gone, exit 0 and a name is
    # still there, and a non-zero exit is an error (an API that does not
    # answer), which is not "gone". An error is read again until the deadline.
    rc=0
    out="$(kubectl -n velero get backups.velero.io "$1" --ignore-not-found -o name 2>/dev/null)" || rc=$?
    [ "$rc" -ne 0 ] || [ -n "$out" ] || return 0
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 5
  done
}

velero_backup() {
  local name phase="" deadline queue_deadline busy pickup_deadline attempt=0
  queue_deadline=$(( $(date +%s) + VELERO_QUEUE_WAIT ))
  while :; do
    # A list that cannot be read is not an empty queue.
    busy="$(velero_in_flight)" || busy="(the backup list could not be read)"
    [ -n "$busy" ] || break
    [ "$(date +%s)" -lt "$queue_deadline" ] || { printf 'timeout:queue (%s)' "$(printf '%s' "$busy" | tr '\n' ' ')"; return; }
    sleep 15
  done
  velero_storage_ready || { velero_diagnose "(none made yet)"; printf 'timeout:storage-location'; return; }
  while :; do
    attempt=$(( attempt + 1 ))
    name="rotation-drill-$(date +%s)-${attempt}"
    printf '%s' "$name" > "$VELERO_LAST_FILE"
    kubectl apply -f - >/dev/null <<YAML || { echo create-failed; return; }
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${name}
  namespace: velero
spec:
  includedNamespaces: ["${NS}"]
  labelSelector:
    matchLabels:
      app.kubernetes.io/component: openbao
  defaultVolumesToFsBackup: true
  ttl: 1h0m0s
YAML
    deadline=""
    pickup_deadline=$(( $(date +%s) + VELERO_PICKUP_WAIT ))
    while :; do
      phase="$(kubectl -n velero get backups.velero.io "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      case "$phase" in
        Completed|PartiallyFailed|Failed|FailedValidation) printf '%s' "$phase"; return ;;
        "")
          # No phase: the controller has not touched the backup.
          if [ "$(date +%s)" -ge "$pickup_deadline" ]; then
            velero_diagnose "$name"
            velero_delete_backup "$name" || { echo "stale backup ${name} could not be deleted" >&2; printf 'timeout:stale-backup'; return; }
            [ "$attempt" -lt 2 ] && continue 2
            printf 'timeout:unreconciled'; return
          fi ;;
        New|Queued|ReadyToStart)
          # Still in the queue: a Schedule fired between the wait and the create.
          [ "$(date +%s)" -lt "$queue_deadline" ] || { printf 'timeout:%s' "$phase"; return; } ;;
        *)
          [ -n "$deadline" ] || deadline=$(( $(date +%s) + VELERO_RUN_WAIT ))
          [ "$(date +%s)" -lt "$deadline" ] || { printf 'timeout:%s' "$phase"; return; } ;;
      esac
      sleep 15
    done
  done
}

# password_refused PHASE: true when PHASE, the end of a backup made with a
# repository password that is not the keyring password, is a refusal. Only
# Failed or PartiallyFailed is. A backup that never left the queue, never
# ended, or was refused before it ran says nothing about the password.
password_refused() {
  case "$1" in
    PartiallyFailed|Failed) return 0 ;;
    Completed) miss "a backup with a password that is not the keyring password completed" ;;
    FailedValidation) miss "the backup with another repository password failed validation, so it never read the repository" ;;
    timeout:unreconciled) miss "the Velero server did not pick up the backup with another repository password in two tries (no phase), so it proves no refusal. The diagnostics of the Velero server are above" ;;
    timeout:stale-backup) miss "a backup that Velero never picked up could not be deleted, so the restart on the keyring password would run it, and it would end Completed. Delete the Backup rotation-drill-* in the velero namespace and run again" ;;
    timeout:storage-location) miss "no BackupStorageLocation was Available after the restart of the Velero server, so no backup could start and the refusal is not proved. The diagnostics are above" ;;
    *) miss "the backup with another repository password did not end (${1:-no phase}), so it proves no refusal" ;;
  esac
}

velero_restart() {
  kubectl -n velero rollout restart deployment/velero >/dev/null \
    && kubectl -n velero rollout status deployment/velero --timeout="${ROLLOUT_WAIT_S}s" >/dev/null
}

# velero_refusal_step WORK: restart Velero on another repository password
# (WORK/velero.env), make a backup, restart it on the keyring password, and
# prove that the backup was refused. After each restart the reference time of
# the storage location check is the start time of the new Velero pod, read from
# the cluster, never the runner clock (hosted#68 review). The reference is
# read again after the second restart, for the backup that follows this step.
velero_refusal_step() {
  local work="$1" phase
  k2c "$work/velero.env" && velero_restart || { miss "Velero did not restart with another password"; k2c; velero_restart; return 1; }
  # Velero runs on the random password now. A miss here puts the keyring
  # password back and restarts it, as the failure path above does, or each
  # scheduled backup fails afterwards.
  VELERO_RESTARTED_AT="$(velero_pod_start)" \
    || { miss "the start time of the Velero pod could not be read, so the storage location check has no reference time"; k2c; velero_restart; return 1; }
  phase="$(velero_backup)"
  k2c && velero_restart || { miss "Velero did not restart with the keyring password"; return 1; }
  VELERO_RESTARTED_AT="$(velero_pod_start)" \
    || { miss "the start time of the Velero pod could not be read after the restart on the keyring password"; return 1; }
  password_refused "$phase" || return 1
  ok "a backup with another repository password does not complete (${phase})"
}

class_keyring_generated_keys() {
  local work old new ids phase
  [ -n "${KEYRING_FILE:-}" ] && [ -s "$KEYRING_FILE" ] && [ -n "${SUBSTRATE_ENV_FILE:-}" ] && [ -s "$SUBSTRATE_ENV_FILE" ] \
    || { miss "no KEYRING_FILE or SUBSTRATE_ENV_FILE on this runner: the keyring lives with stage 0"; return 1; }
  work="$(mktemp -d)"; chmod 700 "$work"
  cp -p "$KEYRING_FILE" "$work/orig.env"
  old="$(scripts/keyring.sh get "$KEYRING_FILE" OPENBAO_SEAL_KEY)"; mask "$old"
  [ -z "$(scripts/keyring.sh get "$KEYRING_FILE" OPENBAO_SEAL_KEY_PREVIOUS)" ] \
    || { miss "the keyring already holds a previous seal key: a rotation did not finish"; rm -rf "$work"; return 1; }

  # 0. The chart of this env writes the seal stanza with the key id. Without
  #    it a rotation would seal the store, so the check stops here.
  ids="$(bao_ids)"
  [ "$ids" = "[openbao] seal key id $(seal_id_of "$old")" ] \
    || { miss "the openbao container does not log the seal key id of the keyring (got: ${ids:-nothing}); its chart predates the seal key rotation"; rm -rf "$work"; return 1; }
  ok "OpenBao runs on the keyring seal key $(seal_id_of "$old")"

  # 1. Rotate at the source. OpenBao starts with both keys and rewraps.
  scripts/keyring.sh rotate "$KEYRING_FILE" OPENBAO_SEAL_KEY >/dev/null \
    || { miss "keyring.sh rotate failed"; rm -rf "$work"; return 1; }
  new="$(scripts/keyring.sh get "$KEYRING_FILE" OPENBAO_SEAL_KEY)"; mask "$new"
  if ! { k2c && bao_restart unsealed; }; then
    cp -p "$work/orig.env" "$KEYRING_FILE"; k2c; bao_restart unsealed || true
    miss "OpenBao did not start unsealed with the new and the previous seal key"; rm -rf "$work"; return 1
  fi
  [ "$(bao_ids)" = "[openbao] seal key id $(seal_id_of "$new"), previous $(seal_id_of "$old")" ] \
    || { miss "OpenBao did not log the new and the previous seal key id (got: $(bao_ids))"; rm -rf "$work"; return 1; }
  ok "OpenBao started unsealed with the new key $(seal_id_of "$new") and the previous key"

  # 2. Retire the old key. The new key alone opens the store.
  scripts/keyring.sh retire "$KEYRING_FILE" OPENBAO_SEAL_KEY >/dev/null \
    || { miss "keyring.sh retire failed"; rm -rf "$work"; return 1; }
  k2c && bao_restart unsealed \
    || { miss "OpenBao did not start unsealed with the new seal key alone: the store was not rewrapped"; rm -rf "$work"; return 1; }
  [ "$(bao_ids)" = "[openbao] seal key id $(seal_id_of "$new")" ] \
    || { miss "OpenBao did not log the new seal key id alone (got: $(bao_ids))"; rm -rf "$work"; return 1; }
  ok "OpenBao starts unsealed with the new seal key alone"

  # 3. The old key alone is refused: the store stays sealed. Then back.
  ( umask 077; grep -vE '^OPENBAO_SEAL_KEY(_PREVIOUS)?=' "$KEYRING_FILE" > "$work/old.env"
    printf 'OPENBAO_SEAL_KEY=%s\nOPENBAO_SEAL_KEY_PREVIOUS=\n' "$old" >> "$work/old.env" )
  local refused=0
  k2c "$work/old.env" && bao_restart sealed || refused=1
  k2c && bao_restart unsealed \
    || { miss "OpenBao did not return unsealed on the new seal key after the refusal test"; rm -rf "$work"; return 1; }
  [ "$refused" -eq 0 ] || { miss "OpenBao did not stay sealed under the old seal key alone"; rm -rf "$work"; return 1; }
  ok "OpenBao stays sealed under the old seal key, and opens again on the new one"
  kubectl -n "$NS" rollout status statefulset/"${RELEASE}-openbao" --timeout="${ROLLOUT_WAIT_S}s" >/dev/null \
    || { miss "OpenBao is not ready after the seal key rotation"; rm -rf "$work"; return 1; }

  # 4. Velero: the keyring password opens the repository, another does not.
  ( umask 077; grep -v '^VELERO_REPO_PASSWORD=' "$KEYRING_FILE" > "$work/velero.env"
    printf 'VELERO_REPO_PASSWORD=%s\n' "$(head -c 32 /dev/urandom | base64 -w0)" >> "$work/velero.env" )
  velero_refusal_step "$work" || { rm -rf "$work"; return 1; }
  phase="$(velero_backup)"
  if [ "$phase" != Completed ]; then
    velero_diagnose "$(cat "$VELERO_LAST_FILE")"
    velero_failed_volumes "$(cat "$VELERO_LAST_FILE")"
    miss "a backup with the keyring repository password ends ${phase}"; rm -rf "$work"; return 1
  fi
  ok "a backup with the keyring repository password completes"

  # 5. Back to the key of stage 0, through the same path. The drill keyring
  #    of stage 0 outlives this run, and the hourly Velero schedule may
  #    store the OpenBao volume: a store left on the rotated key would not
  #    open under that keyring after a restore.
  ( umask 077; grep -vE '^OPENBAO_SEAL_KEY(_PREVIOUS)?=' "$work/orig.env" > "$work/back.env"
    printf 'OPENBAO_SEAL_KEY=%s\nOPENBAO_SEAL_KEY_PREVIOUS=%s\n' "$old" "$new" >> "$work/back.env" )
  k2c "$work/back.env" && bao_restart unsealed \
    || { miss "OpenBao did not start unsealed on the way back to the stage 0 key"; rm -rf "$work"; return 1; }
  cp -p "$work/orig.env" "$KEYRING_FILE"
  k2c && bao_restart unsealed \
    || { miss "OpenBao did not start unsealed on the stage 0 key alone"; rm -rf "$work"; return 1; }
  [ "$(bao_ids)" = "[openbao] seal key id $(seal_id_of "$old")" ] \
    || { miss "OpenBao is not back on the stage 0 seal key (got: $(bao_ids))"; rm -rf "$work"; return 1; }
  ok "OpenBao is back on the stage 0 seal key, and the keyring file is the one stage 0 wrote"

  # The callers of OpenBao work after the restarts.
  sleep "$SETTLE_S"
  bootstrap_ready || { miss "the PlatformBootstrap is not Ready after the seal key rotation"; rm -rf "$work"; return 1; }
  ok "the PlatformBootstrap is Ready after the rotation"
  rm -rf "$work"
}

# --- neo4j-password ----------------------------------------------------------
# The platform Neo4j had no client, so it is deleted, not rotated (ADR-0171,
# D78, charts#563). Each tenant has its own Neo4j from the tenant-operator.
# The check proves that nothing of the platform Neo4j is left: no seed line,
# no ExternalSecret that reads its OpenBao key, no Secret, no workload and no
# Service. A credential that no reader can get cannot be used.
class_neo4j_password() {
  local st n
  [ -n "${CHARTS_ROOT:-}" ] && [ -x "${CHARTS_ROOT}/scripts/baseline-set-secret.sh" ] \
    || { miss "CHARTS_ROOT holds no charts checkout, so the test cannot read the seed table"; return 1; }
  if grep -q '^gibson-neo4j-password ' "${CHARTS_ROOT}/helm/gibson-workloads/files/openbao-seed-keys.txt"; then
    miss "the seed table of the charts checkout still generates gibson-neo4j-password"; return 1
  fi
  # No reader can get the value: no ExternalSecret reads the OpenBao key.
  # (The check does not log in to OpenBao: hosted holds no OpenBao login,
  # ADR-0009, hosted#417.)
  st="$(kubectl get externalsecret -A -o json \
    | jq -r '[.items[] | select([.spec.data[]?.remoteRef.key, .spec.dataFrom[]?.extract.key] | index("gibson-neo4j-password")) | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")')" \
    || { miss "the list of ExternalSecrets failed"; return 1; }
  [ -z "$st" ] || { miss "ExternalSecrets still read gibson-neo4j-password: ${st}"; return 1; }
  ok "no ExternalSecret reads the OpenBao key gibson-neo4j-password"
  for n in "secret/${RELEASE}-neo4j-auth" "secret/gibson-neo4j-auth" "statefulset/${RELEASE}-neo4j" \
           "statefulset/${RELEASE}" "service/${RELEASE}-neo4j" "service/${RELEASE}-neo4j-lb-neo4j"; do
    if kubectl -n "$NS" get "$n" >/dev/null 2>&1; then
      # The release StatefulSet named after the release was the Neo4j pod.
      if [ "$n" = "statefulset/${RELEASE}" ] && ! kubectl -n "$NS" get "$n" -o json \
           | jq -e '.spec.template.spec.containers[] | select(.name == "neo4j")' >/dev/null; then
        continue
      fi
      miss "the platform Neo4j object ${n} still exists"; return 1
    fi
  done
  [ -z "$(kubectl -n "$NS" get pods -l helm.neo4j.com/pod_category=neo4j-instance -o name 2>/dev/null)" ] \
    || { miss "a platform Neo4j pod still runs in ${NS}"; return 1; }
  st="$(kubectl -n "$NS" get secrets -o json | jq -r '[.items[] | select(.data.NEO4J_PASSWORD != null) | .metadata.name] | join(" ")')"
  [ -z "$st" ] || { miss "Secrets of ${NS} still carry NEO4J_PASSWORD: ${st}"; return 1; }
  ok "no key, Secret, workload or Service of the platform Neo4j exists"
}

# --- platform-signing-keys ---------------------------------------------------
# Source: the OpenBao keys gibson-cg-signing-key, -next and -previous. Path:
# the openbao-auto-init sidecar publishes a new kid in -next, promotes it to
# current 10 minutes later (previous = the old current), and clears -previous
# after the longest token life (ADR-0171, charts#555). The daemon reads the
# mount again when it changes.
#
# The check starts a rotation with the write of step 1. It does not wait the
# 25 hours of step 3: it writes the clear of -previous itself, the same write
# that the sidecar makes. The proof is the per-kid key route of each daemon
# pod, which ext-authz uses to verify a grant: the new kid answers 200, and
# after the clear the old kid answers 404, so a grant of the old key cannot
# verify.
CG_KEY_KEY="gibson-cg-signing-key"

# cg_kid_status POD KID CERT KEY BUNDLE: the HTTP status of the key route of
# POD for KID, over SPIFFE mTLS with the given client SVID.
cg_kid_status() {
  local lport pid code=""
  lport=$(( 20000 + RANDOM % 20000 ))
  kubectl -n "$NS" port-forward "pod/$1" "${lport}:8086" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code="$(printf 'GET /capabilitygrant/v1/keys/%s HTTP/1.1\r\nHost: gibson\r\nConnection: close\r\n\r\n' "$2" \
      | openssl s_client -quiet -verify_return_error -connect "127.0.0.1:${lport}" \
          -cert "$3" -key "$4" -CAfile "$5" 2>/dev/null | head -n1 | awk '{print $2}')"
    [ -n "$code" ] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf '%s' "$code"
}

# cg_all_pods WANT KID CERT KEY BUNDLE: wait until each daemon pod answers
# WANT for KID, or the deadline passes.
cg_all_pods() {
  local pod bad pods code
  while :; do
    bad=""
    pods="$(pods_of app.kubernetes.io/component=daemon)"
    for pod in $pods; do
      code="$(cg_kid_status "$pod" "$2" "$3" "$4" "$5")"
      [ "$code" = "$1" ] || { bad="${pod} answers ${code:-nothing} for kid $2"; break; }
    done
    [ -n "$pods" ] && [ -z "$bad" ] && return 0
    [ "$(date +%s)" -lt "$CG_DEADLINE" ] || { REASON="$bad"; return 1; }
    sleep 15
  done
}

# CG_SVID_SLACK_S: the time between the mint of the reader SVID and the start
# of CG_DEADLINE (the bundle read and the first port-forward), plus the length
# of the last check after the deadline.
CG_SVID_SLACK_S=300

class_platform_signing_keys() {
  local work td reader secret old new seed
  [ -n "${CHARTS_ROOT:-}" ] && [ -x "${CHARTS_ROOT}/scripts/baseline-set-secret.sh" ] \
    || { miss "CHARTS_ROOT holds no scripts/baseline-set-secret.sh, so the test cannot write the OpenBao key"; return 1; }
  work="$(mktemp -d)"; chmod 700 "$work"
  secret="${DAEMON_STS}-cg-signing-key"
  old="$(secret_value "$secret" current.kid)"
  [ -n "$old" ] || { miss "the Secret ${secret} holds no current kid"; rm -rf "$work"; return 1; }

  # A client SVID of the reader that the daemon admits on :8086. The key stays
  # in the temporary directory and is removed at the end. The SVID must live
  # to the end of the class: every check below runs until CG_DEADLINE, and the
  # sidecar promotes the next kid no sooner than 600 s after its write. A
  # lifetime of 10 minutes ended before the check after the promotion, so the
  # handshake failed and each pod "answered nothing" (audit of 2026-10-19).
  td="$(kubectl -n "$NS" get configmap "${RELEASE}-server" -o jsonpath='{.data.server\.conf}' \
        | jq -r '.server.trust_domain // empty')"
  reader="$(kubectl -n "$NS" get statefulset "$DAEMON_STS" -o json \
    | jq -r '[.spec.template.spec.containers[].env[]? | select(.name == "GIBSON_AUTHZ_REGISTRY_READER_SVIDS") | .value][0] // empty' \
    | tr ', ' '\n\n' | grep -m1 "^spiffe://${td}/")"
  [ -n "$td" ] && [ -n "$reader" ] || { miss "no trust domain or no reader SVID of the daemon key route"; rm -rf "$work"; return 1; }
  # x509 mint prints the SVID, then its private key, then the roots. The
  # first certificate is the SVID.
  ( umask 077; spire x509 mint -spiffeID "$reader" -ttl "$(( ROTATION_WAIT + CG_SVID_SLACK_S ))s" > "$work/mint.txt" ) \
    || { miss "spire-server x509 mint of the reader SVID failed"; rm -rf "$work"; return 1; }
  openssl x509 < "$work/mint.txt" > "$work/svid.pem" 2>/dev/null
  ( umask 077; awk '/BEGIN .*PRIVATE KEY/{k=1} k{print} /END .*PRIVATE KEY/{exit}' "$work/mint.txt" > "$work/key.pem" )
  rm -f "$work/mint.txt"
  spire_bundle "$work/bundle.pem"
  [ -s "$work/svid.pem" ] && [ -s "$work/key.pem" ] && [ -s "$work/bundle.pem" ] \
    || { miss "the reader SVID, its key or the bundle is missing"; rm -rf "$work"; return 1; }
  CG_DEADLINE=$(( $(date +%s) + ROTATION_WAIT ))
  cg_all_pods 200 "$old" "$work/svid.pem" "$work/key.pem" "$work/bundle.pem" \
    || { miss "before the rotation: ${REASON}"; rm -rf "$work"; return 1; }
  ok "each daemon pod serves the current kid ${old}"

  # 1. Rotate at the source: the write of step 1 of the sidecar.
  new="drill$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
  seed="$(head -c 32 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_')"
  # printf is a builtin, so the seed is on no argv. The kid and the seed are
  # URL-safe base64 and letters, so they need no JSON escape.
  set_at_source --object "${CG_KEY_KEY}-next" "$(printf '{"kid":"%s","key":"%s"}' "$new" "$seed")" \
    || { miss "the write of the next kid failed"; seed=""; rm -rf "$work"; return 1; }
  seed=""
  ok "published the next kid ${new} at the source"

  # 2. The path runs: each pod publishes the new kid, then the sidecar
  #    promotes it, and the old kid still verifies.
  cg_all_pods 200 "$new" "$work/svid.pem" "$work/key.pem" "$work/bundle.pem" \
    || { miss "the next kid did not reach each daemon pod: ${REASON}"; rm -rf "$work"; return 1; }
  ok "each daemon pod publishes the next kid ${new}"
  while [ "$(secret_value "$secret" current.kid)" != "$new" ]; do
    [ "$(date +%s)" -lt "$CG_DEADLINE" ] || { miss "the sidecar did not promote ${new} to current"; rm -rf "$work"; return 1; }
    sleep 30
  done
  [ "$(secret_value "$secret" previous.kid)" = "$old" ] \
    || { miss "after the promotion the previous slot does not hold ${old}"; rm -rf "$work"; return 1; }
  cg_all_pods 200 "$old" "$work/svid.pem" "$work/key.pem" "$work/bundle.pem" \
    || { miss "after the promotion the old kid does not verify: ${REASON}"; rm -rf "$work"; return 1; }
  ok "the sidecar promoted ${new}, and ${old} still verifies"

  # 3. Retire the old kid with the write of step 3. Each pod refuses it.
  set_at_source --object "${CG_KEY_KEY}-previous" '{"kid":"","key":""}' \
    || { miss "the clear of the previous slot failed"; rm -rf "$work"; return 1; }
  cg_all_pods 404 "$old" "$work/svid.pem" "$work/key.pem" "$work/bundle.pem" \
    || { miss "the old kid is still served after the clear: ${REASON}"; rm -rf "$work"; return 1; }
  cg_all_pods 200 "$new" "$work/svid.pem" "$work/key.pem" "$work/bundle.pem" \
    || { miss "the new kid is not served after the clear: ${REASON}"; rm -rf "$work"; return 1; }
  ok "each daemon pod refuses the old kid ${old} and serves ${new}"
  rm -rf "$work"
}

# --- postgres-role-passwords -------------------------------------------------
# Source: the OpenBao database engine, which issues a login role of each owner
# of a platform database (charts, ADR-0171). Path: ESO asks for a new login
# role every 24 hours, writes username and password, and Reloader restarts
# each consumer. A login role lives 48 hours: its password expires then
# (VALID UNTIL), and the engine drops the role.
#
# The check forces a new login role for each owner (an annotation that makes
# ESO refresh, the same refresh as the schedule), and proves:
#   - the Secret holds a new login role, a member of the owner;
#   - each consumer runs on it: Postgres shows sessions of the new role and
#     none of the old one;
#   - the old role has a password end at most 72 hours away (max_ttl), so
#     Postgres refuses it then, and the engine drops it.
# <Secret> <owner role> <consumer workload, or - when it connects on demand>
POSTGRES_LOGINS="
gibson-platform-postgres-credentials gibson_platform deployment/gibson-dashboard
tenant-admin-postgres-credentials tenant_admin -
zitadel-postgres-credentials zitadel deployment/gibson-zitadel
openfga-postgres-credentials openfga deployment/gibson-openfga
spire-postgres-credentials spire statefulset/gibson-server
"

# The SaaS overlay consumers of gibson_platform (billing, entitlements). They
# read the login role of gibson-platform-postgres-credentials too, so each
# must roll onto the new one.
POSTGRES_PLATFORM_CONSUMERS="deployment/gibson-billing-webhook deployment/gibson-entitlements-svc"

pg_su() {  # SQL: run as the Postgres superuser in the CNPG primary. A failed
  # exec or SQL error returns non-zero with its message on stderr, so a
  # caller never reads an empty answer as a result.
  local pod out
  pod="$(kubectl -n "$NS" get pods -l cnpg.io/cluster=platform-postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || { echo "pg_su: no primary pod of platform-postgres" >&2; return 1; }
  out="$(kubectl -n "$NS" exec "$pod" -c postgres -- psql -X -tA -v ON_ERROR_STOP=1 -d postgres -c "$1" 2>&1)" \
    || { printf 'pg_su: %s\n' "$out" >&2; return 1; }
  printf '%s\n' "$out"
}

# consumer_on_role <workload> <role> <since epoch> <deadline epoch>: the
# workload runs on <role>. Two proofs (hosted#591):
#   1. a new generation: every pod of the workload that is not being deleted
#      started after <since>, is Ready, and there are as many of them as the
#      workload wants. `rollout status` alone passed before Reloader had even
#      started the restart;
#   2. Postgres holds a session of <role> whose client address is one of
#      those pods. A session of the role from another workload proves
#      nothing about this one.
consumer_on_role() {
  local workload="$1" role="$2" since="$3" deadline="$4" sel want pods line name start ip gone ready
  local ips n_new n_old sessions
  sel="$(kubectl -n "$NS" get "$workload" -o jsonpath='{.spec.selector.matchLabels}' \
    | python3 -c 'import json,sys; print(",".join("%s=%s" % kv for kv in sorted(json.load(sys.stdin).items())))')" \
    || { miss "cannot read the pod selector of ${workload}"; return 1; }
  [ -n "$sel" ] || { miss "${workload} has no matchLabels selector"; return 1; }
  # A workload scaled to 0 has no pod to hold a session, and its IP list
  # would be empty. Refuse it now, not after the wait.
  want="$(kubectl -n "$NS" get "$workload" -o jsonpath='{.spec.replicas}')" \
    || { miss "cannot read the replicas of ${workload}"; return 1; }
  [ "${want:-1}" != 0 ] || { miss "${workload} has 0 replicas, so no pod of it can run on ${role}"; return 1; }
  while :; do
    want="$(kubectl -n "$NS" get "$workload" -o jsonpath='{.spec.replicas}')" \
      || { miss "cannot read the replicas of ${workload}"; return 1; }
    pods="$(kubectl -n "$NS" get pods -l "$sel" \
      -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{.status.startTime}{" "}{.status.podIP}{" "}{.metadata.deletionTimestamp}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}')" \
      || { miss "cannot list the pods of ${workload}"; return 1; }
    ips=() n_new=0 n_old=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      ready="${line##*|}"; line="${line%|*}"
      read -r name start ip gone <<< "$line"
      [ -z "${gone:-}" ] || continue
      if [ -n "$start" ] && [ "$(date -d "$start" +%s)" -gt "$since" ] && [ "$ready" = True ]; then
        n_new=$(( n_new + 1 )); ips+=("'${ip}'")
      else
        n_old=$(( n_old + 1 ))
      fi
    done <<< "$pods"
    [ "$n_old" = 0 ] && [ "$n_new" -ge "${want:-1}" ] && break
    [ "$(date +%s)" -lt "$deadline" ] \
      || { miss "${workload}: ${n_new} Ready pod(s) started after the rotation and ${n_old} other(s), want ${want:-1} new ones only"; return 1; }
    sleep 15
  done
  ok "${workload} runs a new generation: ${n_new} Ready pod(s), all started after the rotation"
  until sessions="$(pg_su "SELECT count(*) FROM pg_stat_activity WHERE usename = '${role}' AND host(client_addr) IN ($(IFS=,; echo "${ips[*]}"))")" \
        && [ "${sessions:-0}" -gt 0 ]; do
    [ "$(date +%s)" -lt "$deadline" ] \
      || { miss "${workload}: Postgres holds no session of ${role} from its pods (${ips[*]})"; return 1; }
    sleep 15
  done
  ok "${workload} holds ${sessions} session(s) of ${role} from its own pods"
}

class_postgres_role_passwords() {
  local secret owner workload old new deadline member sessions until left count forced_at
  declare -A olds=()
  deadline=$(( $(date +%s) + 2 * ROTATION_WAIT ))
  forced_at=$(date +%s)
  # 1. Force a new login role at the source, for each owner.
  while read -r secret owner workload; do
    [ -n "$secret" ] || continue
    old="$(secret_value "$secret" username)"
    [ -n "$old" ] || { miss "${secret} holds no login role"; return 1; }
    olds[$secret]="$old"
    kubectl -n "$NS" annotate externalsecret "$secret" "force-sync=$(date +%s)" --overwrite >/dev/null \
      || { miss "the refresh of ExternalSecret ${secret} failed"; return 1; }
  done <<< "$POSTGRES_LOGINS"
  ok "asked ESO for a new login role of each platform database"

  # 2. The path runs: each Secret holds a new member of its owner, and each
  #    consumer restarts onto it.
  while read -r secret owner workload; do
    [ -n "$secret" ] || continue
    old="${olds[$secret]}"
    until new="$(secret_value "$secret" username)" && [ -n "$new" ] && [ "$new" != "$old" ]; do
      [ "$(date +%s)" -lt "$deadline" ] || { miss "${secret} still holds the old login role"; return 1; }
      sleep 15
    done
    member="$(pg_su "SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE r.rolname = '${owner}' AND u.rolname = '${new}'")" \
      || { miss "could not read the members of ${owner} from Postgres"; return 1; }
    [ "$member" = 1 ] || { miss "the new login role of ${secret} is not a member of ${owner}"; return 1; }
    if [ "$workload" != - ]; then
      # The rollout counts against the class deadline, so the deadline bounds
      # the class (the time budget, review of hosted#805).
      left=$(( deadline - $(date +%s) ))
      [ "$left" -gt 0 ] || { miss "${workload}: the class deadline passed before its rollout"; return 1; }
      [ "$left" -le "$PG_ROLLOUT_S" ] || left="$PG_ROLLOUT_S"
      kubectl -n "$NS" rollout status "$workload" --timeout="${left}s" >/dev/null \
        || { miss "${workload} is not ready on the new login role"; return 1; }
      until sessions="$(pg_su "SELECT count(*) FILTER (WHERE usename = '${new}') || ' ' || count(*) FILTER (WHERE usename = '${old}') FROM pg_stat_activity")" \
            && [ "${sessions%% *}" -gt 0 ] && [ "${sessions##* }" = 0 ]; do
        [ "$(date +%s)" -lt "$deadline" ] || { miss "${workload}: sessions of the new and the old login role are ${sessions}"; return 1; }
        sleep 15
      done
      ok "${workload} runs on the new login role of ${owner}, and no session holds the old one"
    else
      ok "the login role of ${owner} is new (its consumer connects on demand)"
    fi

    # 3. The old role ends: it is gone, or its password expires within
    #    max_ttl. Two questions, so an empty answer is never a pass: does the
    #    role exist, and when it does, is its expiry a finite time.
    count="$(pg_su "SELECT count(*) FROM pg_roles WHERE rolname = '${old}'")" \
      || { miss "could not ask Postgres for the old login role of ${owner}"; return 1; }
    case "$count" in
      0) ok "the old login role of ${owner} is already gone" ;;
      1)
        until="$(pg_su "SELECT CASE WHEN rolvaliduntil IS NULL OR rolvaliduntil = 'infinity' THEN 'never' ELSE extract(epoch FROM rolvaliduntil)::bigint::text END FROM pg_roles WHERE rolname = '${old}'")" \
          || { miss "could not read the expiry of the old login role of ${owner}"; return 1; }
        [[ "$until" =~ ^[0-9]+$ ]] \
          || { miss "the old login role of ${owner} has no finite expiry (${until:-empty}): its password never ends"; return 1; }
        left=$(( until - $(date +%s) ))
        [ "$left" -le $(( 72 * 3600 )) ] || { miss "the old login role of ${owner} is valid for ${left} more seconds, past max_ttl"; return 1; }
        ok "Postgres refuses the old login role of ${owner} in $(( left / 3600 )) hours at the latest"
        ;;
      *) miss "Postgres gave '${count}' for the count of the old login role of ${owner}"; return 1 ;;
    esac
  done <<< "$POSTGRES_LOGINS"

  # The SaaS overlay consumers of gibson_platform run on the new role too:
  # each one restarted after the rotation, and each one holds a session of
  # the new role from its own pods (hosted#591).
  new="$(secret_value gibson-platform-postgres-credentials username)"
  [ -n "$new" ] || { miss "gibson-platform-postgres-credentials holds no login role"; return 1; }
  for workload in $POSTGRES_PLATFORM_CONSUMERS; do
    consumer_on_role "$workload" "$new" "$forced_at" "$deadline" || return 1
  done

  sleep "$SETTLE_S"
  bootstrap_ready || { miss "the PlatformBootstrap is not Ready after the new login roles"; return 1; }
}

# --- platform-generated-secrets ----------------------------------------------
# Three secrets that the platform generates (ADR-0171, row
# platform-generated-secrets). Each is rotated at its source, an OpenBao key,
# with the write that the sidecar makes, and each proves both halves.
#
# System API key (charts#570): two slots, each with its own System API user.
#   The check makes the other slot active. A JWT signed with the new key works
#   at once; the old key keeps working until the sidecar gives the old slot a
#   new key, 15 minutes after the flip, and then Zitadel refuses it.
# Masterkey (charts#572): the check writes `next`. The CronJob proves the
#   marker, rewraps the Zitadel keys and moves `next` to `value`. Zitadel then
#   serves with the new masterkey, and the marker no longer opens with the
#   old one.
# Session secret (charts#553): the check writes previous = old and a new
#   secret, the write of a seed rotation. The dashboard then runs with both.
#   A second rotation drops the first secret, which the dashboard then refuses.
DASHBOARD_SECRETS="${DASHBOARD_SECRETS:-${DAEMON_STS}-dashboard-secrets}"

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

# zitadel_admin_status TOKEN: the HTTP status of GET /admin/v1/orgs/default with
# the bearer TOKEN, through a port-forward to Zitadel. The token goes to curl
# on stdin, never on its command line.
zitadel_admin_status() {
  local domain lport pid code=""
  domain="$(kubectl get platformbootstrap -o jsonpath='{.items[0].spec.zitadel.externalDomain}')"
  lport=$(( 20000 + RANDOM % 20000 ))
  kubectl -n "$NS" port-forward "svc/${RELEASE}-zitadel" "${lport}:8080" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code="$(printf 'header = "Authorization: Bearer %s"\n' "$1" \
      | curl -s -o /dev/null -w '%{http_code}' -K - -H "x-zitadel-instance-host: ${domain}" \
          "http://127.0.0.1:${lport}/admin/v1/orgs/default" 2>/dev/null || true)"
    [ -n "$code" ] && [ "$code" != 000 ] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf '%s' "$code"
}

# system_jwt_status KEYFILE USER: zitadel_admin_status with a System API JWT that
# USER signs with KEYFILE (RS256).
system_jwt_status() {
  local domain now head body sig
  domain="$(kubectl get platformbootstrap -o jsonpath='{.items[0].spec.zitadel.externalDomain}')"
  now="$(date +%s)"
  head="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  body="$(jq -nc --arg u "$2" --arg a "https://${domain}" --argjson n "$now" \
    '{iss: $u, sub: $u, aud: $a, iat: $n, exp: ($n + 60)}' | b64url)"
  sig="$(printf '%s.%s' "$head" "$body" | openssl dgst -sha256 -sign "$1" | b64url)"
  zitadel_admin_status "${head}.${body}.${sig}"
}

# admin_pat_status: zitadel_admin_status with the PAT of the Zitadel admin
# (PlatformBootstrap spec.zitadel.adminTokenRef). A PAT is an opaque token
# that Zitadel decrypts with a key of system.encryption_keys, which the
# masterkey wraps. So a 200 proves that Zitadel opens its keys.
admin_pat_status() {
  local ref pat code rns rname rkey
  ref="$(kubectl get platformbootstrap -o json | jq -r --arg d "$NS" '.items[0].spec.zitadel.adminTokenRef | "\(.namespace // $d) \(.name) \(.key)"')"
  read -r rns rname rkey <<<"$ref"
  pat="$(kubectl -n "$rns" get secret "$rname" -o json 2>/dev/null | jq -r --arg k "$rkey" '.data[$k] // empty' | base64 -d)"
  [ -n "$pat" ] || return 0
  mask "$pat"
  code="$(zitadel_admin_status "$pat")"; pat=""
  printf '%s' "$code"
}

# zitadel_pods_after EPOCH: true when each pod of the Zitadel Deployment
# started after EPOCH and is Ready, so none runs on an older Secret.
zitadel_pods_after() {
  local sel
  sel="$(kubectl -n "$NS" get deployment "${RELEASE}-zitadel" -o json \
    | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
  kubectl -n "$NS" get pods -l "$sel" -o json | jq -e --argjson t "$1" '
    [.items[] | select(.metadata.deletionTimestamp == null)] as $p
    | ($p | length) > 0 and all($p[];
        (.status.startTime | fromdateiso8601) > $t
        and ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) > 0)' >/dev/null
}

# session_probe SECRET: in each running dashboard pod, make an Auth.js session
# token with SECRET (JWE dir A256CBC-HS512, the key and its kid derived as
# Auth.js does) and send it to /api/auth/session. Prints "accepted" when every
# pod returns the session, "refused" when none does, and "mixed" otherwise.
# It prints "error" when no dashboard pod runs, or when a pod gives no answer
# that is accepted or refused: an empty answer, a lost stdin ("lost"), or a
# response that is not an Auth.js session answer (a 5xx). Each of those is
# sent again, at most 4 times, before it counts. The secret goes to node on
# stdin.
SESSION_PROBE_JS='
const c = require("crypto");
let sec = "";
process.stdin.on("data", (d) => (sec += d)).on("end", async () => {
  sec = sec.trim();
  if (!sec) { process.stdout.write("lost"); return; }
  const name = (process.env.AUTH_URL || "").startsWith("https:") ? "__Secure-authjs.session-token" : "authjs.session-token";
  const key = Buffer.from(c.hkdfSync("sha256", sec, name, `Auth.js Generated Encryption Key (${name})`, 64));
  const u = (b) => Buffer.from(b).toString("base64url");
  const kid = u(c.createHash("sha512").update(JSON.stringify({ k: u(key), kty: "oct" })).digest());
  const now = Math.floor(Date.now() / 1000);
  const hdr = u(JSON.stringify({ alg: "dir", enc: "A256CBC-HS512", kid }));
  const body = JSON.stringify({ sub: "rotation-drill", name: "rotation drill", email: "rotation-drill@invalid",
    authIssuedAt: now, iat: now, exp: now + 300, jti: c.randomUUID() });
  const iv = c.randomBytes(16);
  const ci = c.createCipheriv("aes-256-cbc", key.subarray(32), iv);
  const ct = Buffer.concat([ci.update(body), ci.final()]);
  const aad = Buffer.from(hdr);
  const al = Buffer.alloc(8); al.writeBigUInt64BE(BigInt(aad.length * 8));
  const tag = c.createHmac("sha512", key.subarray(0, 32)).update(Buffer.concat([aad, iv, ct, al])).digest().subarray(0, 32);
  const jwe = [hdr, "", u(iv), u(ct), u(tag)].join(".");
  const r = await fetch(`http://127.0.0.1:${process.env.PORT || 3000}/api/auth/session`, { headers: { cookie: `${name}=${jwe}` } });
  if (!r.ok) { process.stdout.write("error"); return; }
  // Auth.js answers JSON, null for a cookie it does not accept. A body that
  // is not JSON is no answer.
  let j;
  try { j = await r.json(); } catch (e) { process.stdout.write("error"); return; }
  process.stdout.write(j && j.user && j.user.email === "rotation-drill@invalid" ? "accepted" : "refused");
});'
session_probe() {
  local pod out seen="" pods
  # No Running dashboard pod, or a probe with no answer, is an "error". It
  # was "refused" before, so a refusal check passed on nothing (review of
  # hosted#797).
  pods="$(pods_of app.kubernetes.io/component=dashboard)" || pods=""
  [ -n "$pods" ] || { printf 'error'; return 0; }
  for pod in $pods; do
    # Anything but accepted or refused (a lost stdin, an empty answer from a
    # dropped stdout frame, a failed exec, a 5xx) is sent again. One that
    # stays is neither accepted nor refused.
    for _ in 1 2 3 4; do
      out="$(printf '%s' "$1" | kubectl -n "$NS" exec -i "$pod" -c dashboard -- node -e "$SESSION_PROBE_JS" 2>/dev/null || true)"
      case "$out" in accepted|refused) break ;; esac
      sleep 1
    done
    case "$out" in accepted|refused) ;; *) out=error ;; esac
    case "$seen" in "") seen="$out" ;; "$out") ;; *) seen=mixed ;; esac
  done
  printf '%s' "$seen"
}

# The AES-CFB of the Zitadel masterkey (zitadel internal/crypto/aes.go), as
# the CronJob zitadel-masterkey-rotation does it.
mk_hex_of() { od -An -v -tx1 | tr -d ' \n'; }
mk_decrypt_text() {  # STRING KEY32: the plaintext of a Zitadel AESString
  local raw
  raw="$(printf '%s' "$1" | tr '_-' '/+' | base64 -d 2>/dev/null | mk_hex_of)"
  [ "${#raw}" -ge 32 ] || return 0
  printf '%b' "$(printf '%s' "${raw:32}" | sed 's/../\\x&/g')" \
    | openssl enc -d -aes-256-cfb -K "$(printf '%s' "$2" | mk_hex_of)" -iv "${raw:0:32}" -nopad 2>/dev/null
}

# zitadel_marker: the masterkey marker row, read as the Postgres superuser in
# the primary of platform-postgres.
zitadel_marker() {
  local pod
  pod="$(kubectl -n "$NS" get pods -l cnpg.io/cluster=platform-postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n "$NS" exec "$pod" -c postgres -- psql -X -tA -d zitadel \
    -c "SELECT marker FROM gibson_rotation.masterkey_marker WHERE id = 1" 2>/dev/null
}

# rotate_masterkey DEADLINE: the masterkey half of platform-generated-secrets.
# Two reference points must come BEFORE the write of `next` (audit of the
# drill path, 2026-10-19):
#   - Zitadel accepts its admin PAT. The check ran after the write, and when
#     it failed the class returned while the CronJob went on to rotate the
#     masterkey and restart Zitadel under the next class. The check now waits
#     for 200, so a Zitadel that is still restarting after the slot refresh
#     is not read as a refusal.
#   - The time the Secret still held the old masterkey. Reloader restarts
#     Zitadel seconds after ESO writes the new masterkey. The class saw the
#     new Secret up to 30 s later and then wanted a pod that started after
#     that, which no pod did. The restart is now dated from the last read
#     that still saw the old masterkey.
rotate_masterkey() {
  local deadline="$1" mk_old mk_new code t seen_old marker
  until code="$(admin_pat_status)" && [ "$code" = 200 ]; do
    [ "$(date +%s)" -lt "$deadline" ] \
      || { miss "Zitadel answers ${code:-nothing} to its admin PAT before the masterkey rotation, not 200"; return 1; }
    sleep 15
  done
  ok "Zitadel accepts its admin PAT before the masterkey rotation"
  # No Zitadel rollout may still run at the write. The slot refresh above
  # changes gibson-zitadel-system-key, and Reloader restarts Zitadel for it.
  # The old pod answers 200 while the new one starts, and a slow new pod
  # could start after the write and pass as the masterkey restart (review of
  # hosted#806).
  kubectl -n "$NS" rollout status deployment/"${RELEASE}-zitadel" \
      --timeout="$(( deadline > $(date +%s) ? deadline - $(date +%s) : 1 ))s" >/dev/null \
    || { miss "a rollout of ${RELEASE}-zitadel did not finish before the masterkey rotation"; return 1; }
  mk_old="$(secret_value gibson-zitadel-masterkey masterkey)"; mask "$mk_old"
  [ -n "$mk_old" ] || { miss "the Secret gibson-zitadel-masterkey holds no masterkey"; return 1; }
  mk_new="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 43)"; mask "$mk_new"
  seen_old="$(date +%s)"
  set_at_source zitadel-masterkey next "$mk_new" || { miss "the write of the next masterkey failed"; return 1; }
  ok "wrote the next masterkey at the source"
  # t is taken before each read. When the read still sees the old masterkey,
  # the change came after t, so each restart for it starts at t or later.
  # The poll is short, so a pod that started just before the change is not
  # inside the window.
  while :; do
    t="$(date +%s)"
    [ "$(secret_value gibson-zitadel-masterkey masterkey)" != "${mk_new:0:32}" ] || break
    seen_old="$t"
    [ "$t" -lt "$deadline" ] || { miss "the CronJob did not move the next masterkey to value"; return 1; }
    sleep 5
  done
  until zitadel_pods_after "$(( seen_old - 1 ))"; do
    [ "$(date +%s)" -lt "$deadline" ] || { miss "no Zitadel pod is Ready that started after the new masterkey"; return 1; }
    sleep 15
  done
  until code="$(admin_pat_status)" && [ "$code" = 200 ]; do
    [ "$(date +%s)" -lt "$deadline" ] \
      || { miss "Zitadel on the new masterkey answers ${code:-nothing} to its admin PAT, not 200: it does not open its encryption keys"; return 1; }
    sleep 15
  done
  marker="$(zitadel_marker)"
  [ "$(mk_decrypt_text "$marker" "${mk_new:0:32}")" = gibson-zitadel-masterkey-marker-v1 ] \
    || { miss "the masterkey marker does not open with the new masterkey"; return 1; }
  [ "$(mk_decrypt_text "$marker" "${mk_old:0:32}")" != gibson-zitadel-masterkey-marker-v1 ] \
    || { miss "the masterkey marker still opens with the old masterkey"; return 1; }
  ok "Zitadel restarted on the new masterkey and opens its keys (admin PAT), and the marker no longer opens with the old one"
}

class_platform_generated_secrets() {
  local work deadline old_user new_user other s_old s_new s_newer probe probe_old
  [ -n "${CHARTS_ROOT:-}" ] && [ -x "${CHARTS_ROOT}/scripts/baseline-set-secret.sh" ] \
    || { miss "CHARTS_ROOT holds no scripts/baseline-set-secret.sh, so the test cannot write the OpenBao keys"; return 1; }
  work="$(mktemp -d)"; chmod 700 "$work"
  deadline=$(( $(date +%s) + 2 * ROTATION_WAIT ))

  # --- the System API key ---
  old_user="$(secret_value gibson-zitadel-system-key user)"
  ( umask 077; secret_value gibson-zitadel-system-key private-key.pem > "$work/old.pem" )
  case "$old_user" in
    gibson-system-bot) other=b; new_user=gibson-system-bot-b ;;
    gibson-system-bot-b) other=a; new_user=gibson-system-bot ;;
    *) miss "gibson-zitadel-system-key names the user '${old_user}', not a slot user"; rm -rf "$work"; return 1 ;;
  esac
  [ "$(system_jwt_status "$work/old.pem" "$old_user")" = 200 ] \
    || { miss "Zitadel refuses the active System API key before the rotation"; rm -rf "$work"; return 1; }
  set_at_source gibson-zitadel-system-active slot "$other" \
    || { miss "the write of the active slot failed"; rm -rf "$work"; return 1; }
  ok "made slot ${other} (${new_user}) active at the source"
  until [ "$(secret_value gibson-zitadel-system-key user)" = "$new_user" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { miss "the operator mount still names ${old_user}"; rm -rf "$work"; return 1; }
    sleep 15
  done
  ( umask 077; secret_value gibson-zitadel-system-key private-key.pem > "$work/new.pem" )
  [ "$(system_jwt_status "$work/new.pem" "$new_user")" = 200 ] \
    || { miss "Zitadel refuses the new System API key of ${new_user}"; rm -rf "$work"; return 1; }
  [ "$(system_jwt_status "$work/old.pem" "$old_user")" = 200 ] \
    || { miss "Zitadel refuses the old System API key as soon as the new one works: no overlap"; rm -rf "$work"; return 1; }
  ok "Zitadel accepts the new System API key of ${new_user}, and still the old one"
  while [ "$(system_jwt_status "$work/old.pem" "$old_user")" != 401 ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { miss "Zitadel still accepts the old System API key of ${old_user}"; rm -rf "$work"; return 1; }
    sleep 60
  done
  ok "Zitadel refuses the old System API key of ${old_user} after the refresh of its slot"

  # --- the masterkey ---
  rotate_masterkey "$deadline" || { rm -rf "$work"; return 1; }

  # --- the session secret ---
  # A session made with a secret is accepted while the dashboard holds that
  # secret as AUTH_SECRET or AUTH_SECRET_PREVIOUS, and refused after.
  s_old="$(secret_value "$DASHBOARD_SECRETS" auth-secret)"; mask "$s_old"
  probe="$(session_probe "$s_old")"
  [ "$probe" = accepted ] \
    || { miss "the dashboard does not accept a session made with its own secret before the rotation (probe result: ${probe})"; rm -rf "$work"; return 1; }
  probe="$(session_probe "$(head -c 32 /dev/urandom | base64 -w0)")"
  [ "$probe" = refused ] \
    || { miss "the dashboard does not refuse a session made with a random secret (probe result: ${probe})"; rm -rf "$work"; return 1; }
  s_new="$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')"; mask "$s_new"
  set_at_source gibson-dashboard-session-secrets auth_secret_previous "$s_old" \
    && set_at_source gibson-dashboard-session-secrets auth_secret "$s_new" \
    || { miss "the write of the session secrets failed"; rm -rf "$work"; return 1; }
  until probe="$(session_probe "$s_new")"; [ "$probe" = accepted ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { miss "the dashboard does not accept a session made with the new secret (probe result: ${probe})"; rm -rf "$work"; return 1; }
    sleep 20
  done
  probe="$(session_probe "$s_old")"
  [ "$probe" = accepted ] \
    || { miss "the dashboard on the new secret does not accept a session made with the old one: sessions break (probe result: ${probe})"; rm -rf "$work"; return 1; }
  ok "the dashboard accepts sessions made with the new and with the old session secret"
  s_newer="$(head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '=')"; mask "$s_newer"
  set_at_source gibson-dashboard-session-secrets auth_secret_previous "$s_new" \
    && set_at_source gibson-dashboard-session-secrets auth_secret "$s_newer" \
    || { miss "the second write of the session secrets failed"; rm -rf "$work"; return 1; }
  until probe="$(session_probe "$s_newer")"; probe_old="$(session_probe "$s_old")"; [ "$probe" = accepted ] && [ "$probe_old" = refused ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { miss "after a second rotation the dashboard does not refuse a session made with the first secret (probe result for the newest: ${probe}, for the first: ${probe_old})"; rm -rf "$work"; return 1; }
    sleep 20
  done
  probe="$(session_probe "$s_new")"
  [ "$probe" = accepted ] \
    || { miss "after a second rotation the dashboard does not accept a session made with the previous secret (probe result: ${probe})"; rm -rf "$work"; return 1; }
  s_old=""; s_new=""; s_newer=""
  ok "after a second rotation the dashboard refuses a session made with the first secret"
  sleep "$SETTLE_S"
  bootstrap_ready || { miss "the PlatformBootstrap is not Ready after the rotations"; rm -rf "$work"; return 1; }
  rm -rf "$work"
}

# --- openfga-preshared-key ---------------------------------------------------
# Source: the OpenBao key gibson-openfga-preshared-key (key, key_previous).
# Path: ESO writes the Secret gibson-openfga-preshared-key, Reloader restarts
# OpenFGA with both keys, and each client reads its mounted key files again
# (charts#645, gibson#1091, ADR-0171). The check proves:
#   - OpenFGA refuses a call with no key;
#   - after one rotation OpenFGA accepts the new key and the old one;
#   - after a second rotation OpenFGA refuses the first key and accepts the
#     second and the third;
#   - the clients keep service through both rotations with no restart: each
#     daemon pod stays Ready the whole time, and its /readyz answers 200 at
#     the end. The daemon readiness runs an OpenFGA Check with the key of the
#     daemon, and a refused key makes it fail (gibson internal/server/daemon
#     readiness.go, probe authz_fga);
#   - no client logs a refused OpenFGA call during the rotations;
#   - ext-authz starts on the current key: its start self-check is an OpenFGA
#     Check, and a refused key stops the start.

# fga_status KEY: the HTTP status of an OpenFGA Check with KEY as the bearer
# token, through a port-forward to the OpenFGA Service. An empty KEY sends no
# key. The key goes to curl on stdin, never on an argv.
fga_status() {
  local lport pid code="" store
  store="$(kubectl -n "$NS" get configmap gibson-fga-config -o jsonpath='{.data.store_id}' 2>/dev/null)"
  [ -n "$store" ] || { printf 'no-store'; return 0; }
  lport=$(( 20000 + RANDOM % 20000 ))
  kubectl -n "$NS" port-forward "svc/${RELEASE}-openfga" "${lport}:8080" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code="$( { [ -z "$1" ] || printf 'header = "Authorization: Bearer %s"\n' "$1"; } \
      | curl -ks -o /dev/null -w '%{http_code}' -K - -H 'Content-Type: application/json' \
          --data '{"tuple_key":{"user":"user:rotation-drill","relation":"owner","object":"tenant:rotation-drill"}}' \
          "https://127.0.0.1:${lport}/stores/${store}/check" 2>/dev/null || true)"
    [ -n "$code" ] && [ "$code" != 000 ] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf '%s' "$code"
}

# daemons_ready: each daemon pod is Ready. Its readiness probe is /readyz,
# which runs an OpenFGA Check with the key of the daemon.
daemons_ready() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/component=daemon -o json \
    | jq -e '(.items | length) > 0 and all(.items[];
        ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) > 0)' >/dev/null
}

# daemon_readyz POD: the HTTP status of /readyz of POD, through a
# port-forward to its health port.
daemon_readyz() {
  local lport pid code=""
  lport=$(( 20000 + RANDOM % 20000 ))
  kubectl -n "$NS" port-forward "pod/$1" "${lport}:health" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:${lport}/readyz" 2>/dev/null || true)"
    [ -n "$code" ] && [ "$code" != 000 ] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf '%s' "$code"
}

# FGA_CLIENTS: the pod selectors of the OpenFGA clients that run all the time.
FGA_CLIENTS="app.kubernetes.io/component=daemon app.kubernetes.io/component=ext-authz app.kubernetes.io/name=gibson-tenant-operator app.kubernetes.io/name=gibson-platform-operator"

# refused_fga_calls SINCE: the count of log lines of the OpenFGA clients
# since SINCE (RFC 3339) that name a refused OpenFGA call.
refused_fga_calls() {
  local sel pod n=0 c
  for sel in $FGA_CLIENTS; do
    for pod in $(pods_of "$sel"); do
      c="$(kubectl -n "$NS" logs "$pod" --all-containers --since-time="$1" 2>/dev/null \
        | grep -ciE 'fga.*(401|unauthenticated|bearer token)|(401|unauthenticated).*fga' || true)"
      n=$(( n + ${c:-0} ))
    done
  done
  printf '%s' "$n"
}

# daemon_restarts: the name and the restart count of each daemon container,
# one pair a line, sorted.
daemon_restarts() {
  kubectl -n "$NS" get pods -l app.kubernetes.io/component=daemon -o json \
    | jq -r '.items[] | .metadata.name as $p | .status.containerStatuses[]? | "\($p)/\(.name) \(.restartCount)"' | sort
}

# KUBELET_SYNC_WAIT: the seconds the kubelet may take to write a changed
# Secret into the volume of a running pod (its sync period of 60 s, and the
# Secret cache), with a margin.
KUBELET_SYNC_WAIT=120
FGA_KEY_SECRET=gibson-openfga-preshared-key

# fga_key_mounts POD: one line for each container of POD that sets
# GIBSON_FGA_KEY_DIR: "ok <container> <dir>" when the directory is a volume of
# the Secret FGA_KEY_SECRET with no subPath, else "bad <container> <why>". A
# key read by subPath or by env never changes in a running pod, so for such a
# client a rotation is a mount defect, not a race (review of hosted#805).
# Nothing at all means no container of POD names the key directory.
fga_key_mounts() {
  kubectl -n "$NS" get pod "$1" -o json | python3 -c '
import json, sys
secret = sys.argv[1]
pod = json.load(sys.stdin)
spec = pod.get("spec") or {}
vols = {v.get("name"): v for v in spec.get("volumes") or []}
for c in spec.get("containers") or []:
    d = next((e.get("value") for e in c.get("env") or [] if e.get("name") == "GIBSON_FGA_KEY_DIR"), None)
    if d is None:
        continue
    m = next((m for m in c.get("volumeMounts") or [] if m.get("mountPath") == d), None)
    if m is None:
        print("bad %s no volume is mounted at %s" % (c["name"], d)); continue
    if m.get("subPath") or m.get("subPathExpr"):
        print("bad %s %s is mounted by subPath, which the kubelet never updates" % (c["name"], d)); continue
    src = ((vols.get(m.get("name")) or {}).get("secret") or {}).get("secretName")
    if src != secret:
        print("bad %s %s is not a volume of the Secret %s" % (c["name"], d, secret)); continue
    print("ok %s %s" % (c["name"], d))
' "$FGA_KEY_SECRET"
}

# fga_key_held POD CONTAINER DIR: the SHA-256 of the key file that CONTAINER of
# POD reads, read in the pod. The key itself never leaves the pod. Only an
# image with a shell can answer (the daemon); a distroless one cannot.
fga_key_held() {
  kubectl -n "$NS" exec "$1" -c "$2" -- sh -c 'tr -d "\r\n" < "$1/key" | sha256sum' _ "$3" 2>/dev/null | cut -c1-64
}

# wait_fga_clients KEY WRITTEN DEADLINE: each OpenFGA client holds KEY, which
# was written at the epoch WRITTEN. It replaces a fixed sleep of the kubelet
# bound (review of hosted#805):
#   - every client pod reads the key from a Secret volume with no subPath,
#     or the class fails at once;
#   - each daemon pod reads KEY back from its key file, polled until
#     DEADLINE;
#   - the other clients run distroless images, which cannot show their key.
#     Their volume is the same Secret, which the kubelet writes within its
#     sync period, so for them the class waits the rest of KUBELET_SYNC_WAIT
#     after WRITTEN.
wait_fga_clients() {
  local want sel pod line bad rest
  want="$(printf '%s' "$1" | sha256sum | cut -c1-64)"
  for sel in $FGA_CLIENTS; do
    for pod in $(pods_of "$sel"); do
      line="$(fga_key_mounts "$pod")" || { miss "cannot read the pod ${pod}"; return 1; }
      [ -n "$line" ] || { miss "no container of ${pod} names GIBSON_FGA_KEY_DIR, so it cannot read a rotated key"; return 1; }
      bad="$(printf '%s\n' "$line" | sed -n 's/^bad //p' | head -n1)"
      [ -z "$bad" ] || { miss "${pod}: ${bad}"; return 1; }
    done
  done
  while :; do
    bad=""
    for pod in $(pods_of app.kubernetes.io/component=daemon); do
      while read -r _ c d; do
        [ "$(fga_key_held "$pod" "$c" "$d")" = "$want" ] || { bad="${pod}/${c}"; break; }
      done <<< "$(fga_key_mounts "$pod")"
      [ -z "$bad" ] || break
    done
    [ -z "$bad" ] && break
    [ "$(date +%s)" -lt "$3" ] || { miss "${bad} does not hold the new OpenFGA key in its key file"; return 1; }
    sleep 10
  done
  rest=$(( $2 + KUBELET_SYNC_WAIT - $(date +%s) ))
  [ "$rest" -le 0 ] || sleep "$rest"
  ok "each daemon pod reads the new OpenFGA key back from its key file, and each client mounts the Secret as a volume"
}

# new_fga_key: 43 URL-safe base64 characters, the shape of the seed kind rand.
new_fga_key() { head -c 32 /dev/urandom | base64 -w0 | tr '+/' '-_' | tr -d '='; }

class_openfga_preshared_key() {
  local k0 k1 k2 deadline since pod refused restarts written unready=0
  [ -n "${CHARTS_ROOT:-}" ] && [ -x "${CHARTS_ROOT}/scripts/baseline-set-secret.sh" ] \
    || { miss "CHARTS_ROOT holds no scripts/baseline-set-secret.sh, so the test cannot write the OpenBao key"; return 1; }
  k0="$(secret_value gibson-openfga-preshared-key key)"; mask "$k0"
  [ -n "$k0" ] || { miss "the Secret gibson-openfga-preshared-key holds no key"; return 1; }
  [ "$(fga_status "")" = 401 ] || { miss "OpenFGA does not refuse a call with no key"; return 1; }
  [ "$(fga_status "$k0")" = 200 ] || { miss "OpenFGA refuses the key of the cluster"; return 1; }
  daemons_ready || { miss "a daemon pod is not Ready before the rotation"; return 1; }
  restarts="$(daemon_restarts)"
  ok "OpenFGA refuses a call with no key and accepts the key of the cluster"

  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  deadline=$(( $(date +%s) + ROTATION_WAIT ))
  k1="$(new_fga_key)"; mask "$k1"
  set_at_source gibson-openfga-preshared-key key_previous "$k0" \
    && set_at_source gibson-openfga-preshared-key key "$k1" \
    || { miss "the write of the OpenFGA key failed"; return 1; }
  written="$(date +%s)"
  until [ "$(fga_status "$k1")" = 200 ] && [ "$(fga_status "$k0")" = 200 ]; do
    daemons_ready || unready=$((unready + 1))
    [ "$(date +%s)" -lt "$deadline" ] || { miss "OpenFGA does not accept the new and the old key after the rotation"; return 1; }
    sleep 15
  done
  ok "after one rotation OpenFGA accepts the new key and the old one"
  # The clients read k1 from their key files only after the kubelet writes the
  # new Secret into each pod. The second rotation drops k0 from OpenFGA, so it
  # must wait for that write, or a client that still holds k0 is refused and
  # the class reads a race as a failed rotation (audit of 2026-10-19).
  wait_fga_clients "$k1" "$written" "$deadline" || return 1

  k2="$(new_fga_key)"; mask "$k2"
  set_at_source gibson-openfga-preshared-key key_previous "$k1" \
    && set_at_source gibson-openfga-preshared-key key "$k2" \
    || { miss "the second write of the OpenFGA key failed"; return 1; }
  written="$(date +%s)"
  until [ "$(fga_status "$k2")" = 200 ] && [ "$(fga_status "$k0")" = 401 ]; do
    daemons_ready || unready=$((unready + 1))
    [ "$(date +%s)" -lt "$deadline" ] || { miss "after a second rotation OpenFGA does not refuse the first key"; return 1; }
    sleep 15
  done
  [ "$(fga_status "$k1")" = 200 ] || { miss "after a second rotation OpenFGA refuses the previous key"; return 1; }
  ok "after a second rotation OpenFGA refuses the first key and accepts the previous and the new one"

  # Each client holds k2, then each client is proven.
  wait_fga_clients "$k2" "$written" "$deadline" || return 1
  [ "$unready" -eq 0 ] || { miss "a daemon pod went unready ${unready} times during the rotations: its OpenFGA Check was refused"; return 1; }
  [ "$(daemon_restarts)" = "$restarts" ] \
    || { miss "a daemon pod or container restarted during the rotations, so the poll cannot prove it kept service"; return 1; }
  for pod in $(pods_of app.kubernetes.io/component=daemon); do
    [ "$(daemon_readyz "$pod")" = 200 ] || { miss "/readyz of ${pod} fails after the rotations"; return 1; }
  done
  ok "each daemon pod stayed Ready through both rotations with no restart, and its /readyz answers 200"
  refused="$(refused_fga_calls "$since")"
  [ "$refused" = 0 ] || { miss "the OpenFGA clients logged ${refused} refused OpenFGA calls during the rotations"; return 1; }
  ok "no OpenFGA client logged a refused call during the rotations"
  restart_ext_authz "$RESTART_WAIT_S" \
    || { miss "ext-authz does not start on the current key: its start self-check is refused"; return 1; }
  bootstrap_ready || { miss "the PlatformBootstrap is not Ready after the rotations"; return 1; }
  k0=""; k1=""; k2=""
  ok "ext-authz starts on the current key, and the PlatformBootstrap is Ready"
}

# --- vendor-issued-inputs ----------------------------------------------------
# Source: GitHub and Stripe. A person creates the new value at the vendor and
# runs scripts/keyring.sh set, which records the time; keyring-to-cluster.sh
# writes the value and the time (an annotation of the keyring Secret), and
# the chart moves the value to its consumer (ADR-0171). The vendor value has
# no issue API, so the drill does not rotate it. The check proves:
#   - each vendor value the cluster holds has a recorded set time, younger
#     than its lifetime;
#   - the Stripe webhook secret: an event signed with the secret the
#     billing-webhook holds is accepted, and one signed with another secret
#     is refused.
VENDOR_LIFETIME_DAYS="${VENDOR_LIFETIME_DAYS:-365}"
# <member> <key of bringup-keyring, or - when the value lives elsewhere>
VENDOR_VALUES="
GHCR_PULL_TOKEN ghcr-pull-token
STRIPE_SECRET_KEY stripe-secret-key
STRIPE_PUBLISHABLE_KEY stripe-publishable-key
STRIPE_WEBHOOK_SECRET stripe-webhook-secret
GITHUB_APP_PRIVATE_KEY -
"

# stripe_signed_status SECRET NS POD: the HTTP status of a test event signed
# with SECRET, posted to /webhook of POD through a port-forward.
stripe_signed_status() {
  local lport pid code="" ts body sig
  ts="$(date +%s)"
  body="$(jq -nc --arg id "evt_rotation_drill_${ts}" \
    '{id: $id, object: "event", type: "rotation.drill.check", api_version: "2024-06-20", created: 0, data: {object: {}}}')"
  sig="$(printf '%s.%s' "$ts" "$body" | openssl dgst -sha256 -hmac "$1" -hex | sed 's/^.*= //')"
  lport=$(( 20000 + RANDOM % 20000 ))
  kubectl -n "$2" port-forward "pod/$3" "${lport}:8090" >/dev/null 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    code="$(printf 'header = "Stripe-Signature: t=%s,v1=%s"\n' "$ts" "$sig" \
      | curl -s -o /dev/null -w '%{http_code}' -K - -H 'Content-Type: application/json' \
          --data-binary "$body" "http://127.0.0.1:${lport}/webhook" 2>/dev/null || true)"
    [ -n "$code" ] && [ "$code" != 000 ] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  printf '%s' "$code"
}

class_vendor_issued_inputs() {
  local member key value at age annotations dep ns pod sec skey whsec code
  annotations="$(kubectl -n "$NS" get secret bringup-keyring -o json | jq -c '.metadata.annotations // {}')" \
    || { miss "no keyring Secret ${NS}/bringup-keyring"; return 1; }
  while read -r member key; do
    [ -n "$member" ] || continue
    at="$(jq -r --arg a "keyring.zeroroot.ai/set-at.$(printf '%s' "$member" | tr 'A-Z_' 'a-z-')" '.[$a] // empty' <<<"$annotations")"
    if [ "$key" != - ]; then
      value="$(secret_value bringup-keyring "$key")"
      if [ -z "$value" ]; then ok "${member}: not supplied in this env"; continue; fi
      value=""
      [ -n "$at" ] || { miss "${member} is supplied and has no recorded set time: set it again with keyring.sh set"; return 1; }
    elif [ -z "$at" ]; then
      # The GitHub App key reaches the cluster as argocd/zeroroot-ai-creds
      # (keyring-to-cluster.sh). That Secret means the key is in use.
      if kubectl -n argocd get secret zeroroot-ai-creds >/dev/null 2>&1; then
        miss "${member} is in use (argocd/zeroroot-ai-creds) and has no recorded set time: set it again with keyring.sh set"; return 1
      fi
      ok "${member}: not used in this env"; continue
    fi
    age=$(( ( $(date +%s) - at ) / 86400 ))
    [ "$age" -le "$VENDOR_LIFETIME_DAYS" ] \
      || { miss "${member} was set ${age} days ago, past its lifetime of ${VENDOR_LIFETIME_DAYS} days: rotate it at the vendor"; return 1; }
    ok "${member}: set ${age} days ago"
  done <<< "$VENDOR_VALUES"

  # The Stripe webhook secret, at its consumer.
  dep="$(kubectl get deploy -A -o json | jq -r '.items[] | select(.metadata.name | endswith("billing-webhook")) | "\(.metadata.namespace) \(.metadata.name)"' | head -n1)"
  if [ -z "$dep" ]; then ok "no billing-webhook in this env: no Stripe webhook to prove"; return 0; fi
  ns="${dep%% *}"
  read -r sec skey < <(kubectl -n "$ns" get deploy "${dep#* }" -o json | jq -r '
    [.spec.template.spec.containers[].env[]? | select(.name == "STRIPE_WEBHOOK_SECRET") | .valueFrom.secretKeyRef][0] | "\(.name) \(.key)"')
  whsec="$(kubectl -n "$ns" get secret "$sec" -o json 2>/dev/null | jq -r --arg k "$skey" '.data[$k] // empty' | base64 -d 2>/dev/null)"
  [ -n "$whsec" ] || { miss "the billing-webhook holds no Stripe webhook secret (${sec}/${skey})"; return 1; }
  mask "$whsec"
  pod="$(kubectl -n "$ns" get pods -o json | jq -r --arg d "${dep#* }" '[.items[] | select(.metadata.name | startswith($d + "-")) | select(.status.phase == "Running") | .metadata.name][0] // empty')"
  [ -n "$pod" ] || { miss "no running billing-webhook pod in ${ns}"; return 1; }
  code="$(stripe_signed_status "$whsec" "$ns" "$pod")"; whsec=""
  [ "$code" = 200 ] || { miss "the billing-webhook answers ${code:-nothing}, not 200, to an event signed with the secret it holds"; return 1; }
  code="$(stripe_signed_status "whsec_$(openssl rand -hex 16)" "$ns" "$pod")"
  [ "$code" = 400 ] || { miss "the billing-webhook answers ${code:-nothing}, not 400, to an event signed with another secret"; return 1; }
  ok "the billing-webhook accepts an event signed with its secret and refuses one signed with another"
}

# --- setec-disk-signing-seed ------------------------------------------------
# Source: the bringup keyring members SETEC_DISK_SIGNING_SEED and the second,
# permanent seed SETEC_DISK_SIGNING_SEED_PREVIOUS, whose two public keys the
# drill overlay lists (owner decision of 2026-10-18, hosted#444, option a).
# Path: keyring-to-cluster.sh writes the seed to the bringup keyring, the
# openbao-auto-init sidecar copies it to OpenBao, ESO writes the Secret
# setec-system/setec-disk-signing, and the setec operator signs each new disk
# with it. A disk tag names the key id of its signer (setec#272), so a new
# seed makes a new disk.
#
# The check switches the signing seed to the second seed in a copy of the
# runner keyring, waits until the operator Secret holds it, and boots a
# launcher Sandbox of a first-party image (the default class, an image of the
# ghcr.io mirror, the one registry of the install). It proves that the
# operator ran the disk Job of that image digest and the key id of the second
# seed, and that the Sandbox runs: the launcher verified the disk. Then it
# switches back, through the same path. The class does not revoke: both keys
# stay trusted (revokes_old: false).
SETEC_NS="${SETEC_NS:-setec-system}"
DISK_SIGNING_SECRET="${DISK_SIGNING_SECRET:-setec-disk-signing}"
SEED_WAIT="${SEED_WAIT:-900}"
SANDBOX_NS="${SANDBOX_NS:-setec-sandboxes}"
SANDBOX_WAIT="${SANDBOX_WAIT:-900}"
# A small first-party image, by digest: a disk belongs to one digest.
DISK_PROBE_IMAGE="${DISK_PROBE_IMAGE:-ghcr.io/zeroroot-ai/mirror/alpine@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d}"

# disk_key_id PUB_B64: the key id of a raw ed25519 public key, as setec
# names it in a disk tag: 16 hex of the SHA-256 of the key (diskbuilder.KeyID).
disk_key_id() { printf '%s' "$1" | base64 -d | sha256sum | cut -c1-16; }

# with_disk_seeds FILE OUT SEED PREVIOUS: a copy of keyring FILE at OUT with
# the two disk seed members set. Every other member stays as it is.
with_disk_seeds() {
  ( umask 077
    grep -vE '^SETEC_DISK_SIGNING_SEED(_PREVIOUS)?=' "$1" > "$2"
    printf 'SETEC_DISK_SIGNING_SEED=%s\nSETEC_DISK_SIGNING_SEED_PREVIOUS=%s\n' "$3" "$4" >> "$2" )
}

# signing_seed_is SEED: true when the operator Secret holds SEED. The values
# are compared by hash, never printed.
signing_seed_is() {
  local have
  have="$(kubectl -n "$SETEC_NS" get secret "$DISK_SIGNING_SECRET" -o jsonpath='{.data.seed}' 2>/dev/null | base64 -d 2>/dev/null | sha256sum | cut -c1-64)"
  [ "$have" = "$(printf '%s' "$1" | sha256sum | cut -c1-64)" ]
}

# wait_signing_seed SEED: until the operator Secret holds SEED, or SEED_WAIT.
# The input pass of the sidecar runs every five minutes, then ESO refreshes.
wait_signing_seed() {
  local deadline=$(( $(date +%s) + SEED_WAIT ))
  until signing_seed_is "$1"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    kubectl -n "$SETEC_NS" annotate externalsecret "$DISK_SIGNING_SECRET" "force-sync=$(date +%s)" --overwrite >/dev/null 2>&1 || true
    sleep 30
  done
}

# disk_job_name IMAGE KEY_ID: the name of the disk Job of an image digest and
# a signing key, as the setec operator names it (diskJobName): setec-disk-,
# the first 20 hex of the digest, -, the key id.
disk_job_name() {
  local digest="${1##*@sha256:}"
  [ "$digest" != "$1" ] || return 1
  printf 'setec-disk-%s-%s' "${digest:0:20}" "$2"
}

# probe_sandbox NAME JOB: create a launcher Sandbox of DISK_PROBE_IMAGE and
# wait until it runs, or SANDBOX_WAIT. While it waits, it reads the disk Job
# JOB, because the Job is deleted 600 s after it ends (diskJobTTLSeconds), and
# writes "job-succeeded" to the file JOB_SEEN when the Job succeeded. Prints
# the last phase and reason on failure.
probe_sandbox() {
  local deadline phase
  kubectl apply -f - >/dev/null <<YAML || return 1
apiVersion: setec.zeroroot.ai/v1alpha1
kind: Sandbox
metadata:
  name: ${1}
  namespace: ${SANDBOX_NS}
spec:
  image: ${DISK_PROBE_IMAGE}
  command: ["/bin/sh", "-c", "sleep 600"]
  resources:
    vcpu: 1
    memory: 512Mi
  network:
    mode: none
  desiredState: Running
YAML
  deadline=$(( $(date +%s) + SANDBOX_WAIT ))
  while :; do
    if kubectl -n "$SETEC_NS" get job "$2" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -qx 1; then
      echo job-succeeded > "$JOB_SEEN"
    fi
    phase="$(kubectl -n "$SANDBOX_NS" get sandbox "$1" -o jsonpath='{.status.phase}/{.status.reason}' 2>/dev/null || true)"
    case "$phase" in Running/*) return 0 ;; Failed/*) printf '%s' "$phase"; return 1 ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || { printf '%s' "${phase:-none}"; return 1; }
    sleep 15
  done
}


class_setec_disk_signing_seed() {
  local work cur prev keys cur_pub prev_pub new_id job box since got
  [ -n "${KEYRING_FILE:-}" ] && [ -s "$KEYRING_FILE" ] && [ -n "${SUBSTRATE_ENV_FILE:-}" ] && [ -s "$SUBSTRATE_ENV_FILE" ] \
    || { miss "no KEYRING_FILE or SUBSTRATE_ENV_FILE on this runner: the keyring lives with stage 0"; return 1; }
  cur="$(scripts/keyring.sh get "$KEYRING_FILE" SETEC_DISK_SIGNING_SEED)"; mask "$cur"
  prev="$(scripts/keyring.sh get "$KEYRING_FILE" SETEC_DISK_SIGNING_SEED_PREVIOUS)"; mask "$prev"
  [ -n "$cur" ] && [ -n "$prev" ] \
    || { miss "the keyring holds no second disk seed (SETEC_DISK_SIGNING_SEED_PREVIOUS), so there is nothing to switch to"; return 1; }
  keys="$(scripts/keyring.sh disk-public-keys "$KEYRING_FILE")" \
    || { miss "keyring.sh disk-public-keys failed"; return 1; }
  cur_pub="$(printf '%s\n' "$keys" | sed -n 1p)"; prev_pub="$(printf '%s\n' "$keys" | sed -n 2p)"
  [ -n "$prev_pub" ] || { miss "the second disk seed has no public key"; return 1; }
  new_id="$(disk_key_id "$prev_pub")"
  job="$(disk_job_name "$DISK_PROBE_IMAGE" "$new_id")" \
    || { miss "the probe image ${DISK_PROBE_IMAGE} has no digest"; return 1; }
  signing_seed_is "$cur" \
    || { miss "before the switch the Secret ${SETEC_NS}/${DISK_SIGNING_SECRET} does not hold the keyring seed"; return 1; }
  ok "the disk builder signs with the seed of key $(disk_key_id "$cur_pub"), and the keyring keeps the second seed of key ${new_id}"

  work="$(mktemp -d)"; chmod 700 "$work"
  with_disk_seeds "$KEYRING_FILE" "$work/switched.env" "$prev" "$cur"

  # 1. Rotate at the source: the second seed signs.
  if ! { k2c "$work/switched.env" && wait_signing_seed "$prev"; }; then
    k2c; wait_signing_seed "$cur" || true
    miss "the Secret ${SETEC_NS}/${DISK_SIGNING_SECRET} did not take the second seed in ${SEED_WAIT}s"; rm -rf "$work"; return 1
  fi
  ok "the disk builder holds the second seed"

  # 2. The path runs: a launcher Sandbox boots. The operator runs the disk
  #    Job of the image digest and the key id of the second seed, and the
  #    launcher verifies the disk against the overlay keys before it boots.
  box="rotation-disk-seed-$(date +%s)"
  JOB_SEEN="$work/job-seen"
  if ! got="$(probe_sandbox "$box" "$job")"; then
    kubectl -n "$SANDBOX_NS" delete sandbox "$box" --wait=false >/dev/null 2>&1 || true
    k2c; wait_signing_seed "$cur" || true
    miss "a launcher Sandbox did not run after the switch to the second seed (phase ${got})"; rm -rf "$work"; return 1
  fi
  if ! { [ -s "$JOB_SEEN" ] || kubectl -n "$SETEC_NS" get job "$job" -o jsonpath='{.status.succeeded}' 2>/dev/null | grep -qx 1; }; then
    kubectl -n "$SANDBOX_NS" delete sandbox "$box" --wait=false >/dev/null 2>&1 || true
    k2c; wait_signing_seed "$cur" || true
    miss "no succeeded disk Job ${job} for the key ${new_id} of the second seed"; rm -rf "$work"; return 1
  fi
  kubectl -n "$SANDBOX_NS" delete sandbox "$box" --wait=false >/dev/null 2>&1 || true
  ok "a launcher Sandbox runs a disk of the second key: the operator chose it by the key id of the second seed (disk Job ${job}), and the launcher verified its signature"

  # 3. Back to the seed of stage 0, through the same path.
  k2c && wait_signing_seed "$cur" \
    || { miss "the Secret ${SETEC_NS}/${DISK_SIGNING_SECRET} did not return to the stage 0 seed"; rm -rf "$work"; return 1; }
  ok "the disk builder signs with the stage 0 seed again"
  rm -rf "$work"
}

# --- substrate-cloud-credentials ---------------------------------------------
# Source: the access keys of the substrate IAM users (stage 0,
# substrate/gibson-bootstrap). Path: scripts/substrate-rotate.sh at stage 0,
# on the operator workstation (ADR-0083, ADR-0171), and in the drill, where
# rotation run 1 starts a rotation of each user and the later drill runs continue
# it (scripts/drill-rotate-keys.sh). The check asks IAM for the keys of each
# user and proves the result of the path:
#   - exactly one active key, so no old key is still accepted;
#   - its id is the id the cluster holds, so the cluster uses the live key;
#   - it is younger than its lifetime, so the rotation runs on time.
# A key that IAM no longer lists is refused by AWS.
#
# AN OPEN ROTATION. Rotation run 1 starts a rotation of each user
# (scripts/drill-rotate-keys.sh start) before this class runs, in the same job.
# The class is in run 1 of credential-classes.yaml for that reason, and
# tests/harness/rotation-budget.bats keeps it there (review of hosted#807).
# A rotation
# deletes the old key only after it stays unused for QUIET_SECS (4 hours,
# scripts/substrate-rotate.sh). So in that run each user has two active keys.
# When the stage 0 file key-slots.tfvars.json shows two slots for a user, the
# check accepts two active keys, and proves the state of the rotation instead:
#   - the cluster holds the newer key;
#   - AWS reports no use of the older key after the switch time that
#     key-rotation.json records, so no consumer still holds it.
# A later drill run deletes the older key (drill-rotate-keys.sh continue).
SUBSTRATE_KEY_LIFETIME_DAYS="${SUBSTRATE_KEY_LIFETIME_DAYS:-90}"

# key_last_used ID: the epoch of the last use of the access key ID, or 0.
key_last_used() {
  local d
  d="$(aws iam get-access-key-last-used --access-key-id "$1" \
         --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null)" || return 1
  case "$d" in ''|None) echo 0 ;; *) date -d "$d" +%s ;; esac
}

class_substrate_cloud_credentials() {
  local env user slot want keys n id created age smtp_user state slots switched_file switched old_id olu
  # drill.yml sets ENV for the job; the IAM users carry it in their names.
  env="${ENV:-}"
  [ -n "$env" ] || { miss "no ENV: the check cannot name the IAM users"; return 1; }
  command -v aws >/dev/null 2>&1 || { miss "aws is not on PATH"; return 1; }
  # The stage 0 files of this env, next to substrate.env.
  state="$(dirname "${SUBSTRATE_ENV_FILE:-/nonexistent/substrate.env}")"
  slots="${state}/key-slots.tfvars.json"
  switched_file="${state}/key-rotation.json"
  smtp_user="$(secret_value bringup-keyring smtp-username)"
  # <IAM user> <its key-slots name> <the access key id the cluster holds>
  while read -r user slot want; do
    [ -n "$user" ] || continue
    if [ -z "$want" ]; then
      ok "${user}: the cluster holds no key of it (not used in this env)"; continue
    fi
    keys="$(aws iam list-access-keys --user-name "$user" --output json 2>/dev/null)" \
      || { miss "IAM gave no answer for the keys of ${user}"; return 1; }
    n="$(jq '[.AccessKeyMetadata[] | select(.Status == "Active")] | length' <<<"$keys")"
    if [ "$n" = 2 ] && [ -s "$slots" ] \
       && [ "$(jq -r --arg u "$slot" '.key_slots[$u].keep | length' "$slots")" = 2 ]; then
      # An open rotation. The newer key is the one the cluster must hold.
      id="$(jq -r '[.AccessKeyMetadata[] | select(.Status == "Active")] | sort_by(.CreateDate) | .[1].AccessKeyId' <<<"$keys")"
      old_id="$(jq -r '[.AccessKeyMetadata[] | select(.Status == "Active")] | sort_by(.CreateDate) | .[0].AccessKeyId' <<<"$keys")"
      if [ "$want" = "$old_id" ]; then
        miss "${user}: a rotation is open, and the cluster still holds the old key. The step 'Start the access key rotation' did not reach the cluster: read its log"; return 1
      fi
      [ "$id" = "$want" ] \
        || { miss "${user}: a rotation is open, and the cluster holds ${want}, which is neither key of the user"; return 1; }
      switched="$(jq -r --arg u "$slot" '.[$u] // 0' "$switched_file" 2>/dev/null || echo 0)"
      [ "${switched:-0}" -gt 0 ] \
        || { miss "${user}: a rotation is open, and ${switched_file} records no switch time. The step 'Start the access key rotation' stopped before step 3c of substrate-rotate.sh: read its log"; return 1; }
      olu="$(key_last_used "$old_id")" \
        || { miss "IAM gave no answer for the last use of the old key of ${user}"; return 1; }
      [ "$olu" -lt "$switched" ] \
        || { miss "${user}: the old key ${old_id} was used at $(date -u -d "@$olu" +%FT%TZ), after the switch: a consumer still holds it"; return 1; }
      ok "${user}: a rotation is open. The cluster holds the newer key, and the old key is unused since the switch"
      continue
    fi
    [ "$n" = 1 ] || { miss "${user} has ${n} active access keys, not 1: an old key is still accepted"; return 1; }
    id="$(jq -r '.AccessKeyMetadata[] | select(.Status == "Active") | .AccessKeyId' <<<"$keys")"
    [ "$id" = "$want" ] || { miss "${user}: the active key is ${id}, and the cluster holds ${want}"; return 1; }
    created="$(jq -r '.AccessKeyMetadata[] | select(.Status == "Active") | .CreateDate' <<<"$keys")"
    age=$(( ( $(date +%s) - $(date -d "$created" +%s) ) / 86400 ))
    [ "$age" -le "$SUBSTRATE_KEY_LIFETIME_DAYS" ] \
      || { miss "${user}: the active key is ${age} days old, past its lifetime of ${SUBSTRATE_KEY_LIFETIME_DAYS} days"; return 1; }
    ok "${user}: one active key, the one the cluster holds, ${age} days old"
  done <<EOF
zeroroot-ai-${env}-platform platform $(secret_value bringup-keyring bucket-access-key)
zeroroot-ai-${env}-dns dns $(secret_value route53-credential access-key-id)
zeroroot-ai-${env}-setec-disk-builder setec-disk-builder $(secret_value setec-disk-push-credential access-key-id)
zeroroot-ai-${env}-smtp smtp $([ "${smtp_user#AKIA}" != "$smtp_user" ] && printf '%s' "$smtp_user")
EOF
}

# --- diagnostics of a failed class -------------------------------------------
# diagnose_failed_class NAME: what the cluster looks like when a class fails,
# so the run names the cause (drill run 39125128505: redis-password failed
# with the CronJob state unchanged, and each later class found the daemon
# down, with no log of either). Pods that are not Ready (Pending pods in their
# init containers too), their recent events and the tail of their logs, and
# the last Jobs of the rotation CronJobs with each container. No Secret value
# is read. It prints only and decides nothing, and it runs in a subshell
# with errexit and pipefail off, so a failed read never stops the run.
diagnose_failed_class() (
  set +e +o pipefail
  local pod job pods
  printf '    --- diagnostics after %s ---\n' "$1"
  pods="$(kubectl -n "$NS" get pods --no-headers \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.conditions[?(@.type=="Ready")].status,RESTARTS:.status.containerStatuses[*].restartCount,START:.status.startTime' 2>&1 \
    | awk '$3 != "True" && $2 != "Succeeded"')"
  printf '%s\n' "$pods" | head -n 20 | sed 's/^/      /'
  for pod in $(printf '%s\n' "$pods" | awk '$2 == "Running" || $2 == "Pending" {print $1}' | head -n 5); do
    printf '      events of %s:\n' "$pod"
    kubectl -n "$NS" get events --field-selector "involvedObject.name=${pod}" --sort-by=.lastTimestamp 2>&1 | tail -n 5 | sed 's/^/        /'
    printf '      last log lines of %s:\n' "$pod"
    kubectl -n "$NS" logs "$pod" --all-containers --tail=15 2>&1 | cut -c1-300 | sed 's/^/        /'
  done
  # The CronJob Jobs carry no label of their own (the jobTemplate has no
  # metadata), so they are found by name.
  for job in $(kubectl -n "$NS" get jobs --sort-by=.metadata.creationTimestamp -o name 2>&1 \
                 | grep -E "^job.batch/${RELEASE}-(redis-rotation|zitadel-masterkey-rotation)-" | tail -n 3); do
    printf '      log of %s:\n' "$job"
    kubectl -n "$NS" logs "$job" --all-containers --tail=20 2>&1 | cut -c1-300 | sed 's/^/        /'
  done
  return 0
)

# --- the time budget ---------------------------------------------------------
# The step of drill.yml that runs this script has a time limit. GitHub stops
# the step at that limit, also inside a class. A class stopped in the middle
# leaves the cluster half rotated, and each class after it gets no line in the
# results, so no issue opens for it (review of hosted#805). So the script has
# one time budget, ROTATION_BUDGET_S, which drill.yml sets from the step limit
# (tests/harness/rotation-budget.bats keeps the two equal), and each tested
# class declares the most time it can take (time_bound_of). A class whose
# bound does not fit in the time left is not started, and its line says so.
#
# The bounds are worst cases: each deadline of the class, and each wait that
# runs after a deadline, plus BOUND_SLACK_S for the last poll after a deadline
# and the reads between the waits. The bounds of all the classes do not fit
# one step, so the classes are split into runs. The plan is the field `run`
# of each tested class in credential-classes.yaml, so a change of the plan is
# a reviewed diff (review of hosted#807). The script checks at start that the
# bounds of each run fit the budget, and refuses to start when they do not.
# A drill dispatch with rotation_run <n> does run <n>, so a person dispatches
# each run to rotate each class. A class that runs longer than its bound fails with that reason,
# so a bound that is wrong does not stay wrong.
BOUND_SLACK_S=300

# time_bound_of TEST: the most seconds the class of TEST can take. A test with
# no line here has no bound, and the run refuses to start it.
time_bound_of() {
  local w="$ROTATION_WAIT" b
  case "$1" in
    redis-password)            b=$(( REDIS_WAIT_MAX_S + 4 * CHECK_ROLLOUT_S )) ;;
    edge-tls)                  b=$(( w )) ;;
    component-tls)             b=$(( 2 * w + RESTART_WAIT_S )) ;;
    spire-svid)                b=$(( w + 2 * EXT_AUTHZ_RESTART_WAIT_S )) ;;
    openbao-service-tokens)    b=$(( 2 * w + ROLLOUT_WAIT_S + RECONCILE_PASS_S + CHECK_ROLLOUT_S )) ;;
    postgres-role-passwords)   b=$(( 2 * w + SETTLE_S )) ;;
    neo4j-password)            b=0 ;;
    platform-signing-keys)     b=$(( w + CG_SVID_SLACK_S )) ;;
    platform-generated-secrets) b=$(( 2 * w + SETTLE_S )) ;;
    # One kubelet wait: the rest after the second write is the only one that
    # can fall after the deadline (review of fix/rotation-bound-followups).
    openfga-preshared-key)     b=$(( w + KUBELET_SYNC_WAIT + RESTART_WAIT_S )) ;;
    zitadel-bringup-tokens)    b=$(( 2 * w + ROLLOUT_WAIT_S + RECONCILE_PASS_S )) ;;
    # Six OpenBao restarts, two Velero restarts (the third restart only runs
    # on the failure path, which then returns), the OpenBao rollout, two
    # backups and the settle (review of hosted#807).
    keyring-generated-keys)    b=$(( 6 * (BAO_DELETE_WAIT_S + BAO_STATE_WAIT_S) + 2 * ROLLOUT_WAIT_S
                                     + 2 * (VELERO_QUEUE_WAIT + VELERO_RUN_WAIT) + ROLLOUT_WAIT_S + SETTLE_S
                                     + 2 * (2 * VELERO_READY_WAIT + 2 * (VELERO_PICKUP_WAIT + VELERO_DELETE_WAIT)) )) ;;
    setec-disk-signing-seed)   b=$(( 2 * SEED_WAIT + SANDBOX_WAIT )) ;;
    substrate-cloud-credentials) b=0 ;;
    vendor-issued-inputs)      b=0 ;;
    *) return 1 ;;
  esac
  printf '%s' $(( b + BOUND_SLACK_S ))
}

# --- one class, under a time limit -----------------------------------------
# Each class runs in a child process of this script, under `timeout` at its
# bound plus CLASS_TIMEOUT_MARGIN_S (review of hosted#807). A kubectl exec, get
# or port-forward that hangs has no time limit of its own, so a hung class
# would hold the step until GitHub stops it, and the later classes would get
# no line. `timeout` stops the whole process group of the child, kubectl too.
# The parent then writes the fail line of that class, and the next class
# starts. The child writes its REASON to ROTATION_REASON_FILE.
CLASS_TIMEOUT_MARGIN_S=60
CLASS_KILL_AFTER_S=30
DIAG_TIMEOUT_S=120
if [ -n "${ROTATION_ONE_CLASS:-}" ]; then
  REASON=""
  rc=0; "$ROTATION_ONE_CLASS" ${ROTATION_ONE_ARG:+"$ROTATION_ONE_ARG"} || rc=$?
  printf '%s' "$REASON" > "${ROTATION_REASON_FILE:?the parent names the reason file}"
  exit "$rc"
fi

# run_class FN BOUND: run the class FN in a child under its time limit. Sets
# REASON from the child, and returns the exit code of the child (124 or 137
# when the limit stopped it).
run_class() {
  local reason_file rc=0
  reason_file="$(mktemp)"
  ROTATION_ONE_CLASS="$1" ROTATION_REASON_FILE="$reason_file" \
    timeout --kill-after="$CLASS_KILL_AFTER_S" "$(( $2 + CLASS_TIMEOUT_MARGIN_S ))" \
    bash "${BASH_SOURCE[0]}" "$CLASSES" "$RESULTS" || rc=$?
  REASON="$(cat "$reason_file" 2>/dev/null || true)"
  rm -f "$reason_file"
  case "$rc" in
    124|137)
      REASON="the class did not finish within its bound of ${2} s and a margin of ${CLASS_TIMEOUT_MARGIN_S} s, so it was stopped: a call hung${REASON:+ (last reason: ${REASON})}" ;;
  esac
  return "$rc"
}

# run_diagnosis NAME: diagnose_failed_class NAME in a child under
# DIAG_TIMEOUT_S. Its kubectl calls have no time limit of their own, and the
# API that stopped a class can stop the diagnosis too (review of the branch
# fix/rotation-bound-followups). The row of the class is written before it.
run_diagnosis() {
  local reason_file
  reason_file="$(mktemp)"
  ROTATION_ONE_CLASS=diagnose_failed_class ROTATION_ONE_ARG="$1" ROTATION_REASON_FILE="$reason_file" \
    timeout --kill-after="$CLASS_KILL_AFTER_S" "$DIAG_TIMEOUT_S" \
    bash "${BASH_SOURCE[0]}" "$CLASSES" "$RESULTS" \
    || printf '    (the diagnostics of %s stopped after %s s)\n' "$1" "$DIAG_TIMEOUT_S"
  rm -f "$reason_file"
  return 0
}

# --- the classes of the list -------------------------------------------------
# One line per class: <name> TAB <status> TAB <test> TAB <run> TAB <gap>.
rows="$(python3 - "$CLASSES" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for c in doc["classes"]:
    gap = " ".join(str(c.get("gap", "")).split())
    print(f"{c['name']}\t{c['status']}\t{c['test']}\t{c.get('run') or '-'}\t{gap}")
PY
)" || { echo "could not run: the class list does not parse" >&2; exit 2; }
[ -n "$rows" ] || { echo "could not run: the class list is empty" >&2; exit 2; }

# The plan of the list: the run of each tested class. Each run must fit the
# budget, or no run of the plan can finish, and the script refuses to start.
# A tested class with no bound or no run has no place in the plan, and run 1
# reports it.
declare -A run_sum=()
runs=1
while IFS=$'\t' read -r name status test run gap; do
  [ "$status" = tested ] || continue
  b="$(time_bound_of "$test")" || continue
  [[ "$run" =~ ^[1-9][0-9]*$ ]] || continue
  run_sum[$run]=$(( ${run_sum[$run]:-0} + b ))
  [ "$run" -le "$runs" ] || runs="$run"
done <<< "$rows"
for r in "${!run_sum[@]}"; do
  [ "${run_sum[$r]}" -le "$ROTATION_BUDGET_S" ] \
    || { echo "could not run: the classes of run ${r} in ${CLASSES} need up to ${run_sum[$r]} s, more than the budget of ${ROTATION_BUDGET_S} s. Move a class to another run" >&2; exit 2; }
done
[ "$ROTATION_RUN" -le "$runs" ] \
  || { echo "could not run: ROTATION_RUN is ${ROTATION_RUN}, and the plan has ${runs} runs" >&2; exit 2; }
printf 'run %s of %s, a time budget of %s s, the bounds of this run %s s\n' \
  "$ROTATION_RUN" "$runs" "$ROTATION_BUDGET_S" "${run_sum[$ROTATION_RUN]:-0}"

failed=()
tested=0
# The class that the time limit stopped, if one did. The classes after it
# run on a cluster in an unknown state, so they do not start, and their rows
# name that cause.
stopped=""
while IFS=$'\t' read -r -u 3 name status test run gap; do
  printf '▶ %s\n' "$name"
  REASON=""
  if [ "$status" != tested ]; then
    printf '    - untested (%s): %s\n' "$status" "$gap"
    printf '%s\tuntested\t%s: %s\n' "$name" "$status" "$gap" >> "$RESULTS"
    continue
  fi
  fn="class_${test//-/_}"
  bound="$(time_bound_of "$test")" || bound=""
  [[ "$run" =~ ^[1-9][0-9]*$ ]] || run=""
  if [ -n "$bound" ] && [ -n "$run" ] && [ "$run" != "$ROTATION_RUN" ]; then
    printf '    - run %s of %s tests this class\n' "$run" "$runs"
    printf '%s\tother-run\trun %s of %s tests it\n' "$name" "$run" "$runs" >> "$RESULTS"
    continue
  fi
  # A class with no bound or no run has no place in the plan. Run 1
  # reports it, once.
  if { [ -z "$bound" ] || [ -z "$run" ]; } && [ "$ROTATION_RUN" != 1 ]; then
    continue
  fi
  tested=$((tested + 1))
  left=$(( START + ROTATION_BUDGET_S - $(date +%s) ))
  if ! declare -F "$fn" >/dev/null; then
    REASON="the class is marked tested, and this script has no ${fn}"
    printf '    ✗ %s\n' "$REASON" >&2
  elif [ -z "$bound" ]; then
    REASON="not started: the class declares no time bound (time_bound_of), so it may not fit the step"
    printf '    ✗ %s\n' "$REASON" >&2
  elif [ -z "$run" ]; then
    REASON="not started: the class names no run of the rotation plan in ${CLASSES}"
    printf '    ✗ %s\n' "$REASON" >&2
  elif [ -n "$stopped" ]; then
    REASON="not started: the cluster state is unknown after ${stopped} was stopped"
    printf '    ✗ %s\n' "$REASON" >&2
  elif [ "$bound" -gt "$left" ]; then
    REASON="not started: ${left} s of the time budget left, and the class needs up to ${bound} s"
    printf '    ✗ %s\n' "$REASON" >&2
  else
    # A line that stands until the class ends. When the step limit stops
    # the run inside a class, the results still name that class as failed.
    printf '%s\tfail\t%s\n' "$name" "the test did not finish before the step limit" >> "$RESULTS"
    t0="$(date +%s)"
    rc=0; run_class "$fn" "$bound" || rc=$?
    took=$(( $(date +%s) - t0 ))
    case "$rc" in 124|137) stopped="$name" ;; esac
    if [ "$took" -gt "$bound" ]; then
      # A bound that is too small lets a later class start that cannot
      # finish. It fails the class, so the bound is raised.
      REASON="${REASON:+${REASON}. }the class took ${took} s, past its declared bound of ${bound} s: raise time_bound_of"
      printf '    ✗ %s\n' "$REASON" >&2
    elif [ "$rc" -eq 0 ]; then
      sed -i '$d' "$RESULTS"
      printf '%s\tpass\t\n' "$name" >> "$RESULTS"
      continue
    fi
    # The final row first, then the diagnosis, which can hang on the same API.
    sed -i '$d' "$RESULTS"
    printf '%s\tfail\t%s\n' "$name" "${REASON:-the test failed and gave no reason}" >> "$RESULTS"
    failed+=("$name")
    run_diagnosis "$name"
    continue
  fi
  printf '%s\tfail\t%s\n' "$name" "${REASON:-the test failed and gave no reason}" >> "$RESULTS"
  failed+=("$name")
done 3<<< "$rows"

[ "$tested" -gt 0 ] || { echo "could not run: the class list marks no class as tested" >&2; exit 2; }
if [ "${#failed[@]}" -eq 0 ]; then
  printf 'PASS: each of the %s tested credential classes rotated, and each path works with the new value\n' "$tested"
  exit 0
fi

# --- the alert -----------------------------------------------------------------
# The Alertmanager of the env sends it by email (the path that
# test/monitoring/exit-test-alert-delivery.sh proves).
list="$(IFS=,; echo "${failed[*]}")"
alert="$(jq -nc --arg c "$list" --arg r "${RUN_URL:-a local run}" \
  '[{labels:{alertname:"CredentialRotationFailed",severity:"warning",classes:$c},
     annotations:{summary:("Credential rotation failed for: " + $c + " (hosted#444)"),run:$r}}]')"
# Each kubectl call of the alert runs under ALERT_TIMEOUT_S. A hung API would
# otherwise hold the step after every class row is written, and the run
# would end with no line for the alert (review of the branch
# fix/rotation-bound-followups).
ALERT_TIMEOUT_S=60
rc=0
am_pod="$(timeout --kill-after="$CLASS_KILL_AFTER_S" "$ALERT_TIMEOUT_S" \
  kubectl -n "$MON_NS" get pods -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ] && [ -n "$am_pod" ]; then
  timeout --kill-after="$CLASS_KILL_AFTER_S" "$ALERT_TIMEOUT_S" \
    kubectl -n "$MON_NS" exec "$am_pod" -c alertmanager -- \
    wget -qO- --header 'Content-Type: application/json' --post-data "$alert" \
    http://localhost:9093/api/v2/alerts >/dev/null 2>&1 || rc=$?
fi
if [ "$rc" -eq 0 ] && [ -n "$am_pod" ]; then
  printf 'sent the alert CredentialRotationFailed for: %s\n' "$list"
else
  # The alert is half of the failure report. A run that could not send it
  # says so as a failure of its own, and drill.yml opens an issue for it.
  case "$rc" in
    124|137) why="the call to the Alertmanager in the namespace ${MON_NS} did not answer in ${ALERT_TIMEOUT_S} s, so it was stopped" ;;
    *) why="no Alertmanager in the namespace ${MON_NS} took the alert" ;;
  esac
  printf '    ✗ could not send the alert CredentialRotationFailed: %s\n' "$why" >&2
  printf 'alert CredentialRotationFailed\tfail\t%s for: %s\n' "$why" "$list" >> "$RESULTS"
fi
printf 'FAIL: %s of the credential classes failed: %s\n' "${#failed[@]}" "$list" >&2
exit 1
