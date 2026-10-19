#!/usr/bin/env bash
# Umbrella-chart signature + digest guard (gitops#388, consuming half of
# deploy#1194).
#
# WHAT IT CHECKS, PER ENV UNDER envs/
#
#   1. the chartVersion the env pins resolves, in the registry right now, to
#      the digest recorded in chart-digests.yaml — i.e. the tag has not moved;
#   2. that digest carries a cosign signature from zeroroot-ai/charts's
#      publish-umbrella-chart workflow, keyless via GitHub Actions OIDC;
#   3. a version recorded `signed: false` still has no signature — a stale
#      exemption is a failure, so the debt cannot outlive itself.
#
# WHY THIS IS A GATE AND NOT AN ADMISSION CHECK — READ BEFORE "IMPROVING" IT
#
# This does not stop a compromised registry from serving unsigned bytes to
# ArgoCD at sync time. Nothing in this repo can, today:
#
#   - ArgoCD has no Application-spec field that verifies a cosign signature for
#     a Helm OCI source. Enforcing at sync would need an in-cluster policy
#     layer (Kyverno or the sigstore policy-controller) that is not in this
#     stack and not in the bringup DAG — a new component on the critical path,
#     which is a real decision, not a CI change.
#   - Pinning `targetRevision` to a digest does not work for Helm OCI charts:
#     ArgoCD still appends a semver `--version` flag even when the revision is
#     a digest. Plain OCI artifacts are fine, Helm-packaged charts are not.
#     Upstream: argoproj/argo-cd#24970, argoproj/argo-cd#25078.
#
# So what this buys is detection with a short fuse, in three places: every PR
# that touches an overlay, every promotion before its PR is even opened, and a
# schedule that catches a swap landing after a merge. What it does not buy is
# prevention at sync time. Do not describe it as more than that.
#
# WHY THE DIGEST LEDGER EXISTS ALONGSIDE THE SIGNATURE
#
# A signature check alone does not stop a tag swap. Re-running the trusted
# publish workflow republishes `gibson:X.Y.Z` over different bytes, and the new
# digest is signed by the same identity — a signature-only check waves it
# through. chart-digests.yaml pins what each tag is allowed to mean, so the
# swap fails on the digest comparison even though the signature is valid.
#
# Usage:
#   scripts/verify-chart-signature.sh                 # every env under envs/
#   scripts/verify-chart-signature.sh staging         # named envs
#   scripts/verify-chart-signature.sh --record 0.111.0  # admit a new version
#   scripts/verify-chart-signature.sh --selftest      # prove it still rejects
#
# Requires: helm, cosign, python3, and a registry login for BOTH tools —
# they do not share credentials (helm uses $HELM_REGISTRY_CONFIG, cosign uses
# the go-containerregistry keychain at ~/.docker/config.json). The publish
# workflow hit this exact trap; see its `cosign login (ghcr)` step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_REPO="${CHART_REPO:-oci://ghcr.io/zeroroot-ai/charts/gibson}"
CHART_REF="${CHART_REF:-ghcr.io/zeroroot-ai/charts/gibson}"
LEDGER="${LEDGER:-${REPO_ROOT}/chart-digests.yaml}"

# The identity that must have signed the chart. Keep these two in lockstep with
# zeroroot-ai/charts's .github/workflows/publish-umbrella-chart.yml — its own
# in-job self-check uses exactly this pair. A regexp rather than an exact
# identity because the trailing @refs/tags/vX.Y.Z differs per release; the
# repo, the workflow file and the issuer are what is actually being asserted.
#
# It was the deploy repo until that repo was deleted (ADR-0086). The chart
# is published and signed by zeroroot-ai/charts now, so the old regexp could
# never match a chart signed today. A version published before the split
# carries the old identity and FAILS here: the fix is a promotion onto a
# charts-signed version, not a wider regexp.
IDENTITY_REGEXP="${IDENTITY_REGEXP:-^https://github\.com/zeroroot-ai/charts/\.github/workflows/publish-umbrella-chart\.yml@.*$}"
OIDC_ISSUER="${OIDC_ISSUER:-https://token.actions.githubusercontent.com}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

fail_count=0

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "::error::$1 is required but not on PATH" >&2
    exit 2
  }
}

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
# live_digest <version> — the digest the tag resolves to in the registry RIGHT
# NOW. `helm pull` reports the manifest digest of what it fetched, which is the
# same reference the publish workflow signs (it parses it out of `helm push`).
# Verified end to end rather than assumed.
# ---------------------------------------------------------------------------
live_digest() {
  local version="$1" out
  if ! out="$(helm pull "$CHART_REPO" --version "$version" --destination "$WORKDIR" 2>&1)"; then
    echo "::error::cannot pull ${CHART_REPO}:${version} — $(tail -1 <<<"$out")" >&2
    if grep -q 'not found' <<<"$out"; then
      # The packages are public, so "not found" is the tag, not the token:
      # zeroroot-ai/charts never published this version here, or the package
      # version was deleted. Every version the deleted deploy repo published
      # is in this state (ADR-0086).
      echo "  the registry does not serve this tag. Promote the env onto a version" >&2
      echo "  zeroroot-ai/charts published: gh release list -R zeroroot-ai/charts" >&2
    else
      echo "  the runner needs a ghcr login with read access to the charts package:" >&2
      echo "  echo \"\$TOKEN\" | helm registry login ghcr.io -u \"\$ACTOR\" --password-stdin" >&2
    fi
    return 1
  fi
  local digest
  digest="$(grep -oE 'sha256:[0-9a-f]{64}' <<<"$out" | tail -1)"
  [ -n "$digest" ] || {
    echo "::error::could not parse a digest out of helm pull for ${version}" >&2
    return 1
  }
  echo "$digest"
}

# ---------------------------------------------------------------------------
# ledger_get <version> <field> — read `digest`, `signed` or `unsigned-reason`
# from the ledger. Prints nothing and returns 1 when the version is absent.
# ---------------------------------------------------------------------------
ledger_get() {
  python3 - "$LEDGER" "$1" "$2" <<'PY'
import sys, yaml
ledger, version, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(ledger) as fh:
        data = yaml.safe_load(fh) or {}
except FileNotFoundError:
    sys.exit(1)
charts = (data or {}).get("charts") or {}
entry = charts.get(version)
if entry is None:
    sys.exit(1)
value = entry.get(field)
if value is None:
    sys.exit(1)
print("true" if value is True else "false" if value is False else value)
PY
}

# ---------------------------------------------------------------------------
# cosign_verify <digest> — returns 0 when a valid signature from the expected
# identity exists for that digest.
# ---------------------------------------------------------------------------
cosign_verify() {
  cosign verify \
    --certificate-identity-regexp "$IDENTITY_REGEXP" \
    --certificate-oidc-issuer "$OIDC_ISSUER" \
    "${CHART_REF}@${1}" >"${WORKDIR}/cosign.out" 2>&1
}

# ---------------------------------------------------------------------------
# record <version> — resolve, verify, and write the ledger entry.
# ---------------------------------------------------------------------------
record() {
  local version="$1" digest signed="true" reason=""
  need helm; need cosign; need python3

  printf '%s=== recording %s ===%s\n' "$GREEN" "$version" "$NC"
  digest="$(live_digest "$version")" || exit 2
  printf '  digest: %s\n' "$digest"

  if cosign_verify "$digest"; then
    printf '  %s[PASS]%s signature verified against %s\n' "$GREEN" "$NC" "$OIDC_ISSUER"
  else
    signed="false"
    reason="$(tail -1 "${WORKDIR}/cosign.out")"
    # REQUIRE_SIGNED=1 refuses to write a `signed: false` entry at all. The
    # promotion workflow sets it: recording an exemption is a deliberate act
    # with a reason, and letting an automated promotion mint one silently
    # would turn the exemption mechanism into a rubber stamp.
    if [ "${REQUIRE_SIGNED:-0}" = "1" ]; then
      printf '  %s[FAIL]%s %s has no valid signature: %s\n' "$RED" "$NC" "$version" "$reason"
      printf '         REQUIRE_SIGNED=1, so this will not be recorded as sanctioned debt.\n'
      printf '         Publish a signed chart, or add the exemption by hand with a reason.\n'
      exit 1
    fi
    printf '  %s[WARN]%s no valid signature: %s\n' "$YELLOW" "$NC" "$reason"
    printf '         recording signed: false — this is TRACKED DEBT. The guard\n'
    printf '         fails the day it does verify, so the flag cannot be forgotten.\n'
  fi

  python3 - "$LEDGER" "$version" "$digest" "$signed" "$reason" <<'PY'
import sys, re

ledger, version, digest, signed, reason = sys.argv[1:6]

with open(ledger) as fh:
    text = fh.read()

block = f'  "{version}":\n    digest: "{digest}"\n    signed: {signed}\n'
if signed == "false":
    note = reason.replace('"', "'") or "no valid signature found"
    block += f'    unsigned-reason: "{note}"\n'

pattern = re.compile(
    rf'^  "{re.escape(version)}":\n(?:    .*\n)*', flags=re.MULTILINE
)
if pattern.search(text):
    text = pattern.sub(block, text)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += "\n" + block
with open(ledger, "w") as fh:
    fh.write(text)
print(f"  wrote {version} -> {digest} (signed: {signed})")
PY
}

# ---------------------------------------------------------------------------
# check_version <version> <label> — the whole invariant for one version.
# ---------------------------------------------------------------------------
check_version() {
  local version="$1" label="$2" digest recorded signed

  if ! digest="$(live_digest "$version")"; then
    printf '  %s[FAIL]%s %s: cannot resolve %s in the registry\n' "$RED" "$NC" "$label" "$version"
    fail_count=$((fail_count + 1))
    return
  fi

  if ! recorded="$(ledger_get "$version" digest)"; then
    printf '  %s[FAIL]%s %s: chartVersion %s is not in %s.\n' \
      "$RED" "$NC" "$label" "$version" "$(basename "$LEDGER")"
    printf '         An unrecorded version has never had its signature checked. Admit it with:\n'
    printf '           scripts/verify-chart-signature.sh --record %s\n' "$version"
    fail_count=$((fail_count + 1))
    return
  fi

  if [ "$digest" != "$recorded" ]; then
    printf '  %s[FAIL]%s %s: the tag MOVED. %s resolved to\n' "$RED" "$NC" "$label" "$version"
    printf '           %s\n' "$digest"
    printf '         but %s records\n' "$(basename "$LEDGER")"
    printf '           %s\n' "$recorded"
    printf '         Same tag, different bytes. A re-publish by the trusted workflow would\n'
    printf '         still be validly signed, so the signature alone would not have caught\n'
    printf '         this. Do not update the ledger to match without establishing why the\n'
    printf '         tag moved — that is the attack this check exists for.\n'
    fail_count=$((fail_count + 1))
    return
  fi

  signed="$(ledger_get "$version" signed || echo true)"

  if cosign_verify "$digest"; then
    if [ "$signed" = "false" ]; then
      printf '  %s[FAIL]%s %s: %s is recorded `signed: false` but its signature NOW VERIFIES.\n' \
        "$RED" "$NC" "$label" "$version"
      printf '         Stale exemption — delete the `signed: false` and `unsigned-reason`\n'
      printf '         lines for %s from %s.\n' "$version" "$(basename "$LEDGER")"
      fail_count=$((fail_count + 1))
      return
    fi
    printf '  %s[PASS]%s %s: %s @ %s — signed by %s\n' "$GREEN" "$NC" "$label" "$version" \
      "${digest:0:19}…" "zeroroot-ai/charts publish-umbrella-chart"
    return
  fi

  if [ "$signed" = "false" ]; then
    printf '  %s[WARN]%s %s: %s @ %s — UNSIGNED, sanctioned: %s\n' "$YELLOW" "$NC" "$label" \
      "$version" "${digest:0:19}…" "$(ledger_get "$version" unsigned-reason || echo 'no reason recorded')"
    printf '         The digest still matches, so the tag has not moved. But nothing proves\n'
    printf '         these bytes came from the publish workflow. Promote off it.\n'
    return
  fi

  printf '  %s[FAIL]%s %s: %s @ %s — signature verification FAILED: %s\n' \
    "$RED" "$NC" "$label" "$version" "${digest:0:19}…" "$(tail -1 "${WORKDIR}/cosign.out")"
  printf '         Expected identity matching %s\n' "$IDENTITY_REGEXP"
  printf '         issued by %s\n' "$OIDC_ISSUER"
  fail_count=$((fail_count + 1))
}

# ---------------------------------------------------------------------------
# selftest — the decision logic, driven against a scratch ledger so no network
# round trip is needed and every branch is reachable. Mutating the real
# registry is not an option, so the mutations are on the ledger side: they are
# exactly the states a tag swap, a missing record and a stale exemption
# produce.
# ---------------------------------------------------------------------------
selftest() {
  printf '%s=== selftest ===%s\n' "$GREEN" "$NC"
  local rc=0 real_ledger="$LEDGER"

  # A stub live_digest and cosign_verify let the selftest exercise every branch
  # deterministically. The real ones are restored before the scan.
  local stub_digest
  stub_digest="sha256:$(printf 'a%.0s' {1..64})"
  local stub_signed=0
  live_digest() { echo "$stub_digest"; }
  cosign_verify() { echo "stubbed" >"${WORKDIR}/cosign.out"; return $stub_signed; }

  mk_ledger() { LEDGER="${WORKDIR}/ledger.yaml"; printf 'charts:\n%s' "$1" >"$LEDGER"; }
  run() { fail_count=0; check_version "1.0.0" "selftest" >"${WORKDIR}/st.out" 2>&1; echo "$fail_count"; }

  # (1) version absent from the ledger -> FAIL. Without this, adding a brand
  #     new chartVersion would silently skip verification entirely, which is
  #     the whole gap gitops#388 is about.
  mk_ledger ""
  stub_signed=0
  if [ "$(run)" -gt 0 ] && grep -q 'not in' "${WORKDIR}/st.out"; then
    printf '  %s[PASS]%s selftest 1: an unrecorded chartVersion is rejected\n' "$GREEN" "$NC"
  else
    printf '  %s[FAIL]%s selftest 1: an unrecorded chartVersion was accepted\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/st.out" >&2; rc=1
  fi

  # (2) recorded digest != live digest -> FAIL, even though the signature is
  #     valid. This is the tag-swap case and the reason the ledger exists.
  mk_ledger '  "1.0.0":
    digest: "sha256:'"$(printf 'b%.0s' {1..64})"'"
    signed: true
'
  stub_signed=0
  if [ "$(run)" -gt 0 ] && grep -q 'tag MOVED' "${WORKDIR}/st.out"; then
    printf '  %s[PASS]%s selftest 2: a moved tag is rejected even with a valid signature\n' "$GREEN" "$NC"
  else
    printf '  %s[FAIL]%s selftest 2: a moved tag was accepted\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/st.out" >&2; rc=1
  fi

  # (3) digest matches, signature valid, recorded signed: true -> PASS. The
  #     negative control: a checker that rejects everything is not a checker.
  mk_ledger '  "1.0.0":
    digest: "'"$stub_digest"'"
    signed: true
'
  stub_signed=0
  if [ "$(run)" -eq 0 ] && grep -q 'PASS' "${WORKDIR}/st.out"; then
    printf '  %s[PASS]%s selftest 3: a matching, validly signed version is accepted\n' "$GREEN" "$NC"
  else
    printf '  %s[FAIL]%s selftest 3: a good version was rejected\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/st.out" >&2; rc=1
  fi

  # (4) signature invalid while recorded signed: true -> FAIL.
  stub_signed=1
  if [ "$(run)" -gt 0 ] && grep -q 'verification FAILED' "${WORKDIR}/st.out"; then
    printf '  %s[PASS]%s selftest 4: a version expected to be signed but failing cosign is rejected\n' "$GREEN" "$NC"
  else
    printf '  %s[FAIL]%s selftest 4: an unverifiable signature was accepted\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/st.out" >&2; rc=1
  fi

  # (5) recorded signed: false and still unsigned -> WARN, not a failure. This
  #     is today's prod/dev state; failing it would just be breakage.
  mk_ledger '  "1.0.0":
    digest: "'"$stub_digest"'"
    signed: false
    unsigned-reason: "selftest"
'
  stub_signed=1
  if [ "$(run)" -eq 0 ] && grep -q 'UNSIGNED, sanctioned' "${WORKDIR}/st.out"; then
    printf '  %s[PASS]%s selftest 5: a sanctioned unsigned version warns without failing\n' "$GREEN" "$NC"
  else
    printf '  %s[FAIL]%s selftest 5: the sanctioned-unsigned path is wrong\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/st.out" >&2; rc=1
  fi

  # (6) recorded signed: false but it NOW verifies -> FAIL as a stale
  #     exemption. This is what stops the debt outliving itself.
  stub_signed=0
  if [ "$(run)" -gt 0 ] && grep -q 'Stale exemption' "${WORKDIR}/st.out"; then
    printf '  %s[PASS]%s selftest 6: a stale `signed: false` exemption is rejected\n' "$GREEN" "$NC"
  else
    printf '  %s[FAIL]%s selftest 6: a stale exemption survived\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/st.out" >&2; rc=1
  fi

  # (7) an empty / missing ledger must not read as "nothing to check".
  LEDGER="${WORKDIR}/absent.yaml"
  stub_signed=0
  if [ "$(run)" -gt 0 ]; then
    printf '  %s[PASS]%s selftest 7: a missing ledger fails rather than passing vacuously\n' "$GREEN" "$NC"
  else
    printf '  %s[FAIL]%s selftest 7: a missing ledger was treated as clean\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/st.out" >&2; rc=1
  fi

  unset -f live_digest cosign_verify mk_ledger run
  # Re-source the real implementations the stubs shadowed.
  eval "$(declare -f real_live_digest | sed '1s/real_live_digest/live_digest/')"
  eval "$(declare -f real_cosign_verify | sed '1s/real_cosign_verify/cosign_verify/')"
  LEDGER="$real_ledger"
  fail_count=0
  return $rc
}

# Keep pristine copies so the selftest's stubs can be undone.
eval "$(declare -f live_digest | sed '1s/live_digest/real_live_digest/')"
eval "$(declare -f cosign_verify | sed '1s/cosign_verify/real_cosign_verify/')"

# ---------------------------------------------------------------------------
main() {
  case "${1:-}" in
    --record)
      [ -n "${2:-}" ] || { echo "::error::--record needs a chartVersion" >&2; exit 2; }
      record "$2"
      exit 0
      ;;
    --selftest)
      need python3
      selftest
      exit $?
      ;;
  esac

  need helm; need cosign; need python3

  local envs=("$@")
  if [ ${#envs[@]} -eq 0 ]; then
    mapfile -t envs < <(find "${REPO_ROOT}/envs" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
  fi

  selftest || exit 1

  printf '\n%s=== pinned chart versions ===%s\n' "$GREEN" "$NC"
  local checked=0 seen=() version
  for env in "${envs[@]}"; do
    resolve_app "$env" >/dev/null 2>&1 || continue
    version="$(chart_version "$env" 2>/dev/null || true)"
    if [ -z "$version" ]; then
      printf '  %s[FAIL]%s %s: no single OCI umbrella pin in the platform Application\n' "$RED" "$NC" "$env"
      fail_count=$((fail_count + 1))
      continue
    fi
    # One registry round trip per distinct version, but name every env that
    # pins it so a failure says which environments are affected.
    local already=""
    for s in ${seen[@]+"${seen[@]}"}; do
      [ "$s" = "$version" ] && already=1
    done
    if [ -n "$already" ]; then
      printf '  %s[INFO]%s %s also pins %s (checked above)\n' "$YELLOW" "$NC" "$env" "$version"
      continue
    fi
    seen+=("$version")
    check_version "$version" "$env"
    checked=$((checked + 1))
  done

  # Zero versions checked means the env discovery produced nothing. Reporting
  # success from that state is how a guard quietly stops guarding.
  if [ "$checked" -eq 0 ]; then
    printf '\n%s[FAIL]%s no env pinned a chartVersion — nothing was verified\n' "$RED" "$NC"
    exit 1
  fi

  printf '\n%s=== summary ===%s\n' "$GREEN" "$NC"
  printf '  chart versions checked: %s   failures: %s\n' "$checked" "$fail_count"
  if [ "$fail_count" -gt 0 ]; then
    printf '%s[FAIL]%s a pinned umbrella chart is unverified or its tag has moved\n' "$RED" "$NC"
    exit 1
  fi
  printf '%s[PASS]%s every pinned chart resolves to its recorded digest\n' "$GREEN" "$NC"
}

main "$@"
