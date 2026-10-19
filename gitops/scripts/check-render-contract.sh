#!/usr/bin/env bash
# Render-contract gate over the env overlays (gitops#487).
#
# WHY THIS EXISTS
#
# Values-contract breaks between the pinned umbrella chart and an env overlay
# were only ever caught live. The 0.113.0 staging promotion shipped three in
# one window: the ClusterSecretStore provider knob cutover silently fell back
# to the kind store and degraded every ExternalSecret (deploy#1469 →
# gitops#486), the FGA HTTP listener grew TLS while the overlays still dialed
# http:// and the tenant-operator wedged NotReady (deploy#1491 → gitops#490),
# and the setec installer default turned on with no overlay opt-out
# (deploy#1445 → gitops#489). helm renders fine in every one of those states:
# unknown keys are ignored, dead knobs are inert, and the failure mode is a
# degraded resource discovered on the live cluster.
#
# This gate renders each env's overlay against THAT ENV'S OWN pinned
# chartVersion (the OCI targetRevision in its platform Application — same
# resolution as check-profile-coherence.sh) and asserts a curated list of
# render-time invariants. On a promotion PR the pin in the diff IS the new
# version, so the render the gate checks is exactly the render the cluster
# will apply after merge — the class above becomes a red PR check.
#
# THE INVARIANTS
#
#   render      the chart must template at all against the overlay (a chart-
#               side `required`/fail is a contract break, e.g. the
#               spire.identityAdmission.workloadCreators requirement).
#               NOT exemptible: an env that cannot render is undeployable,
#               and no other invariant below can even be evaluated.
#   eso-store   every env must render exactly one `gibson-secrets`
#               ClusterSecretStore, and its provider must be `vault`
#               (OpenBao). ADR-0083 and deploy#1733 made OpenBao the ONE
#               External Secrets backend on every substrate and deleted the
#               backend selector, so an `aws`-provider store anywhere is the
#               deleted path coming back, and a MISSING gibson-secrets store
#               is the gitops#486 break in its new shape: every ExternalSecret
#               points at a store that does not exist.
#   fga-scheme  the scheme of every rendered gibson-openfga URL must match the
#               chart's FGA listener posture: if the chart renders the
#               `gibson-openfga-http-tls` Certificate (server TLS on the HTTP
#               listener, deploy#1382/#1491) every consumer must dial https;
#               if it does not, every consumer must dial http. Mixed schemes
#               always fail (the gitops#490 break).
#   images      every workload container image must be non-empty and carry a
#               tag or digest — a knob rename that empties an image renders
#               fine and ImagePullBackOffs live.
#   tool-dispatch
#               the daemon must have somewhere to run a tool. A tool executes
#               only as a setec sandbox guest, never as a pod (ADR-0052), so an
#               env classified `require` must render `sandbox.enabled: true`
#               and an env classified `deny` must not. Without it EVERY tool
#               node fails with nothing red anywhere — the gitops#553 break,
#               which staging first reached by a missing tool catalog and can
#               still reach by a missing sandbox.
#               This check does NOT assert the tool set itself. Since ADR-0117
#               (gibson#1662, deploy#1708) tools are catalog manifests baked
#               into the daemon image and gated per tenant by an FGA tuple
#               (`can_execute` on `component:tool/<name>`); neither is visible
#               in a render, and the `tool_runner` knob this check used to
#               assert no longer exists in the chart (gitops#556).
#
# ENV CLASSIFICATION is intrinsic and explicit (env_expectations below), not
# read from the overlay — the overlay knob being wrong is the failure mode
# this gate exists to catch, so it cannot also be the oracle. An env this
# script does not know fails loudly: classify it before shipping it.
#
# STAGED CUTOVERS AND THE PROMOTION-ISOLATION GUARD
#
# check-promotion-isolation.sh (gitops#448) forbids a pin bump and a
# values.yaml change in one revision, so a promotion whose new chart version
# breaks a contract CANNOT ride with its own values fix — the repo passes
# through one revision where the pin and the overlay disagree. That staged
# break is declared, not waved through: add a line to
# scripts/.render-contract-exemptions.txt (`env:check:reason with the tracking
# issue`) in the promotion PR, and delete it in the immediately-following
# values PR. A STALE exemption — one whose check now passes — fails the gate,
# so the line cannot outlive the window it covers. Same mechanism and
# semantics as scripts/.profile-coherence-exemptions.txt (gitops#356).
#
# Usage:
#   scripts/check-render-contract.sh                # every env under envs/
#   scripts/check-render-contract.sh staging prod    # named envs
#   scripts/check-render-contract.sh --selftest     # prove every assertion
#                                                   # can fail (mutation set)
#
# Requires: helm and python3 (+pyyaml). The chart package
# oci://ghcr.io/zeroroot-ai/charts/gibson is public, so a pull needs no login.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_REPO="${CHART_REPO:-oci://ghcr.io/zeroroot-ai/charts/gibson}"
EXEMPTIONS="${REPO_ROOT}/scripts/.render-contract-exemptions.txt"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# shellcheck source=scripts/lib/chart-version.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/chart-version.sh"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

fail_count=0
warn_count=0

# ---------------------------------------------------------------------------
# env_expectations <env> — prints "<store> <dispatch-policy>".
#   store: aws | kind   dispatch: require | deny
# Fails on an unknown env: classification is a decision, not a default.
#
# dispatch is classified, not read from the overlay, for the reason stated
# above: the overlay knob being wrong is what this gate catches, so it cannot
# be its own oracle. It tracks whether the env has a sandbox to dispatch into.
# Staging runs setec (deploy#1080); prod does not enable it in its overlay
# today. Flip an env to `require` in the same change that turns its setec on.
# ---------------------------------------------------------------------------
env_expectations() {
  case "$1" in
    staging)      echo "aws require" ;;
    prod)         echo "aws deny" ;;
    *)
      echo "::error::env '$1' is not classified in check-render-contract.sh — add it to env_expectations before shipping it" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# fetch_chart <version> — pull the chart once per version into $WORKDIR.
# ---------------------------------------------------------------------------
fetch_chart() {
  local version="$1" tgz="${WORKDIR}/gibson-${1}.tgz"
  [ -f "$tgz" ] && { echo "$tgz"; return; }
  if ! helm pull "$CHART_REPO" --version "$version" --destination "$WORKDIR" >/dev/null 2>"${WORKDIR}/pull.err"; then
    echo "::error::cannot pull ${CHART_REPO}:${version} — $(tail -1 "${WORKDIR}/pull.err")" >&2
    echo "  the charts package is public, so a pull needs no login: check the version and the network" >&2
    exit 2
  fi
  echo "$tgz"
}

# ---------------------------------------------------------------------------
# contract_facts <rendered.yaml> <store> <tools-policy>
# Emits one line per violated invariant: "<check>\t<message>". Emits nothing
# when the render honours the contract. Walks manifests properly — a URL in a
# rendered YAML comment must not satisfy or trip a scheme assertion (guards
# have been fooled by rendered comments before).
# ---------------------------------------------------------------------------
contract_facts() {
  python3 - "$1" "$2" "$3" <<'PY'
import re
import sys

import yaml


class Loader(yaml.SafeLoader):
    """SafeLoader that survives a rendered platform (unknown tags tolerated).

    Same rationale as check-profile-coherence.sh: embedded third-party config
    carries tags SafeLoader refuses, and losing the document stream would make
    every invariant look vacuously satisfied.
    """


Loader.add_constructor(
    "tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node)
)
Loader.add_multi_constructor(
    "", lambda loader, suffix, node: loader.construct_scalar(node)
    if isinstance(node, yaml.ScalarNode)
    else None
)

WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}
FGA_URL = re.compile(r"(https?)://gibson-openfga[\w.\-]*(?::\d+)?")

rendered, store_expect, dispatch_policy = sys.argv[1], sys.argv[2], sys.argv[3]

with open(rendered) as fh:
    raw = fh.read()

stores = {}          # name -> provider keys
daemonsets = set()
certificates = set()
fga_schemes = set()
workloads = 0
daemon_cfg = None    # the daemon's own gibson.yaml, parsed out of its ConfigMap
bad_images = []
image_count = 0
unparsed = 0


def containers_of(doc):
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    if kind == "CronJob":
        spec = ((spec.get("jobTemplate") or {}).get("spec") or {})
    template = spec.get("template") or {}
    pod = template.get("spec") or {}
    return (pod.get("containers") or []) + (pod.get("initContainers") or [])


for chunk in re.split(r"^---\s*$", raw, flags=re.MULTILINE):
    if not chunk.strip():
        continue
    # Scheme scan: real lines only — a rendered comment is prose, not a dial.
    for line in chunk.splitlines():
        if line.lstrip().startswith("#"):
            continue
        for m in FGA_URL.finditer(line):
            fga_schemes.add(m.group(1))
    try:
        doc = yaml.load(chunk, Loader=Loader)
    except yaml.YAMLError as exc:
        unparsed += 1
        print(f"unparseable manifest skipped: {str(exc).splitlines()[0]}", file=sys.stderr)
        continue
    if not isinstance(doc, dict):
        continue
    kind = doc.get("kind")
    name = (doc.get("metadata") or {}).get("name", "?")
    if kind == "ConfigMap" and "gibson.yaml" in (doc.get("data") or {}):
        # The daemon's own config. Its knobs are not Kubernetes fields, so
        # nothing else in this gate can see them: they ride as a YAML string
        # inside the ConfigMap and are only ever read by the daemon at boot.
        try:
            parsed = yaml.load(doc["data"]["gibson.yaml"], Loader=Loader)
        except yaml.YAMLError as exc:
            print(f"daemon config in ConfigMap/{name} is not parseable: "
                  f"{str(exc).splitlines()[0]}", file=sys.stderr)
        else:
            if isinstance(parsed, dict):
                daemon_cfg = parsed
    if kind == "ClusterSecretStore":
        stores[name] = sorted((doc.get("spec") or {}).get("provider") or {})
    elif kind == "DaemonSet":
        daemonsets.add(name)
    elif kind == "Certificate":
        certificates.add(name)
    if kind in WORKLOAD_KINDS:
        workloads += 1
        for c in containers_of(doc):
            image_count += 1
            image = c.get("image") or ""
            # A usable image ref carries a tag or digest; a bare or empty ref
            # renders fine and fails at pull time.
            if not image or (":" not in image.split("/")[-1] and "@" not in image):
                bad_images.append(f"{kind}/{name} container {c.get('name', '?')}: {image!r}")

failures = []

# Parsing zero workloads means the render stream was lost — every invariant
# below would pass vacuously, so fail loudly instead (same guard as
# profile-coherence).
if workloads == 0:
    print("render\tno workload manifests parsed from the render — assertions would be vacuous")
    sys.exit(0)

# eso-store
# ADR-0083 / deploy#1733: OpenBao is the ONE External Secrets backend on every
# substrate. There is no backend to select, so the env's classification no
# longer changes what must render — every env owes the same one store.
aws_stores = [n for n, p in stores.items() if p == ["aws"]]
if aws_stores:
    failures.append(
        f"eso-store\tClusterSecretStore(s) {aws_stores} render the aws provider — "
        "the AWS backend was DELETED (ADR-0083, deploy#1733). OpenBao is the one "
        "backend on every substrate; an aws-provider store is the deleted path back"
    )
elif stores.get("gibson-secrets") != ["vault"]:
    got = stores.get("gibson-secrets")
    failures.append(
        "eso-store\tClusterSecretStore gibson-secrets must render with the vault "
        f"(OpenBao) provider, got {got if got else 'no gibson-secrets store at all'} — "
        "every ExternalSecret in the chart targets gibson-secrets by name, so a "
        "missing or wrongly-backed store degrades all of them (gitops#486)"
    )

# fga-scheme
tls_listener = "gibson-openfga-http-tls" in certificates
want = "https" if tls_listener else "http"
if fga_schemes and fga_schemes != {want}:
    posture = (
        "the chart renders the gibson-openfga-http-tls Certificate (TLS listener)"
        if tls_listener
        else "the chart renders no gibson-openfga-http-tls Certificate (plain listener)"
    )
    failures.append(
        f"fga-scheme\trendered gibson-openfga URLs use scheme(s) {sorted(fga_schemes)} but {posture} "
        f"— every consumer must dial {want}:// (the deploy#1491/gitops#490 break)"
    )

# images
if bad_images:
    failures.append(
        "images\t" + str(len(bad_images)) + " container image(s) without a tag or digest: "
        + "; ".join(bad_images[:5])
    )

# tool-dispatch
sandboxed = bool(((daemon_cfg or {}).get("sandbox") or {}).get("enabled"))

if daemon_cfg is None:
    failures.append(
        "tool-dispatch\tno daemon ConfigMap carrying gibson.yaml was parsed from the render — "
        "the dispatch assertion would pass vacuously"
    )
elif dispatch_policy == "require":
    if not sandboxed:
        failures.append(
            "tool-dispatch\tthis env must be able to dispatch a tool but the render has no "
            "sandboxed dispatch path (sandbox.enabled is false) — a tool runs as a setec sandbox "
            "guest, never a pod (ADR-0052), so EVERY tool node fails with nothing red anywhere "
            "(gitops#553)"
        )
elif sandboxed:
    failures.append(
        "tool-dispatch\tsandbox.enabled is true on an env classified as having no sandbox to "
        "dispatch into — either this env now runs setec (reclassify it in env_expectations, "
        "in the same change) or the sandbox config is inert here"
    )

print(f"workloads={workloads} images={image_count} stores={len(stores)} "
      f"fga_schemes={sorted(fga_schemes)} tls_listener={tls_listener} "
      f"sandbox={'on' if sandboxed else 'off'}", file=sys.stderr)
for f in failures:
    print(f)
PY
}

# ---------------------------------------------------------------------------
# exempt <env> <check> — is this failure sanctioned, staged debt?
# Sets EXEMPT_REASON and records the hit. NOT called through a command
# substitution: a subshell would swallow the USED_EXEMPTIONS append and make
# every exemption look stale.
# ---------------------------------------------------------------------------
declare -a USED_EXEMPTIONS=()
EXEMPT_REASON=""

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
  # `render` is never exemptible — see the header.
  if [ "$check" != "render" ] && exempt "$env" "$check"; then
    printf '  %s[WARN]%s %s: %s — exempt: %s\n' "$YELLOW" "$NC" "$check" "$msg" "$EXEMPT_REASON"
    warn_count=$((warn_count + 1))
  else
    printf '  %s[FAIL]%s %s: %s\n' "$RED" "$NC" "$check" "$msg"
    fail_count=$((fail_count + 1))
  fi
}

# ---------------------------------------------------------------------------
# check_env <env> [values-override] [version-override]
# ---------------------------------------------------------------------------
check_env() {
  local env="$1"
  local values="${2:-${REPO_ROOT}/envs/${env}/values.yaml}"
  local version="${3:-}"
  local expectations store tools tgz rendered violations

  expectations="$(env_expectations "$env")" || { fail_count=$((fail_count + 1)); return; }
  read -r store dispatch <<<"$expectations"

  if [ -z "$version" ]; then
    version="$(env_chart_version "$env")" || { fail_count=$((fail_count + 1)); return; }
  fi
  tgz="$(fetch_chart "$version")"
  rendered="${WORKDIR}/${env}-render.yaml"

  printf '\n%s=== %s (chart %s, store=%s, dispatch=%s) ===%s\n' \
    "$GREEN" "$env" "$version" "$store" "$dispatch" "$NC"

  if ! helm template gibson "$tgz" -n gibson -f "$values" >"$rendered" 2>"${WORKDIR}/${env}.err"; then
    report "$env" "render" "the pinned chart does not render against this overlay: $(tail -1 "${WORKDIR}/${env}.err")"
    return
  fi

  if ! violations="$(contract_facts "$rendered" "$store" "$dispatch" 2>"${WORKDIR}/${env}.facts.err")"; then
    report "$env" "render" "could not evaluate the render: $(tail -1 "${WORKDIR}/${env}.facts.err")"
    return
  fi
  sed 's/^/  /' "${WORKDIR}/${env}.facts.err" | grep '^  workloads=' || true

  if [ -z "$violations" ]; then
    printf '  %s[PASS]%s overlay matches the %s values contract\n' "$GREEN" "$NC" "$version"
    return
  fi
  while IFS=$'\t' read -r check msg; do
    [ -n "$check" ] || continue
    report "$env" "$check" "$msg"
  done <<<"$violations"
}

# ---------------------------------------------------------------------------
# selftest — every assertion must be able to fail. Two layers:
#   1. Synthetic fixtures through contract_facts: one mutant per invariant,
#      plus a clean fixture that must pass. Fast, no network.
#   2. One full-pipeline mutation: staging's overlay with its FGA URLs flipped
#      back to http:// rendered against staging's real pinned chart — the
#      exact gitops#490 incident — must go red end to end.
# A guard that has never been observed failing is not a guard.
# ---------------------------------------------------------------------------
selftest() {
  local rc=0 pass=0
  ok()  { printf '  %s[PASS]%s %s\n' "$GREEN" "$NC" "$1"; pass=$((pass + 1)); }
  bad() { printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$1"; rc=1; }

  local fx="${WORKDIR}/fixture.yaml"
  base_fixture() {
    cat >"$fx" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gibson
spec:
  template:
    spec:
      containers:
        - name: daemon
          image: ghcr.io/zeroroot-ai/gibson:v1.0.0@sha256:aaaa
          env:
            - name: FGA_URL
              value: "https://gibson-openfga:8080"
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gibson-openfga-http-tls
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: gibson-secrets
spec:
  provider:
    vault:
      server: http://openbao.gibson.svc:8200
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: gibson-gibson-workloads-config
data:
  gibson.yaml: |
    sandbox:
      enabled: true
EOF
  }
  expect_violation() { # expect_violation <desc> <check> <store> [dispatch]
    local desc="$1" check="$2" store="$3" dispatch="${4:-require}" out
    out="$(contract_facts "$fx" "$store" "$dispatch" 2>/dev/null || true)"
    if grep -q "^${check}	" <<<"$out"; then
      ok "$desc"
    else
      bad "$desc — expected a ${check} violation, got: ${out:-<none>}"
    fi
  }

  # Clean fixture passes.
  base_fixture
  if [ -z "$(contract_facts "$fx" aws require 2>/dev/null)" ]; then
    ok 'clean fixture passes every invariant'
  else
    bad 'clean fixture tripped an invariant'
  fi

  # eso-store: gibson-secrets backed by anything but OpenBao. Every
  # ExternalSecret in the chart names this store, so a wrongly-backed one
  # degrades all of them (gitops#486).
  base_fixture
  sed -i 's/    vault:/    kubernetes:/' "$fx"
  expect_violation 'a gibson-secrets store that is not vault-backed is rejected' eso-store aws

  # eso-store: no gibson-secrets store at all — the shape the staging overlay
  # rendered when the dead backend keys came out ahead of the pin move
  # (gitops#566, deploy#1746).
  base_fixture
  sed -i '/name: gibson-secrets/,+4d' "$fx"
  expect_violation 'no gibson-secrets store at all is rejected' eso-store aws

  # eso-store: an aws-provider store anywhere is the DELETED backend coming
  # back (ADR-0083, deploy#1733), on any env.
  base_fixture
  sed -i 's/    vault:/    aws:/' "$fx"
  expect_violation 'an aws-provider store is rejected on an aws env' eso-store aws
  base_fixture
  sed -i 's/    vault:/    aws:/' "$fx"
  expect_violation 'an aws-provider store is rejected on a kind env' eso-store kind

  # fga-scheme: TLS listener + an http consumer.
  base_fixture
  sed -i 's|https://gibson-openfga|http://gibson-openfga|' "$fx"
  expect_violation 'http:// dial against a TLS FGA listener is rejected' fga-scheme aws

  # fga-scheme: plain listener + an https consumer.
  base_fixture
  sed -i '/gibson-openfga-http-tls/d' "$fx"
  expect_violation 'https:// dial against a plain FGA listener is rejected' fga-scheme aws

  # fga-scheme: a URL in a rendered comment line must NOT count as a consumer
  # (helm renders template comments into the output; guards have been fooled
  # by that before).
  base_fixture
  printf '# NOTE: this endpoint was http://gibson-openfga:8080 before deploy#1382\n' >>"$fx"
  if [ -z "$(contract_facts "$fx" aws require 2>/dev/null)" ]; then
    ok 'a gibson-openfga URL in a rendered comment does not trip the scheme check'
  else
    bad 'a rendered comment tripped the scheme check'
  fi

  # images: a workload image without tag or digest.
  base_fixture
  sed -i 's|image: ghcr.io/zeroroot-ai/gibson:v1.0.0@sha256:aaaa|image: ghcr.io/zeroroot-ai/gibson|' "$fx"
  expect_violation 'a container image without tag or digest is rejected' images aws

  # tool-dispatch: an env that must be able to dispatch a tool and cannot.
  base_fixture
  python3 - "$fx" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(s.replace("    sandbox:\n      enabled: true", "    sandbox:\n      enabled: false"))
EOF
  expect_violation 'a require-dispatch env with no sandboxed dispatch path is rejected' tool-dispatch aws require

  # tool-dispatch: the sandbox key absent entirely, not merely false.
  base_fixture
  python3 - "$fx" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(s.replace("    sandbox:\n      enabled: true\n", ""))
EOF
  expect_violation 'a require-dispatch env with no sandbox block at all is rejected' tool-dispatch aws require

  # tool-dispatch: a sandbox on an env classified as having none.
  base_fixture
  expect_violation 'an enabled sandbox on a deny-dispatch env is rejected' tool-dispatch aws deny

  # tool-dispatch: a deny-dispatch env with no sandbox is the intended posture.
  base_fixture
  python3 - "$fx" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(s.replace("    sandbox:\n      enabled: true", "    sandbox:\n      enabled: false"))
EOF
  if contract_facts "$fx" aws deny 2>/dev/null | grep -q '^tool-dispatch	'; then
    bad 'a deny-dispatch env without a sandbox tripped the tool-dispatch check'
  else
    ok 'a deny-dispatch env without a sandbox is accepted'
  fi

  # tool-dispatch: a render with no daemon ConfigMap must fail, not pass
  # vacuously — the sandbox knob lives only there.
  base_fixture
  sed -i '/^apiVersion: v1$/,$d' "$fx"
  expect_violation 'a render with no daemon config is rejected rather than vacuously passing' \
    tool-dispatch aws require

  # Empty render must fail, not pass vacuously.
  : >"$fx"
  expect_violation 'an empty render is rejected rather than vacuously passing' render aws

  # Full pipeline: re-introduce the gitops#490 break in the real staging
  # overlay and require the gate to go red against the real pinned chart.
  local mutant="${WORKDIR}/staging-fga-mutant.yaml"
  sed 's|https://gibson-openfga|http://gibson-openfga|' \
    "${REPO_ROOT}/envs/staging/values.yaml" >"$mutant"
  local before=$fail_count
  check_env staging "$mutant" >"${WORKDIR}/selftest-pipeline.out" 2>&1 || true
  if [ "$fail_count" -gt "$before" ]; then
    ok 'end to end: staging overlay flipped back to http:// FGA goes red against its pinned chart'
    fail_count=$before
    warn_count=0
    USED_EXEMPTIONS=()
  else
    bad 'end to end: the gate did NOT reject the re-introduced gitops#490 break'
    sed 's/^/    | /' "${WORKDIR}/selftest-pipeline.out" >&2
  fi

  # Full pipeline: strip the sandbox back out of the real staging overlay and
  # require the gate to go red against the real pinned chart. This is the
  # gitops#553 failure mode reached by its remaining route: no sandbox means a
  # tool has nowhere to run (ADR-0052) and every tool node fails silently.
  local tmutant="${WORKDIR}/staging-dispatch-mutant.yaml"
  python3 - "${REPO_ROOT}/envs/staging/values.yaml" >"$tmutant" <<'EOF'
import re
import sys
s = open(sys.argv[1]).read()
# Drop the sandbox block: its key line through the last indented line under it.
out = re.sub(r"^    sandbox:\n(?:^ {6}.*\n)+", "", s, flags=re.MULTILINE)
if out == s:
    sys.exit("selftest mutation matched nothing — the staging overlay no longer "
             "carries a 'sandbox:' block where this mutation expects it")
sys.stdout.write(out)
EOF
  before=$fail_count
  check_env staging "$tmutant" >"${WORKDIR}/selftest-dispatch.out" 2>&1 || true
  if [ "$fail_count" -gt "$before" ]; then
    ok 'end to end: staging overlay with the sandbox removed goes red against its pinned chart'
    fail_count=$before
    warn_count=0
    USED_EXEMPTIONS=()
  else
    bad 'end to end: the gate did NOT reject a staging overlay with no sandboxed dispatch path'
    sed 's/^/    | /' "${WORKDIR}/selftest-dispatch.out" >&2
  fi

  printf '\n%s selftest checks passed\n' "$pass"
  return $rc
}

# ---------------------------------------------------------------------------
main() {
  if [ "${1:-}" = "--selftest" ]; then
    printf '%s=== check-render-contract selftest ===%s\n' "$GREEN" "$NC"
    selftest
    exit $?
  fi

  local envs=("$@")
  if [ ${#envs[@]} -eq 0 ]; then
    mapfile -t envs < <(find "${REPO_ROOT}/envs" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
  fi

  printf '%s=== check-render-contract selftest ===%s\n' "$GREEN" "$NC"
  selftest || exit 1

  for env in "${envs[@]}"; do
    [ -f "${REPO_ROOT}/envs/${env}/values.yaml" ] || continue
    check_env "$env"
  done

  # A stale exemption is a failure: the staged cutover it covered has landed,
  # so the line must go. Scoped to the envs actually checked.
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
      local key check_name
      check_name="$(cut -d: -f2 <<<"$line")"
      key="${exempt_env}:${check_name}"
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
    printf '%s[FAIL]%s an env overlay violates its pinned chart'\''s values contract\n' "$RED" "$NC"
    exit 1
  fi
  printf '%s[PASS]%s every env overlay matches its pinned chart'\''s values contract\n' "$GREEN" "$NC"
}

main "$@"
