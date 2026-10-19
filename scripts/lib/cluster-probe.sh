# shellcheck shell=bash
# cluster-probe.sh — shared, FAIL-CLOSED preflight for live-cluster verification
# suites (deploy#1039, deploy#1041).
#
# Sourced, never executed:
#   source "$(dirname "$0")/lib/cluster-probe.sh"
#
# WHY THIS EXISTS
# ---------------
# The failure mode this library is built to prevent is a verification suite that
# reports success when it verified nothing. The anti-pattern is already in the
# tree — scripts/smoke-auth-chain.sh:95-99 exits 0 ("gracefully skipping") when
# the workload under test is absent, so a cluster missing ext-authz entirely
# produces the same green output as a healthy one.
#
# Every probe here does the inverse: an absent cluster, an absent namespace, an
# absent workload, or an indeterminate deployment profile is exit 2. There is no
# code path in this file that returns success without having established the
# thing it was asked to establish.
#
# Exit-code convention, matching scripts/smoke-signup.sh:
#   0 — all assertions passed
#   1 — an assertion failed (the suite ran and found a real defect)
#   2 — preflight failed (the suite could not run; NOT a pass)
#
# The distinction between 1 and 2 is load-bearing. A caller that cannot tell
# "the product is broken" from "I never reached the product" cannot be trusted
# as a gate.

# ---------------------------------------------------------------------------
# Output helpers — same verbs and colours as scripts/verify-profile.sh
# ---------------------------------------------------------------------------
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

fails=0
pass() { printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$1"; fails=$((fails + 1)); }
info() { printf '%s[info]%s %s\n' "$YELLOW" "$NC" "$1"; }
step() { printf '\n%s=== %s ===%s\n' "$CYAN" "$1" "$NC"; }

# capture <var> <command...>: run the command, put its stdout in <var> and the
# first three lines of its stderr, joined by " | ", in PROBE_ERR. Returns the
# exit code of the command. Three lines, because OpenBao and the AWS CLI put
# the code and the reason after a first line that names only the call
# ("Error listing secret/metadata/infra: Error making API request." then
# "Code: 403. Errors: ... permission denied").
# The stdout of a failed command is kept too: curl -w prints 000 on a failure.
#
# No probe sends its error to /dev/null and falls back to an empty answer.
# Staging run 38465547479 failed with "secret/infra/* missing" while the
# secrets were there: OpenBao refused the list, the refusal went to /dev/null,
# and the fallback "[]" read as "missing". A refusal is reported as a refusal,
# with its first error line. scripts/check-smoke-probes-loud.sh enforces this
# for this file and the promotion proof.
PROBE_ERR=""
capture() {
  local __var="$1" __errf __out __rc=0
  shift
  __errf="$(mktemp)"
  __out="$("$@" 2>"$__errf")" || __rc=$?
  # awk joins the lines with " | " and leaves a pipe inside a line alone.
  PROBE_ERR="$(grep -m3 -v '^[[:space:]]*$' "$__errf" | awk '{ sub(/^[[:space:]]+/, ""); printf "%s%s", (NR > 1 ? " | " : ""), $0 }' | cut -c1-600)" || PROBE_ERR=""
  rm -f "$__errf"
  [ "$__rc" -eq 0 ] || [ -n "$PROBE_ERR" ] || PROBE_ERR="exit ${__rc}, no error text"
  printf -v "$__var" '%s' "$__out"
  return "$__rc"
}

# preflight_die — the only way this library reports "could not run".
preflight_die() {
  printf '%s[PREFLIGHT]%s %s\n' "$RED" "$NC" "$1" >&2
  printf '%s[PREFLIGHT]%s exiting 2 — this is NOT a pass. The suite did not run.\n' "$RED" "$NC" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# probe_cluster <namespace>
#
# Establishes that a cluster exists, is reachable, and carries the namespace.
# Also refuses the customer cluster outright, matching the guard in
# test/smoke/cutover-smoke.sh:197-208.
# ---------------------------------------------------------------------------
probe_cluster() {
  local ns="$1"

  command -v kubectl >/dev/null 2>&1 \
    || preflight_die "kubectl not on PATH"

  local ctx="" out=""
  capture ctx kubectl config current-context \
    || preflight_die "no current kubectl context — there is no cluster to verify against: ${PROBE_ERR}"
  [ -n "$ctx" ] \
    || preflight_die "no current kubectl context — there is no cluster to verify against"

  case "$ctx" in
    kind-gibson-customer|gibson-customer)
      preflight_die "refusing to run against the customer cluster (context: $ctx)"
      ;;
  esac

  capture out kubectl cluster-info \
    || preflight_die "kubectl context '$ctx' is configured but unreachable — no live cluster: ${PROBE_ERR}"

  if ! capture out kubectl get ns "$ns"; then
    case "$PROBE_ERR" in
      *NotFound*|*"not found"*) preflight_die "namespace '$ns' does not exist on context '$ctx': ${PROBE_ERR}" ;;
      *) preflight_die "namespace '$ns' cannot be read on context '$ctx': ${PROBE_ERR}" ;;
    esac
  fi

  pass "cluster reachable (context=$ctx, namespace=$ns)"
}

# ---------------------------------------------------------------------------
# require_workload <namespace> <resource> <name> <why>
#
# Absent workload is exit 2, never a skip. If the thing under test is not
# deployed, the suite has established nothing and must say so.
# ---------------------------------------------------------------------------
require_workload() {
  # capture writes out. The exit code of the read is the check.
  # shellcheck disable=SC2034
  local ns="$1" res="$2" name="$3" why="$4" out=""
  if ! capture out kubectl -n "$ns" get "$res" "$name"; then
    case "$PROBE_ERR" in
      *NotFound*|*"not found"*) preflight_die "$res/$name absent in ns/$ns — cannot verify $why: ${PROBE_ERR}" ;;
      *) preflight_die "$res/$name cannot be read in ns/$ns — cannot verify $why: ${PROBE_ERR}" ;;
    esac
  fi
  pass "$res/$name present"
}

# ---------------------------------------------------------------------------
# detect_profile <namespace>
#
# Echoes "saas" or "self-hosted". Exits 2 when indeterminate.
#
# The discriminator is the presence of the SaaS-only entitlements-svc Service.
# Per ADR-0074 the SaaS overlay is a separate set of charts composed on top of
# the core umbrella, and entitlements-svc is one of its deployables — so its
# Service existing is the cleanest deployment-profile signal available
# in-cluster.
#
# It used to be www-svc. That stopped working when the marketing site became an
# off-cluster surface (ADR-0077): www-svc exists in NEITHER audience now, so
# every cluster would have reported "self-hosted" and every SaaS suite would
# have refused to run — silently, because require_profile skips rather than
# fails on a mismatch.
# ---------------------------------------------------------------------------
# NOTE ON SUBSHELLS: this function and resolve_edge below are called inside
# command substitution, where `exit` would only terminate the subshell and let
# the caller carry on with an empty value. They therefore RETURN non-zero and
# leave the dying to the caller. (This was a real bug: an unresolvable edge used
# to leave EDGE empty and run every probe against nothing, turning "could not
# run" into "ran and found 8 defects".)
# Each one writes the reason of a failure to stderr, which command substitution
# does not capture, so the caller's terminal shows it.
detect_profile() {
  local ns="$1" names=""

  if ! capture names kubectl -n "$ns" get svc -o name; then
    echo "detect_profile: cannot list the Services of ns/$ns: ${PROBE_ERR}" >&2
    return 1
  fi

  if grep -q 'entitlements-svc' <<<"$names"; then
    echo "saas"
  else
    echo "self-hosted"
  fi
}

# ---------------------------------------------------------------------------
# require_profile <namespace> <expected>
#
# Refuses to run a SaaS suite against a self-hosted cluster and vice versa.
#
# Without this, a SaaS suite's assertions would run green-ish against a
# self-hosted cluster where the SaaS surfaces are *correctly* absent, and a
# self-hosted suite's "surface is unrouted" checks would pass trivially
# anywhere the SaaS deployable happens to be down. Asserting the profile first
# is what makes each suite's results mean something.
# ---------------------------------------------------------------------------
require_profile() {
  local ns="$1" want="$2" got
  got="$(detect_profile "$ns")" \
    || preflight_die "could not enumerate Services in ns/$ns — deployment profile indeterminate"
  [ "$got" = "$want" ] \
    || preflight_die "cluster is running the '$got' profile, this suite verifies '$want' — refusing to report a result"
  pass "deployment profile is '$want'"
}

# ---------------------------------------------------------------------------
# resolve_edge <namespace>
#
# Echoes "<ip-or-host>:<port>" for the Envoy edge, so probes can use
# `curl --resolve` instead of depending on the operator's /etc/hosts. The
# existing scripts assume host-side DNS for app./api./www./docs. (see the
# /etc/hosts note at scripts/smoke-signup.sh:353); deriving the edge from the
# Service makes the same probe work on kind (NodePort) and EKS (LoadBalancer).
# ---------------------------------------------------------------------------
resolve_edge() {
  local ns="$1" svc="" names="" type="" addr="" port=""

  if [ -n "${EDGE_ADDR:-}" ]; then
    echo "$EDGE_ADDR"; return 0
  fi

  capture svc kubectl -n "$ns" get svc -l app.kubernetes.io/component=envoy -o name \
    || { echo "resolve_edge: cannot list the envoy Service of ns/$ns: ${PROBE_ERR}" >&2; return 1; }
  svc="${svc%%$'\n'*}"
  if [ -z "$svc" ]; then
    capture names kubectl -n "$ns" get svc -o name \
      || { echo "resolve_edge: cannot list the Services of ns/$ns: ${PROBE_ERR}" >&2; return 1; }
    # grep exits 1 when no name matches. The test below reports that case.
    svc="$(grep -m1 'envoy' <<<"$names")" || svc=""
  fi
  [ -n "$svc" ] || { echo "resolve_edge: ns/$ns has no envoy Service" >&2; return 1; }

  capture type kubectl -n "$ns" get "$svc" -o 'jsonpath={.spec.type}' \
    || { echo "resolve_edge: cannot read the type of $svc: ${PROBE_ERR}" >&2; return 1; }
  case "$type" in
    NodePort)
      capture port kubectl -n "$ns" get "$svc" -o 'jsonpath={.spec.ports[?(@.name=="https")].nodePort}' \
        || { echo "resolve_edge: cannot read the ports of $svc: ${PROBE_ERR}" >&2; return 1; }
      if [ -z "$port" ]; then
        capture port kubectl -n "$ns" get "$svc" -o 'jsonpath={.spec.ports[0].nodePort}' \
          || { echo "resolve_edge: cannot read the ports of $svc: ${PROBE_ERR}" >&2; return 1; }
      fi
      capture addr kubectl get nodes -o 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
        || { echo "resolve_edge: cannot read the node addresses: ${PROBE_ERR}" >&2; return 1; }
      ;;
    LoadBalancer)
      capture addr kubectl -n "$ns" get "$svc" -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' \
        || { echo "resolve_edge: cannot read the load balancer of $svc: ${PROBE_ERR}" >&2; return 1; }
      if [ -z "$addr" ]; then
        capture addr kubectl -n "$ns" get "$svc" -o 'jsonpath={.status.loadBalancer.ingress[0].hostname}' \
          || { echo "resolve_edge: cannot read the load balancer of $svc: ${PROBE_ERR}" >&2; return 1; }
      fi
      port="443"
      ;;
    *)
      echo "resolve_edge: $svc has type '${type}', want NodePort or LoadBalancer" >&2
      return 2
      ;;
  esac

  { [ -n "$addr" ] && [ -n "$port" ]; } \
    || { echo "resolve_edge: $svc has no address or no port yet (addr='${addr}' port='${port}')" >&2; return 3; }

  echo "${addr}:${port}"
}

# ---------------------------------------------------------------------------
# _edge_curl_args <edge> <host>
#
# Echoes the curl args that force <host> at <edge>.
#
# `curl --resolve` only accepts an IP address. A LoadBalancer Service on EKS
# often reports a hostname (`...elb.amazonaws.com`) rather than an IP, so in
# that case the override is dropped and normal DNS resolution is used — which is
# correct there, because a real EKS env has real DNS for app./www./docs. via
# external-dns. Silently emitting an invalid --resolve would make every probe
# return 000 and read as a product failure.
# ---------------------------------------------------------------------------
_edge_curl_args() {
  local edge="$1" host="$2" addr="${1%:*}" port="${1##*:}"
  if printf '%s' "$addr" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    printf -- '--resolve\n%s:%s:%s\n' "$host" "$port" "$addr"
  fi
}

# ---------------------------------------------------------------------------
# edge_status <edge> <host> <path>
#
# Echoes the HTTP status code for https://<host><path> forced at <edge>.
# Echoes 000 on transport failure — callers must treat 000 as a failure, never
# as "not applicable".
# ---------------------------------------------------------------------------
edge_status() {
  local edge="$1" host="$2" path="$3" port="${1##*:}"
  local -a extra=()
  local code=""
  mapfile -t extra < <(_edge_curl_args "$edge" "$host")
  # curl prints "000" AND exits non-zero on a transport failure, so a naive
  # `|| echo 000` concatenates to "000000". Capture, then normalise. The curl
  # error goes to stderr, so the 000 a caller reports comes with its reason.
  capture code curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
    "${extra[@]}" \
    "https://${host}:${port}${path}" \
    || echo "edge_status: https://${host}:${port}${path}: ${PROBE_ERR}" >&2
  case "$code" in
    ""|000) echo "000" ;;
    *)      echo "$code" ;;
  esac
}

# ---------------------------------------------------------------------------
# edge_body <edge> <host> <path>  — the response body, for content assertions.
# ---------------------------------------------------------------------------
edge_body() {
  local edge="$1" host="$2" path="$3" port="${1##*:}"
  local -a extra=()
  local body=""
  mapfile -t extra < <(_edge_curl_args "$edge" "$host")
  # A transport failure prints its curl error to stderr and an empty body.
  capture body curl -sk --max-time 20 \
    "${extra[@]}" \
    "https://${host}:${port}${path}" \
    || echo "edge_body: https://${host}:${port}${path}: ${PROBE_ERR}" >&2
  printf '%s' "$body"
}

# ---------------------------------------------------------------------------
# summary <suite-name>  — the single exit point. Non-zero on any failure.
# ---------------------------------------------------------------------------
summary() {
  local name="$1"
  step "Summary"
  printf '  failed assertions: %d\n' "$fails"
  if [ "$fails" -gt 0 ]; then
    printf '%s%s: %d assertion(s) failed%s\n' "$RED" "$name" "$fails" "$NC" >&2
    exit 1
  fi
  pass "$name: all assertions passed"
  exit 0
}
