#!/usr/bin/env bash
# tenant_id retention guard (production-eks-deploy R8.1).
#
# R8.1: the `tenant_id` label MUST flow through every metric and log line, so
# per-tenant metrics stay attributable. Two ways this repo can break it:
#
#   1. a ServiceMonitor/PodMonitor whose metricRelabelings `labelkeep` drops
#      tenant_id (or whose `labeldrop` names it); and
#   2. a grafana-agent config that ships metrics or logs without carrying
#      tenant_id through — whether it relabels wrongly, or does not relabel
#      at all. The original gate only examined configs that already had a
#      relabel chain, so a config forwarding scrapes straight to remote_write
#      with zero tenant_id labeling was exempt from a rule about labeling —
#      precisely backwards (gitops#440).
#
# WHY THIS IS A SCRIPT WITH A SELFTEST
#
# This guard used to be an inline workflow step scanning `apps/`, which
# gitops#379 deleted. Repointing it surfaced something worse than a dead path
# filter: it could not fail under any input. There is not one ServiceMonitor or
# PodMonitor anywhere in the repo, and the single grafana-agent config has no
# relabel chain at all, so both loops iterated zero times and the step printed
# "OK: tenant_id retention preserved" on every run. A guard that reports success
# without examining anything is worse than no guard, because it is read as
# evidence.
#
# So: the checker self-tests against synthetic violations before it scans, and
# it prints how many subjects it actually examined rather than only a verdict.
# Zero subjects is reported as VACUOUS, loudly — it does not fail the run
# (today's tree genuinely has none, and failing would just be breakage), but it
# can no longer be mistaken for a clean bill of health.
#
# Usage:
#   scripts/check-tenant-id-label.sh                  # scan envs/
#   scripts/check-tenant-id-label.sh envs             # scan named dirs
#   scripts/check-tenant-id-label.sh --selftest       # prove it still rejects
#
# Requires: yq, grep.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_DIRS=(envs)

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'

# ---------------------------------------------------------------------------
# river_direct_forwards <block-regex> <sink-regex> — read a (comment-stripped)
# Grafana Agent Flow config on stdin and print DIRECT for every <block-regex>
# block whose forward_to references <sink-regex> directly. Brace-tracked so a
# relabel component legitimately forwarding to the sink is not a false hit.
# ---------------------------------------------------------------------------
river_direct_forwards() {
  # The opener must tolerate component sub-paths: `loki.source.kubernetes
  # "pods" {` opens a loki.source block just as `prometheus.scrape "x" {`
  # opens a scrape block (found by mutation-testing — the first version
  # required whitespace right after the prefix and missed the loki block).
  awk -v open="$1" -v sink="$2" '
    $0 ~ ("^[[:space:]]*" open "[a-zA-Z_.]*[[:space:]]*\"") { inblock = 1; depth = 0; hit = 0 }
    inblock {
      if ($0 ~ ("forward_to.*" sink)) hit = 1
      depth += gsub(/{/, "{") - gsub(/}/, "}")
      if (depth <= 0) { if (hit) print "DIRECT"; inblock = 0 }
    }
  '
}

# ---------------------------------------------------------------------------
# scan <dir>... — emit `VIOLATION <file> <reason>` lines and a trailing
# `SUBJECTS <monitors> <agent-configs>` line. Returns 1 when it found at
# least one violation.
# ---------------------------------------------------------------------------
scan() {
  local violations=0 monitors=0 agents=0 f body ships relabels

  # (1) ServiceMonitor / PodMonitor — a labelkeep that omits tenant_id, or a
  #     labeldrop that names it, strips the label off every scraped series.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    monitors=$((monitors + 1))
    if yq eval '.spec.endpoints[]?.metricRelabelings[]? | select(.action == "labeldrop") | .regex' "$f" 2>/dev/null \
       | grep -qE '(^|[^a-zA-Z_])tenant_id([^a-zA-Z_]|$)'; then
      echo "VIOLATION ${f} labeldrop removes tenant_id"
      violations=$((violations + 1))
      continue
    fi
    if yq eval '.spec.endpoints[]?.metricRelabelings[]? | select(.action == "labelkeep") | .regex' "$f" 2>/dev/null \
       | grep -q . ; then
      if yq eval '.spec.endpoints[]?.metricRelabelings[]? | select(.action == "labelkeep") | .regex' "$f" 2>/dev/null \
         | grep -qv 'tenant_id'; then
        echo "VIOLATION ${f} labelkeep does not retain tenant_id"
        violations=$((violations + 1))
      fi
    fi
  done < <(grep -rEl '^kind:[[:space:]]*(ServiceMonitor|PodMonitor)' "$@" 2>/dev/null || true)

  # (2) grafana-agent configs — any config that ships metrics or logs is a
  #     subject, relabel chain or not. R8.1 is about the label being present
  #     on what ships, and "no relabel chain at all" is the violation this
  #     guard originally exempted (gitops#440). All matching is done on the
  #     comment-stripped body so `tenant_id` in a comment cannot satisfy it.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    body="$(grep -vE '^[[:space:]]*(//|#)' "$f" || true)"
    ships=0 relabels=0
    if grep -qE 'prometheus\.scrape|loki\.source|prometheus\.remote_write|loki\.write|remote_write' <<<"$body"; then
      ships=1
    fi
    if grep -qE 'metric_relabel_configs|relabel_configs|prometheus\.relabel|discovery\.relabel|loki\.relabel|loki\.process' <<<"$body"; then
      relabels=1
    fi
    if [ "$ships" -eq 0 ] && [ "$relabels" -eq 0 ]; then
      continue
    fi
    agents=$((agents + 1))
    if ! grep -q 'tenant_id' <<<"$body"; then
      if [ "$relabels" -eq 1 ]; then
        echo "VIOLATION ${f} grafana-agent relabel chain does not preserve tenant_id"
      else
        echo "VIOLATION ${f} grafana-agent ships metrics/logs with no tenant_id labeling at all"
      fi
      violations=$((violations + 1))
      continue
    fi
    if river_direct_forwards 'prometheus\.scrape' 'prometheus\.remote_write' <<<"$body" | grep -q DIRECT; then
      echo "VIOLATION ${f} prometheus.scrape forwards straight to remote_write, bypassing tenant_id relabeling"
      violations=$((violations + 1))
    fi
    if river_direct_forwards 'loki\.source' 'loki\.write' <<<"$body" | grep -q DIRECT; then
      echo "VIOLATION ${f} loki.source forwards straight to loki.write, bypassing tenant_id relabeling"
      violations=$((violations + 1))
    fi
  done < <(grep -rl 'grafana[-_]agent' "$@" 2>/dev/null || true)

  echo "SUBJECTS ${monitors} ${agents}"
  [ "$violations" -eq 0 ]
}

# ---------------------------------------------------------------------------
# selftest — synthesise each violation and assert rejection, and synthesise the
# compliant twin of each and assert acceptance. Without the compliant half a
# checker that rejects everything would look healthy.
# ---------------------------------------------------------------------------
selftest() {
  printf '%s=== selftest ===%s\n' "$GREEN" "$NC"
  local tmp rc=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $tmp now, not at trap time
  trap "rm -rf '$tmp'" RETURN

  mkdir -p "$tmp/bad" "$tmp/good" "$tmp/empty"

  cat >"$tmp/bad/servicemonitor.yaml" <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: bad
spec:
  endpoints:
    - port: metrics
      metricRelabelings:
        - action: labelkeep
          regex: (job|instance)
EOF
  cat >"$tmp/bad/agent.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-agent-config
data:
  config.river: |
    prometheus.relabel "strip" {
      rule { action = "labeldrop" regex = "pod" }
    }
EOF
  # The exact shape gitops#440 found live: scrapes and logs forwarded straight
  # to the sinks, zero relabel rules, tenant_id mentioned only in a comment.
  # The old selector exempted this file entirely.
  cat >"$tmp/bad/agent-direct.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-agent-config
data:
  config.river: |
    // tenant_id is attached upstream (it is not — this comment must not count)
    prometheus.scrape "daemon" {
      targets    = [{ __address__ = "gibson:9090", job = "gibson-daemon" }]
      forward_to = [prometheus.remote_write.cloud.receiver]
    }
    loki.source.kubernetes "pods" {
      targets    = discovery.kubernetes.pods.targets
      forward_to = [loki.write.cloud.receiver]
    }
EOF
  # tenant_id present on one path must not excuse a bypass on another: these
  # two each have a compliant half, plus one block forwarding straight to its
  # sink. They exercise both structural branches past the file-level grep.
  cat >"$tmp/bad/agent-scrape-bypass.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-agent-config
data:
  config.river: |
    prometheus.scrape "daemon" {
      targets    = [{ __address__ = "gibson:9090", job = "gibson-daemon" }]
      forward_to = [prometheus.remote_write.cloud.receiver]
    }
    loki.source.kubernetes "pods" {
      targets    = discovery.relabel.pods.output
      forward_to = [loki.relabel.ensure_tenant.receiver]
    }
    loki.relabel "ensure_tenant" {
      forward_to = [loki.write.cloud.receiver]
      rule { source_labels = ["tenant_id"] regex = "" target_label = "tenant_id" replacement = "_platform" }
    }
EOF
  cat >"$tmp/bad/agent-loki-bypass.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-agent-config
data:
  config.river: |
    prometheus.scrape "daemon" {
      targets    = [{ __address__ = "gibson:9090", job = "gibson-daemon" }]
      forward_to = [prometheus.relabel.ensure_tenant.receiver]
    }
    prometheus.relabel "ensure_tenant" {
      forward_to = [prometheus.remote_write.cloud.receiver]
      rule { source_labels = ["tenant_id"] regex = "" target_label = "tenant_id" replacement = "_platform" }
    }
    loki.source.kubernetes "pods" {
      targets    = discovery.kubernetes.pods.targets
      forward_to = [loki.write.cloud.receiver]
    }
EOF

  cat >"$tmp/good/servicemonitor.yaml" <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: good
spec:
  endpoints:
    - port: metrics
      metricRelabelings:
        - action: labelkeep
          regex: (job|instance|tenant_id)
EOF
  # The compliant twin of agent-direct.yaml: every scrape routes through a
  # relabel component that carries tenant_id, and only the relabel components
  # forward to the sinks. Also proves the brace-tracking does not false-hit
  # the relabel components' own legitimate forward_to = remote_write.
  cat >"$tmp/good/agent.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-agent-config
data:
  config.river: |
    prometheus.scrape "daemon" {
      targets    = [{ __address__ = "gibson:9090", job = "gibson-daemon" }]
      forward_to = [prometheus.relabel.ensure_tenant.receiver]
    }
    prometheus.relabel "ensure_tenant" {
      forward_to = [prometheus.remote_write.cloud.receiver]
      rule {
        action        = "replace"
        source_labels = ["tenant_id"]
        regex         = ""
        target_label  = "tenant_id"
        replacement   = "_platform"
      }
    }
    loki.source.kubernetes "pods" {
      targets    = discovery.relabel.pods.output
      forward_to = [loki.relabel.ensure_tenant.receiver]
    }
    loki.relabel "ensure_tenant" {
      forward_to = [loki.write.cloud.receiver]
      rule {
        source_labels = ["tenant_id"]
        regex         = ""
        target_label  = "tenant_id"
        replacement   = "_platform"
      }
    }
EOF

  local out
  # (1) all three violations must be caught, and each must be named.
  if out="$(scan "$tmp/bad")"; then
    printf '  %s[FAIL]%s selftest 1: violations were NOT rejected\n' "$RED" "$NC"
    sed 's/^/    | /' <<<"$out" >&2
    rc=1
  elif ! grep -q 'servicemonitor.yaml' <<<"$out" \
    || ! grep -q 'bad/agent.yaml' <<<"$out" \
    || ! grep -q 'agent-direct.yaml' <<<"$out" \
    || ! grep -q 'agent-scrape-bypass.yaml' <<<"$out" \
    || ! grep -q 'agent-loki-bypass.yaml' <<<"$out"; then
    printf '  %s[FAIL]%s selftest 1: not every violation class was caught\n' "$RED" "$NC"
    sed 's/^/    | /' <<<"$out" >&2
    rc=1
  else
    printf '  %s[PASS]%s selftest 1: a labelkeep dropping tenant_id, a relabel chain without it, and a config that ships with no labeling at all are all rejected\n' "$GREEN" "$NC"
  fi

  # (2) the compliant twins must pass — a checker that rejects everything is
  #     not a working checker.
  if out="$(scan "$tmp/good")"; then
    printf '  %s[PASS]%s selftest 2: the compliant twins of both are accepted\n' "$GREEN" "$NC"
  else
    printf '  %s[FAIL]%s selftest 2: compliant input was rejected\n' "$RED" "$NC"
    sed 's/^/    | /' <<<"$out" >&2
    rc=1
  fi

  # (3) an empty tree must report zero subjects, not silent success.
  out="$(scan "$tmp/empty" || true)"
  if grep -q '^SUBJECTS 0 0$' <<<"$out"; then
    printf '  %s[PASS]%s selftest 3: an empty tree reports 0 subjects rather than a clean bill of health\n' "$GREEN" "$NC"
  else
    printf '  %s[FAIL]%s selftest 3: empty tree did not report its subject count\n' "$RED" "$NC"
    sed 's/^/    | /' <<<"$out" >&2
    rc=1
  fi

  return $rc
}

# ---------------------------------------------------------------------------
main() {
  if [ "${1:-}" = "--selftest" ]; then
    selftest
    exit $?
  fi

  cd "$REPO_ROOT"

  local dirs=("$@")
  [ ${#dirs[@]} -eq 0 ] && dirs=("${DEFAULT_DIRS[@]}")

  local present=()
  for d in "${dirs[@]}"; do
    [ -d "$d" ] && present+=("$d")
  done
  if [ ${#present[@]} -eq 0 ]; then
    printf '%s[FAIL]%s none of the requested scan directories exist: %s\n' "$RED" "$NC" "${dirs[*]}"
    exit 2
  fi

  selftest || exit 1

  printf '\n%s=== scan (%s) ===%s\n' "$GREEN" "${present[*]}" "$NC"
  local out rc=0
  out="$(scan "${present[@]}")" || rc=1

  local subjects monitors agents
  subjects="$(grep '^SUBJECTS ' <<<"$out")"
  monitors="$(awk '{print $2}' <<<"$subjects")"
  agents="$(awk '{print $3}' <<<"$subjects")"

  # Process substitution, not a pipe: `grep | while read` returns 1 when there
  # is nothing to read, which under `set -e` aborted the whole script on the
  # no-violations path — the guard could only complete when it had something to
  # complain about.
  while read -r _ file reason; do
    [ -n "${file:-}" ] || continue
    printf '  %s[FAIL]%s %s — %s\n' "$RED" "$NC" "$file" "$reason"
  done < <(grep '^VIOLATION ' <<<"$out" || true)

  printf '  examined %s ServiceMonitor/PodMonitor and %s grafana-agent config(s)\n' \
    "$monitors" "$agents"

  if [ "$rc" -ne 0 ]; then
    printf '%s[FAIL]%s tenant_id MUST flow through every metric and log line (R8.1)\n' "$RED" "$NC"
    exit 1
  fi

  if [ "$monitors" -eq 0 ] && [ "$agents" -eq 0 ]; then
    # Not a failure — the tree genuinely has no subjects — but say so plainly.
    # The old inline version printed "OK: tenant_id retention preserved" in
    # exactly this state, which read as a pass on work never done.
    printf '%s[VACUOUS]%s nothing to check: no ServiceMonitor/PodMonitor and no grafana-agent config that ships or relabels in %s.\n' \
      "$YELLOW" "$NC" "${present[*]}"
    printf '           The selftest above proves the checker still rejects every violation class.\n'
    exit 0
  fi

  printf '%s[PASS]%s tenant_id retention preserved across every subject examined\n' "$GREEN" "$NC"
}

main "$@"
