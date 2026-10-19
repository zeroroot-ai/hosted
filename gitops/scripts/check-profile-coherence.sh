#!/usr/bin/env bash
# Deployment-profile coherence guard over the env overlays (gitops#356).
#
# WHY THIS EXISTS AND WHY IT RENDERS
#
# deploy's helm/gibson/tests/signup-seam.bats already encodes the SaaS /
# self-hosted invariant, but it only guards the chart's OWN ci/ fixtures. The
# overlays that actually ship live here, and both real environments violated
# the invariant undetected: prod ran billing-on with no WWW_URL (the deploy#1075
# combination — the deployment-profile resolver fail-closes and the dashboard
# 500s on every route incl. /login), and staging + prod both pointed the daemon
# at the entitlements seam without requiring it, i.e. fail-OPEN to unlimited.
#
# This guard renders each env's values against THAT ENV'S OWN pinned
# chartVersion, not the chart tip. That distinction is the point: a value can be
# set in an overlay while the pinned chart has no template to consume it, so the
# knob is silently inert. prod was exactly that case: entitlementsEndpoint had
# been set for months while chartVersion sat on 0.104.0, which predates the seam
# templates (they land in 0.105.0), so prod's daemon ran the embedded unlimited
# provider no matter what the overlay said (gitops#359). prod advanced to 0.109.2
# in gitops#378 and the seam renders now — but the class of bug is what this
# guard is for, and only a render can see it; grepping the values file cannot.
#
# THE INVARIANT (both directions)
#
#   SaaS profile        — ALL of: DASHBOARD_BILLING_PAID_TIERS_ENABLED=true,
#                         WWW_URL, ENTITLEMENTS_ENDPOINT,
#                         GIBSON_ENTITLEMENTS_REQUIRED=true
#   self-hosted profile — NONE of the above
#   both                — SIGNUP_SELF_SERVE agrees between the daemon workload
#                         and the dashboard workload
#
# Anything in between is incoherent and fails.
#
# EXEMPTIONS
#
# scripts/.profile-coherence-exemptions.txt carries `env:check:reason` lines for
# sanctioned, tracked debt (same shape as deploy's hostname allowlist). An
# exemption downgrades a failure to a warning; a STALE exemption — one whose
# check now passes — is itself a failure, so exemptions cannot outlive the debt.
#
# Usage:
#   scripts/check-profile-coherence.sh              # every env under envs/
#   scripts/check-profile-coherence.sh staging prod  # named envs
#   scripts/check-profile-coherence.sh --selftest   # prove the checker catches
#                                                   # a synthetic incoherent env
#
# Requires: helm, python3, and a ghcr login able to pull
# oci://ghcr.io/zeroroot-ai/charts/gibson.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_REPO="${CHART_REPO:-oci://ghcr.io/zeroroot-ai/charts/gibson}"
EXEMPTIONS="${REPO_ROOT}/scripts/.profile-coherence-exemptions.txt"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

fail_count=0
warn_count=0

# ---------------------------------------------------------------------------
# chart_version <env> — the OCI umbrella pin in the env's platform Application
# (the values.yaml chartVersion marker was deleted in gitops#448).
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/chart-version.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/chart-version.sh"
chart_version() {
  env_chart_version "$1"
}

# ---------------------------------------------------------------------------
# fetch_chart <version> — pull the chart once per version into $WORKDIR.
# ---------------------------------------------------------------------------
fetch_chart() {
  local version="$1" tgz="${WORKDIR}/gibson-${1}.tgz"
  [ -f "$tgz" ] && { echo "$tgz"; return; }
  if ! helm pull "$CHART_REPO" --version "$version" --destination "$WORKDIR" >/dev/null 2>"${WORKDIR}/pull.err"; then
    echo "::error::cannot pull ${CHART_REPO}:${version} — $(tail -1 "${WORKDIR}/pull.err")" >&2
    echo "  the runner needs a ghcr login with read access to the charts package:" >&2
    echo "  echo \"\$TOKEN\" | helm registry login ghcr.io -u \"\$ACTOR\" --password-stdin" >&2
    exit 2
  fi
  echo "$tgz"
}

# ---------------------------------------------------------------------------
# profile_facts <rendered.yaml> — emit `KEY=value` lines describing the profile
# knobs present in the render. Walks the manifests properly rather than
# grepping, so a knob named in a comment or a ConfigMap payload cannot be
# mistaken for a live env var on a workload.
# ---------------------------------------------------------------------------
profile_facts() {
  python3 - "$1" <<'PY'
import sys, re, yaml

WANTED = {
    "DASHBOARD_BILLING_PAID_TIERS_ENABLED",
    "WWW_URL",
    "ENTITLEMENTS_ENDPOINT",
    "GIBSON_ENTITLEMENTS_REQUIRED",
    "SIGNUP_SELF_SERVE",
}


class Loader(yaml.SafeLoader):
    """SafeLoader that survives a rendered platform.

    A chart this size embeds third-party config (Grafana dashboards, Prometheus
    rules) that legally carries tags SafeLoader refuses — a bare `=` key parses
    as tag:yaml.org,2002:value and aborts the whole document stream. Losing the
    stream would leave every profile knob looking absent, which reads as a
    perfectly coherent self-hosted profile: a silent false PASS, the exact
    failure the selftest caught. Tolerate unknown tags instead.
    """


Loader.add_constructor(
    "tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node)
)
Loader.add_multi_constructor(
    "", lambda loader, suffix, node: loader.construct_scalar(node)
    if isinstance(node, yaml.ScalarNode)
    else None
)

found = {}
signup = {}
workloads = 0
unparsed = 0

with open(sys.argv[1]) as fh:
    raw = fh.read()

# Parse per document so one unparseable manifest cannot take the rest with it.
for chunk in re.split(r"^---\s*$", raw, flags=re.MULTILINE):
    if not chunk.strip():
        continue
    try:
        doc = yaml.load(chunk, Loader=Loader)
    except yaml.YAMLError as exc:
        unparsed += 1
        print(f"unparseable manifest skipped: {str(exc).splitlines()[0]}", file=sys.stderr)
        continue
    if not isinstance(doc, dict) or doc.get("kind") not in ("Deployment", "StatefulSet"):
        continue
    workloads += 1
    meta = doc.get("metadata") or {}
    template = ((doc.get("spec") or {}).get("template") or {})
    labels = (template.get("metadata") or {}).get("labels") or {}
    component = (
        labels.get("app.kubernetes.io/component")
        or (meta.get("labels") or {}).get("app.kubernetes.io/component")
        or meta.get("name", "?")
    )
    for c in (template.get("spec") or {}).get("containers") or []:
        for e in c.get("env") or []:
            name = e.get("name")
            if name not in WANTED:
                continue
            value = "" if e.get("value") is None else str(e["value"])
            if name == "SIGNUP_SELF_SERVE":
                signup[component] = value
            else:
                found[name] = value

# Zero workloads means the parse produced nothing usable. Reporting "all knobs
# absent" from that state would be indistinguishable from a genuine self-hosted
# render, so fail loudly instead.
if workloads == 0:
    print("no Deployment/StatefulSet parsed from the render", file=sys.stderr)
    sys.exit(3)

for k in sorted(WANTED - {"SIGNUP_SELF_SERVE"}):
    print(f"{k}={found[k]}" if k in found else f"{k}=<absent>")
for comp in sorted(signup):
    print(f"SIGNUP_SELF_SERVE@{comp}={signup[comp]}")
PY
}

# ---------------------------------------------------------------------------
# exempt <env> <check> — is this failure sanctioned debt?
# ---------------------------------------------------------------------------
declare -a USED_EXEMPTIONS=()
EXEMPT_REASON=""

# Sets EXEMPT_REASON and records the hit. Deliberately NOT called through a
# command substitution: that would run it in a subshell and the USED_EXEMPTIONS
# append would evaporate, making every exemption look stale.
exempt() {
  local env="$1" check="$2" line
  EXEMPT_REASON=""
  [ -f "$EXEMPTIONS" ] || return 1
  line="$(grep -v '^#' "$EXEMPTIONS" | grep -v '^[[:space:]]*$' | grep "^${env}:${check}:" || true)"
  [ -n "$line" ] || return 1
  USED_EXEMPTIONS+=("${env}:${check}")
  EXEMPT_REASON="${line#*:*:}"
}

report() { # report <env> <check> <message>
  local env="$1" check="$2" msg="$3"
  if exempt "$env" "$check"; then
    printf '  %s[WARN]%s %s — exempt: %s\n' "$YELLOW" "$NC" "$msg" "$EXEMPT_REASON"
    warn_count=$((warn_count + 1))
  else
    printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$msg"
    fail_count=$((fail_count + 1))
  fi
}

# ---------------------------------------------------------------------------
# check_env <env> [values-override]
# ---------------------------------------------------------------------------
check_env() {
  local env="$1"
  local values="${2:-${REPO_ROOT}/envs/${env}/values.yaml}"
  local version tgz rendered facts

  version="$(chart_version "$env")"
  [ -n "$version" ] || { echo "::error::cannot resolve the pinned chart version for ${env} from its platform Application"; exit 2; }
  tgz="$(fetch_chart "$version")"
  rendered="${WORKDIR}/${env}.yaml"

  printf '\n%s=== %s (chart %s) ===%s\n' "$GREEN" "$env" "$version" "$NC"
  if ! helm template gibson "$tgz" -n gibson -f "$values" >"$rendered" 2>"${WORKDIR}/${env}.err"; then
    printf '  %s[FAIL]%s render failed: %s\n' "$RED" "$NC" "$(tail -1 "${WORKDIR}/${env}.err")"
    fail_count=$((fail_count + 1))
    return
  fi

  if ! facts="$(profile_facts "$rendered" 2>"${WORKDIR}/${env}.parse.err")"; then
    printf '  %s[FAIL]%s could not read profile knobs from the render: %s\n' \
      "$RED" "$NC" "$(tail -1 "${WORKDIR}/${env}.parse.err")"
    fail_count=$((fail_count + 1))
    return
  fi
  local billing www endpoint required
  billing="$(sed -n 's/^DASHBOARD_BILLING_PAID_TIERS_ENABLED=//p' <<<"$facts")"
  www="$(sed -n 's/^WWW_URL=//p' <<<"$facts")"
  endpoint="$(sed -n 's/^ENTITLEMENTS_ENDPOINT=//p' <<<"$facts")"
  required="$(sed -n 's/^GIBSON_ENTITLEMENTS_REQUIRED=//p' <<<"$facts")"

  local billing_on=0 www_on=0 endpoint_on=0 required_on=0
  [ "$billing" = "true" ] && billing_on=1
  [ "$www" != "<absent>" ] && [ -n "$www" ] && www_on=1
  [ "$endpoint" != "<absent>" ] && [ -n "$endpoint" ] && endpoint_on=1
  [ "$required" = "true" ] && required_on=1

  printf '  billing=%s www=%s entitlements=%s required=%s\n' \
    "$billing_on" "$www_on" "$endpoint_on" "$required_on"

  local on=$((billing_on + www_on + endpoint_on + required_on))
  if [ "$on" -eq 4 ]; then
    printf '  %s[PASS]%s coherent SaaS profile\n' "$GREEN" "$NC"
  elif [ "$on" -eq 0 ]; then
    printf '  %s[PASS]%s coherent self-hosted profile\n' "$GREEN" "$NC"
  else
    # Name the specific missing half so the failure is actionable rather than
    # "something is incoherent".
    [ "$billing_on" -eq 1 ] && [ "$www_on" -eq 0 ] && report "$env" "billing-without-www" \
      "DASHBOARD_BILLING_PAID_TIERS_ENABLED=true with no WWW_URL — the deployment-profile resolver fail-closes and the dashboard 500s on every route (deploy#1075)"
    [ "$www_on" -eq 1 ] && [ "$billing_on" -eq 0 ] && report "$env" "www-without-billing" \
      "WWW_URL set with billing off — self-hosted installs must not link a marketing surface (dashboard#920)"
    [ "$endpoint_on" -eq 1 ] && [ "$required_on" -eq 0 ] && report "$env" "entitlements-fail-open" \
      "ENTITLEMENTS_ENDPOINT set without GIBSON_ENTITLEMENTS_REQUIRED=true — the seam degrades to unlimited instead of denying (deploy#1055)"
    [ "$required_on" -eq 1 ] && [ "$endpoint_on" -eq 0 ] && report "$env" "required-without-endpoint" \
      "GIBSON_ENTITLEMENTS_REQUIRED=true with no ENTITLEMENTS_ENDPOINT — the daemon fails closed with nothing to dial"
    [ "$billing_on" -eq 1 ] && [ "$endpoint_on" -eq 0 ] && report "$env" "entitlements-seam-absent" \
      "billing is on but the entitlements seam does not render — plan limits are not enforced (a knob set in the overlay that this chartVersion has no template for renders nothing; see gitops#359)"
    [ "$endpoint_on" -eq 1 ] && [ "$billing_on" -eq 0 ] && report "$env" "entitlements-without-billing" \
      "entitlements seam wired with billing off — an incoherent half-SaaS profile"
  fi

  # SIGNUP_SELF_SERVE must agree across workloads: a daemon that serves public
  # signup behind a dashboard that hides it (or the reverse) is a half-open
  # front door.
  # `|| true` throughout: this runs under `set -o pipefail`, and a grep that
  # matches nothing is a legitimate outcome here — an older chartVersion may not
  # emit the knob at all — not a reason to abort the whole guard.
  local signup_lines signup_values
  signup_lines="$(grep '^SIGNUP_SELF_SERVE@' <<<"$facts" || true)"
  if [ -n "$signup_lines" ]; then
    signup_values="$(sed 's/.*=//' <<<"$signup_lines" | sort -u)"
    if [ "$(wc -l <<<"$signup_values")" -gt 1 ]; then
      report "$env" "signup-disagreement" \
        "SIGNUP_SELF_SERVE disagrees across workloads: $(tr '\n' ' ' <<<"$signup_lines")"
    fi
  fi
}

# ---------------------------------------------------------------------------
# selftest — synthesise an incoherent overlay from a real one and assert the
# checker rejects it. Proves the guard can still catch a regression, rather
# than passing because every assertion silently became a no-op.
# ---------------------------------------------------------------------------
selftest() {
  printf '%s=== selftest ===%s\n' "$GREEN" "$NC"
  local base="${REPO_ROOT}/envs/staging/values.yaml"
  local mutant="${WORKDIR}/incoherent.yaml"

  # Drop wwwUrl from a SaaS overlay: billing stays on, marketing host vanishes.
  grep -v '^    wwwUrl:' "$base" >"$mutant"

  local before=$fail_count
  # Output is captured, not discarded: the mutant's own FAIL lines would read
  # as real failures in CI, but they are the evidence when the selftest itself
  # goes wrong, so dump them only then.
  check_env staging "$mutant" >"${WORKDIR}/selftest.out" 2>&1 || true
  if [ "$fail_count" -gt "$before" ]; then
    printf '  %s[PASS]%s selftest: a SaaS overlay with WWW_URL removed is rejected\n' "$GREEN" "$NC"
    fail_count=$before
    warn_count=0
    USED_EXEMPTIONS=()
    return 0
  fi
  printf '  %s[FAIL]%s selftest: the checker did NOT reject an incoherent overlay\n' "$RED" "$NC"
  sed 's/^/    | /' "${WORKDIR}/selftest.out" >&2
  return 1
}

# ---------------------------------------------------------------------------
main() {
  if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
  fi

  local envs=("$@")
  if [ ${#envs[@]} -eq 0 ]; then
    mapfile -t envs < <(find "${REPO_ROOT}/envs" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
  fi

  selftest || exit 1

  for env in "${envs[@]}"; do
    [ -f "${REPO_ROOT}/envs/${env}/values.yaml" ] || continue
    check_env "$env"
  done

  # A stale exemption is a failure: the debt it covers is gone, so the line must
  # go too. This is what keeps the file monotonically shrinking.
  #
  # Scoped to the envs actually checked. Running the guard for a subset
  # (`check-profile-coherence.sh staging`) must not report another env's exemption
  # as stale just because that env was never rendered — the entry would look
  # unused and fail a run that proved nothing about it.
  if [ -f "$EXEMPTIONS" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in \#*) continue ;; esac
      local exempt_env="${line%%:*}"
      local checked=0
      for e in "${envs[@]}"; do
        [ "$e" = "$exempt_env" ] && checked=1
      done
      [ "$checked" -eq 0 ] && continue
      local key="${exempt_env}:$(cut -d: -f2 <<<"$line")"
      local used=0
      for u in ${USED_EXEMPTIONS[@]+"${USED_EXEMPTIONS[@]}"}; do
        [ "$u" = "$key" ] && used=1
      done
      if [ "$used" -eq 0 ]; then
        printf '\n%s[FAIL]%s stale exemption %s — the check now passes; delete the line\n' "$RED" "$NC" "$key"
        fail_count=$((fail_count + 1))
      fi
    done < <(grep -v '^[[:space:]]*$' "$EXEMPTIONS")
  fi

  printf '\n%s=== summary ===%s\n' "$GREEN" "$NC"
  printf '  failures: %s   sanctioned (exempt): %s\n' "$fail_count" "$warn_count"
  if [ "$fail_count" -gt 0 ]; then
    printf '%s[FAIL]%s deployment-profile coherence violated\n' "$RED" "$NC"
    exit 1
  fi
  printf '%s[PASS]%s every env overlay renders a coherent deployment profile\n' "$GREEN" "$NC"
}

main "$@"
