#!/usr/bin/env bash
# PodDisruptionBudget drainability guard over the env overlays (gitops#381).
#
# WHY THIS EXISTS AND WHY IT RENDERS
#
# A PodDisruptionBudget whose budget permits zero voluntary evictions does not
# protect availability — it removes the ability to drain the node the pod is
# on. The eviction API refuses the pod forever, so `kubectl drain`, a managed
# nodegroup roll, and Karpenter consolidation all hang on it. The failure is
# silent at apply time and only shows up during a node replacement, i.e. the
# worst possible moment.
#
# prod and staging both carried exactly that: `envoy.podDisruptionBudget.
# enabled: true` over `envoy.replicas: 1`, rendering `minAvailable: 1` against
# a 1-replica Deployment. The chart's own templates already omit the PDB at one
# replica for this reason ("a 1-replica PDB blocks node drains") — the overlays
# were overriding that safety by hand.
#
# Grepping the overlay cannot see this, for two independent reasons:
#   1. the replica count and the budget can come from different places — an
#      overlay, a chart default, or a subchart the overlay never mentions
#      (gibson-redis-master's PDB is a subchart's, named nowhere in envs/); and
#   2. whether `enabled: true` even produces a PDB depends on the chartVersion
#      the env is pinned to, which is the same class of trap gitops#359 was.
# So this renders each env against ITS OWN pinned chartVersion, exactly as
# scripts/check-profile-coherence.sh does, and reads the rendered objects.
#
# THE INVARIANT
#
#   Every rendered PodDisruptionBudget must permit at least one voluntary
#   eviction against the workload it selects.
#
#     minAvailable: N      -> allowed = replicas - N              (must be > 0)
#     minAvailable: "P%"   -> allowed = replicas - ceil(replicas*P/100)
#     maxUnavailable: N    -> allowed = N                         (must be > 0)
#     maxUnavailable: "P%" -> allowed = floor(replicas*P/100)
#
#   (ceil for minAvailable, floor for maxUnavailable — that is how the
#   disruption controller rounds, and rounding is where 1-replica percentages
#   turn into zero.)
#
# A PDB selecting a DaemonSet is reported and skipped: `kubectl drain` passes
# --ignore-daemonsets, so those pods are not evicted through the budget.
#
# A PDB whose selector matches no rendered workload is a FAILURE, not a pass.
# The budget is real in the cluster whatever this script can resolve, and an
# unresolvable one means the render changed shape in a way this guard no
# longer understands — which must be looked at, not assumed benign.
#
# Usage:
#   scripts/check-pdb-drainability.sh              # every env under envs/
#   scripts/check-pdb-drainability.sh staging prod  # named envs
#   scripts/check-pdb-drainability.sh --selftest   # prove the checker still
#                                                  # rejects a known-bad input
#
# Requires: helm, python3, and a ghcr login able to pull
# oci://ghcr.io/zeroroot-ai/charts/gibson.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_REPO="${CHART_REPO:-oci://ghcr.io/zeroroot-ai/charts/gibson}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

fail_count=0

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
# pdb_verdicts <rendered.yaml> — emit one `STATUS<TAB>message` line per
# rendered PodDisruptionBudget. Exits 3 if the render yielded nothing usable.
# ---------------------------------------------------------------------------
pdb_verdicts() {
  python3 - "$1" <<'PY'
import math
import re
import sys

import yaml


class Loader(yaml.SafeLoader):
    """SafeLoader that survives a rendered platform.

    Same problem scripts/check-profile-coherence.sh hit: a chart this size
    embeds third-party config (Grafana dashboards, Prometheus rules) carrying
    tags SafeLoader refuses, and one of them aborting the stream would leave
    the render looking like it contained no PodDisruptionBudgets at all — a
    silent PASS, which is the exact failure mode this guard exists to avoid.
    """


Loader.add_constructor(
    "tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node)
)
Loader.add_multi_constructor(
    "", lambda loader, suffix, node: loader.construct_scalar(node)
    if isinstance(node, yaml.ScalarNode)
    else None
)

WORKLOAD_KINDS = ("Deployment", "StatefulSet", "DaemonSet")

pdbs = []
workloads = []
docs_seen = 0

with open(sys.argv[1]) as fh:
    raw = fh.read()

# Parse per document so one unparseable manifest cannot take the rest with it.
for chunk in re.split(r"^---\s*$", raw, flags=re.MULTILINE):
    if not chunk.strip():
        continue
    try:
        doc = yaml.load(chunk, Loader=Loader)
    except yaml.YAMLError as exc:
        print(f"unparseable manifest skipped: {str(exc).splitlines()[0]}", file=sys.stderr)
        continue
    if not isinstance(doc, dict) or "kind" not in doc:
        continue
    docs_seen += 1
    kind = doc.get("kind")
    if kind == "PodDisruptionBudget":
        pdbs.append(doc)
    elif kind in WORKLOAD_KINDS:
        workloads.append(doc)

# An empty or unparseable render must not read as "no PDBs, therefore fine".
# That state is indistinguishable from a clean platform and would turn this
# guard into one that cannot fail. Refuse it instead.
if docs_seen == 0:
    print("no Kubernetes objects parsed from the render", file=sys.stderr)
    sys.exit(3)
if not workloads:
    print("no Deployment/StatefulSet/DaemonSet parsed from the render", file=sys.stderr)
    sys.exit(3)


def pod_labels(workload):
    template = (workload.get("spec") or {}).get("template") or {}
    return (template.get("metadata") or {}).get("labels") or {}


def selected(match_labels):
    return [w for w in workloads
            if all(pod_labels(w).get(k) == v for k, v in match_labels.items())]


def as_percent(value):
    """Return the integer percentage, or None when the value is a plain count."""
    if isinstance(value, str) and value.endswith("%"):
        return int(value[:-1])
    return None


def allowed_evictions(spec, replicas):
    """Voluntary evictions the budget permits at this replica count.

    Returns (allowed, rendered-as) or (None, reason) when it cannot be decided.
    """
    if "maxUnavailable" in spec and spec["maxUnavailable"] is not None:
        raw = spec["maxUnavailable"]
        pct = as_percent(raw)
        if pct is None:
            return int(raw), f"maxUnavailable={raw}"
        # The disruption controller rounds maxUnavailable DOWN.
        return math.floor(replicas * pct / 100), f"maxUnavailable={raw}"
    if "minAvailable" in spec and spec["minAvailable"] is not None:
        raw = spec["minAvailable"]
        pct = as_percent(raw)
        if pct is None:
            return replicas - int(raw), f"minAvailable={raw}"
        # ...and rounds minAvailable UP.
        return replicas - math.ceil(replicas * pct / 100), f"minAvailable={raw}"
    # policy/v1 defaults an unset budget to minAvailable: 0 — every eviction
    # permitted, nothing obstructed.
    return replicas, "no budget set"


if not pdbs:
    print("INFO\tno PodDisruptionBudget rendered")

for pdb in sorted(pdbs, key=lambda p: (p.get("metadata") or {}).get("name", "")):
    name = (pdb.get("metadata") or {}).get("name", "?")
    spec = pdb.get("spec") or {}
    match_labels = (spec.get("selector") or {}).get("matchLabels") or {}
    if not match_labels:
        print(f"FAIL\t{name}: PodDisruptionBudget has no selector.matchLabels — "
              f"it cannot be reasoned about, and a selector-less budget can "
              f"capture unrelated pods")
        continue
    targets = selected(match_labels)
    if not targets:
        print(f"FAIL\t{name}: selector {match_labels} matches no rendered "
              f"Deployment/StatefulSet/DaemonSet — the budget still applies in "
              f"the cluster but its replica count cannot be checked here")
        continue
    for target in targets:
        tkind = target["kind"]
        tname = (target.get("metadata") or {}).get("name", "?")
        if tkind == "DaemonSet":
            print(f"SKIP\t{name}: targets DaemonSet {tname} — drain passes "
                  f"--ignore-daemonsets, so the budget does not gate eviction")
            continue
        replicas = (target.get("spec") or {}).get("replicas")
        replicas = 1 if replicas is None else int(replicas)
        allowed, rendered_as = allowed_evictions(spec, replicas)
        if allowed is None:
            print(f"FAIL\t{name}: cannot resolve the budget ({rendered_as})")
        elif allowed <= 0:
            print(f"FAIL\t{name}: {rendered_as} over {tkind} {tname} with "
                  f"replicas={replicas} permits {allowed} voluntary evictions — "
                  f"the eviction API refuses this pod unconditionally and every "
                  f"node drain hangs on it. Either raise replicas, or drop the "
                  f"podDisruptionBudget override and let the chart re-enable it "
                  f"when replicas > 1")
        else:
            print(f"OK\t{name}: {rendered_as} over {tkind} {tname} "
                  f"replicas={replicas} permits {allowed} eviction(s)")
PY
}

# ---------------------------------------------------------------------------
# check_env <env> [values-override]
# ---------------------------------------------------------------------------
check_env() {
  local env="$1"
  local values="${2:-${REPO_ROOT}/envs/${env}/values.yaml}"
  local version tgz rendered verdicts

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

  if ! verdicts="$(pdb_verdicts "$rendered" 2>"${WORKDIR}/${env}.parse.err")"; then
    printf '  %s[FAIL]%s could not read PodDisruptionBudgets from the render: %s\n' \
      "$RED" "$NC" "$(tail -1 "${WORKDIR}/${env}.parse.err")"
    fail_count=$((fail_count + 1))
    return
  fi

  while IFS=$'\t' read -r status msg; do
    [ -z "$status" ] && continue
    case "$status" in
      OK)   printf '  %s[PASS]%s %s\n' "$GREEN" "$NC" "$msg" ;;
      SKIP) printf '  %s[SKIP]%s %s\n' "$YELLOW" "$NC" "$msg" ;;
      INFO) printf '  %s[INFO]%s %s\n' "$YELLOW" "$NC" "$msg" ;;
      FAIL) printf '  %s[FAIL]%s %s\n' "$RED" "$NC" "$msg"
            fail_count=$((fail_count + 1)) ;;
      *)    printf '  %s[FAIL]%s unrecognised verdict %q\n' "$RED" "$NC" "$status"
            fail_count=$((fail_count + 1)) ;;
    esac
  done <<<"$verdicts"
}

# ---------------------------------------------------------------------------
# selftest — two mutations, because the two ways this guard could rot are
# different and only one of them is about PDB arithmetic:
#
#   1. reintroduce gitops#381 itself — force the Envoy PDB on at replicas: 1 —
#      and assert the checker rejects it. Guards the arithmetic.
#   2. hand the parser an EMPTY render and assert it errors rather than
#      reporting "no PDBs, all good". Guards against the whole guard quietly
#      becoming a no-op the day a render breaks or a parse silently yields
#      nothing — the way a check stops being able to fail at all.
# ---------------------------------------------------------------------------
selftest() {
  printf '%s=== selftest ===%s\n' "$GREEN" "$NC"
  local rc=0

  # (1) arithmetic: a forced PDB over a 1-replica Envoy must be rejected.
  local base="${REPO_ROOT}/envs/staging/values.yaml"
  local mutant="${WORKDIR}/forced-pdb.yaml"
  cp "$base" "$mutant"
  cat >>"$mutant" <<'EOF'

# selftest mutation (gitops#381): force the Envoy PDB on while replicas stays
# at 1. This is the exact combination the fix removed; the guard must reject it.
gibson-workloads:
  envoy:
    replicas: 1
    podDisruptionBudget:
      enabled: true
EOF

  local before=$fail_count
  check_env staging "$mutant" >"${WORKDIR}/selftest-pdb.out" 2>&1 || true
  if [ "$fail_count" -gt "$before" ]; then
    printf '  %s[PASS]%s selftest 1: a PDB forced on over a 1-replica Envoy is rejected\n' "$GREEN" "$NC"
    fail_count=$before
  else
    printf '  %s[FAIL]%s selftest 1: the checker did NOT reject a 1-replica PDB\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/selftest-pdb.out" >&2
    rc=1
  fi

  # (2) empty input: the parser must error, not report a clean bill of health.
  : >"${WORKDIR}/empty.yaml"
  if pdb_verdicts "${WORKDIR}/empty.yaml" >"${WORKDIR}/selftest-empty.out" 2>&1; then
    printf '  %s[FAIL]%s selftest 2: an EMPTY render was accepted — the guard would pass on a broken render\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/selftest-empty.out" >&2
    rc=1
  else
    printf '  %s[PASS]%s selftest 2: an empty render is rejected, not read as "no PDBs, all good"\n' "$GREEN" "$NC"
  fi

  # (3) workload-free input: PDBs present but nothing to size them against.
  cat >"${WORKDIR}/pdb-only.yaml" <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: orphan
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: nothing
EOF
  if pdb_verdicts "${WORKDIR}/pdb-only.yaml" >"${WORKDIR}/selftest-orphan.out" 2>&1; then
    printf '  %s[FAIL]%s selftest 3: a render with no workloads was accepted\n' "$RED" "$NC"
    sed 's/^/    | /' "${WORKDIR}/selftest-orphan.out" >&2
    rc=1
  else
    printf '  %s[PASS]%s selftest 3: a render with PDBs but no workloads is rejected\n' "$GREEN" "$NC"
  fi

  return $rc
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

  printf '\n%s=== summary ===%s\n' "$GREEN" "$NC"
  printf '  failures: %s\n' "$fail_count"
  if [ "$fail_count" -gt 0 ]; then
    printf '%s[FAIL]%s a PodDisruptionBudget permits zero voluntary evictions — node drains will hang\n' "$RED" "$NC"
    exit 1
  fi
  printf '%s[PASS]%s every rendered PodDisruptionBudget permits at least one voluntary eviction\n' "$GREEN" "$NC"
}

main "$@"
