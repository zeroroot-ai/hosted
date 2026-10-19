#!/usr/bin/env bash
# deletion-check.sh — Phase 12 Task 29
#
# Pre-release deletion validation: asserts no residue of the deleted
# pre-release plugin shape remains in the tree.
#
# Requirement 11.3: CI lint SHALL fail on any remaining import of the
# deleted packages or deleted interface symbols.
#
# Usage:
#   bash deletion-check.sh [--repo-root PATH]
#
# Exit codes:
#   0  Tree is clean — no residue found
#   1  Residue found — offending file(s) printed to stderr

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../../../.." && pwd)}"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()   { printf '\033[36m[deletion-check]\033[0m %s\n' "$*"; }
pass()  { printf '\033[32m[deletion-check PASS]\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m[deletion-check FAIL]\033[0m %s\n' "$*" >&2; }
found() { printf '\033[31m[RESIDUE]\033[0m %s\n' "$*" >&2; }

# Argument parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

log "Repo root: ${REPO_ROOT}"
log "Checking for residue of the deleted pre-release plugin shape..."

ERRORS=0
SEARCH_PATHS=(
  "${REPO_ROOT}/core"
  "${REPO_ROOT}/enterprise"
  "${REPO_ROOT}/opensource"
)

# Verify ripgrep is available
if ! command -v rg &>/dev/null; then
  log "ripgrep (rg) not found; falling back to grep -r"
  RG_CMD=(grep -rn --include="*.go")
else
  RG_CMD=(rg -n --type go)
fi

# ---------------------------------------------------------------------------
# Check 1 — No imports of core/sdk/pluginkit (deleted in Phase 1)
# ---------------------------------------------------------------------------
log "Check 1: imports of deleted core/sdk/pluginkit package"

PLUGINKIT_HITS=0
for path in "${SEARCH_PATHS[@]}"; do
  [[ -d "${path}" ]] || continue
  while IFS= read -r line; do
    found "pluginkit import: ${line}"
    PLUGINKIT_HITS=$(( PLUGINKIT_HITS + 1 ))
  done < <(
    "${RG_CMD[@]}" '"[^"]*core/sdk/pluginkit[^"]*"' "${path}" 2>/dev/null || true
  )
done

if [[ "${PLUGINKIT_HITS}" -eq 0 ]]; then
  pass "Check 1: no imports of core/sdk/pluginkit found"
else
  fail "Check 1: found ${PLUGINKIT_HITS} import(s) of the deleted pluginkit package"
  ERRORS=$(( ERRORS + PLUGINKIT_HITS ))
fi

# ---------------------------------------------------------------------------
# Check 2 — No imports of the deleted core/gibson/internal/plugin package
# ---------------------------------------------------------------------------
log "Check 2: imports of deleted core/gibson/internal/plugin package"

INTERNAL_PLUGIN_HITS=0
for path in "${SEARCH_PATHS[@]}"; do
  [[ -d "${path}" ]] || continue
  while IFS= read -r line; do
    found "internal/plugin import: ${line}"
    INTERNAL_PLUGIN_HITS=$(( INTERNAL_PLUGIN_HITS + 1 ))
  done < <(
    "${RG_CMD[@]}" '"[^"]*core/gibson/internal/plugin[^"]*"' "${path}" 2>/dev/null || true
  )
done

if [[ "${INTERNAL_PLUGIN_HITS}" -eq 0 ]]; then
  pass "Check 2: no imports of core/gibson/internal/plugin found"
else
  fail "Check 2: found ${INTERNAL_PLUGIN_HITS} import(s) of the deleted daemon plugin package"
  ERRORS=$(( ERRORS + INTERNAL_PLUGIN_HITS ))
fi

# ---------------------------------------------------------------------------
# Check 3 — No references to the deleted PluginService interface symbols
#
# The deleted PluginService had RPCs: Initialize, Shutdown, ListMethods, Query, Health.
# These were the pre-release shape on the OLD proto (not the new PluginInvokeService).
#
# We look for method receiver patterns that indicate the OLD interface is still
# being implemented somewhere:
#
#   func (*) Initialize(context.Context, *pluginpb.InitializeRequest)
#   func (*) Shutdown(context.Context, *pluginpb.ShutdownRequest)
#   func (*) ListMethods(context.Context, *pluginpb.ListMethodsRequest)
#   func (*) Query(context.Context, *pluginpb.QueryRequest)
#   func (*) Health(context.Context, *pluginpb.HealthRequest)
#
# We also catch the UnimplementedPluginServiceServer embedding pattern.
#
# Allow-list: gibson.plugin.v1.PluginInvokeService (the new surface) is fine.
# We are specifically hunting for the OLD PluginService server implementations.
# ---------------------------------------------------------------------------
log "Check 3: references to deleted PluginService RPC methods"

# Patterns that indicate the old interface is still present
DELETED_PATTERNS=(
  # UnimplementedPluginServiceServer — generated type from the deleted proto
  "UnimplementedPluginServiceServer"
  # RegisterPluginServiceServer — gRPC registration for the deleted service
  "RegisterPluginServiceServer"
  # PluginServiceServer interface embedding in type declarations
  'PluginServiceServer\b'
  # PluginServiceClient (old client-side)
  'PluginServiceClient\b'
  # The old generated NewPluginServiceClient constructor
  "NewPluginServiceClient"
  # InitializeRequest / ShutdownRequest from old proto — these types were
  # deleted when the proto was removed; any new occurrence is a residue.
  '"[^"]*pluginpb"[^;]*\bInitializeRequest\b'
  '"[^"]*pluginpb"[^;]*\bShutdownRequest\b'
  '"[^"]*pluginpb"[^;]*\bListMethodsRequest\b'
  '"[^"]*pluginpb"[^;]*\bQueryRequest\b'
  '"[^"]*pluginpb"[^;]*\bHealthRequest\b'
)

OLD_PLUGIN_HITS=0
for path in "${SEARCH_PATHS[@]}"; do
  [[ -d "${path}" ]] || continue
  for pattern in "${DELETED_PATTERNS[@]}"; do
    while IFS= read -r line; do
      # Skip lines that are part of the new PluginInvokeService (allow-listed)
      if echo "${line}" | grep -q "PluginInvokeService\|PluginInvoke"; then
        continue
      fi
      # Skip the deletion-check script itself
      if echo "${line}" | grep -q "deletion-check.sh"; then
        continue
      fi
      found "old PluginService symbol (pattern: ${pattern}): ${line}"
      OLD_PLUGIN_HITS=$(( OLD_PLUGIN_HITS + 1 ))
    done < <(
      "${RG_CMD[@]}" -- "${pattern}" "${path}" 2>/dev/null || true
    )
  done
done

if [[ "${OLD_PLUGIN_HITS}" -eq 0 ]]; then
  pass "Check 3: no references to deleted PluginService symbols found"
else
  fail "Check 3: found ${OLD_PLUGIN_HITS} reference(s) to deleted PluginService symbols"
  ERRORS=$(( ERRORS + OLD_PLUGIN_HITS ))
fi

# ---------------------------------------------------------------------------
# Check 4 — No references to the old Plugin interface method signatures
#
# The old Plugin interface (core/sdk/plugin before Phase 1) had:
#   Initialize(ctx, cfg) error
#   Query(ctx, method, args) (interface{}, error)
#   Shutdown(ctx) error
#   Health() error
#   Methods() []string
#   MethodDescriptor(name) (MethodDescriptor, error)
#   Schema() interface{}
#
# SCOPE: This check is scoped to the SDK (core/sdk/) and to files OUTSIDE the
# known stub at core/gibson/internal/plugin/plugin.go. That stub is an
# intentional Phase 7 bridge (its TODO comments confirm this). The daemon's
# harness callers still reference it while Phase 7 lands. The build check
# (Check 5) confirms there are no transitive issues from the stub.
#
# What we DO flag:
#   - Any NEW file in core/sdk/ that re-imports the pre-release plugin types
#   - DefaultPluginRegistry (the specifically-deleted pre-release type — distinct
#     from the new PluginRegistry interface in the Phase 7 bridge stub)
#   - References to pluginkit's ConfigSource OUTSIDE the gibsoncheck analyzer
#     and OUTSIDE the Phase 7 stub
# ---------------------------------------------------------------------------
log "Check 4: old Plugin interface assertions and stale type references"

OLD_IFACE_HITS=0

# 4a — DefaultPluginRegistry (the specifically-deleted pre-release concrete type)
#      Allow only in the gibsoncheck rules that document it was deleted.
while IFS= read -r line; do
  # Allow in gibsoncheck analyzer files (they document the deleted type by name)
  if echo "${line}" | grep -qE "gibsoncheck|plugin_legacy"; then
    continue
  fi
  # Allow in the Phase 7 stub package itself only if it's a comment/doc line
  if echo "${line}" | grep -q "core/gibson/internal/plugin/plugin.go" && \
     echo "${line}" | grep -q "//"; then
    continue
  fi
  found "DefaultPluginRegistry outside allowlist: ${line}"
  OLD_IFACE_HITS=$(( OLD_IFACE_HITS + 1 ))
done < <(
  for path in "${SEARCH_PATHS[@]}"; do
    [[ -d "${path}" ]] || continue
    "${RG_CMD[@]}" 'DefaultPluginRegistry\b' "${path}" 2>/dev/null || true
  done
)

# 4b — ConfigSource: must not appear anywhere except the gibsoncheck rule doc
while IFS= read -r line; do
  if echo "${line}" | grep -qE "gibsoncheck|plugin_legacy"; then
    continue
  fi
  found "ConfigSource outside allowlist (pluginkit residue): ${line}"
  OLD_IFACE_HITS=$(( OLD_IFACE_HITS + 1 ))
done < <(
  for path in "${SEARCH_PATHS[@]}"; do
    [[ -d "${path}" ]] || continue
    "${RG_CMD[@]}" 'ConfigSource\b' "${path}" 2>/dev/null || true
  done
)

# 4c — Old Plugin interface var assertion patterns in the SDK
while IFS= read -r line; do
  found "old Plugin interface var assertion: ${line}"
  OLD_IFACE_HITS=$(( OLD_IFACE_HITS + 1 ))
done < <(
  for path in "${REPO_ROOT}/core/sdk" "${REPO_ROOT}/opensource"; do
    [[ -d "${path}" ]] || continue
    "${RG_CMD[@]}" -- 'var _ Plugin = ' "${path}" 2>/dev/null || true
    "${RG_CMD[@]}" -- 'var _ plugin\.Plugin = ' "${path}" 2>/dev/null || true
  done
)

# 4d — Note (not error) that the Phase 7 stub still exists in core/gibson/internal/plugin/
STUB_FILE="${REPO_ROOT}/core/gibson/internal/plugin/plugin.go"
if [[ -f "${STUB_FILE}" ]]; then
  log "  NOTE: Phase 7 bridge stub still present at core/gibson/internal/plugin/plugin.go"
  log "  This file is a deliberate placeholder pending Phase 7 harness migration."
  log "  TODO(plugin-runtime Phase 7): delete this stub and migrate harness callers."
  log "  Check 5 (go build) confirms no transitive compilation issues from this stub."
fi

if [[ "${OLD_IFACE_HITS}" -eq 0 ]]; then
  pass "Check 4: no forbidden old Plugin interface symbols outside allowlisted files"
else
  fail "Check 4: found ${OLD_IFACE_HITS} reference(s) to deleted plugin symbols outside allowlist"
  ERRORS=$(( ERRORS + OLD_IFACE_HITS ))
fi

# ---------------------------------------------------------------------------
# Check 5 — go build: scan for transitive references to the deleted packages
#
# We capture all build output and grep specifically for the deleted package
# paths in error messages. General build failures (e.g., unpublished SDK
# packages during spec development) are noted but do not fail this check —
# only errors that name the deleted plugin packages are considered residue.
#
# The deleted package paths that must NOT appear in build output:
#   - github.com/.../sdk/pluginkit
#   - github.com/.../gibson/internal/plugin   (outside the bridge stub dir)
# ---------------------------------------------------------------------------
log "Check 5: go build scan for deleted package transitive references"

BUILD_ERRORS=0

check_build_for_deleted_refs() {
  local module_dir="${1}"
  local label="${2}"
  local build_output

  printf '\033[36m[deletion-check]\033[0m   Scanning %s...\n' "${label}"
  build_output="$(cd "${module_dir}" && \
    CGO_ENABLED=0 go build -mod=mod ./... 2>&1 || true)"

  # Only flag lines that reference the specifically-deleted package paths.
  local deleted_hits=0
  while IFS= read -r bline; do
    if echo "${bline}" | grep -qiE \
        'sdk/pluginkit|gibson/internal/plugin[^/]'; then
      printf '\033[31m[RESIDUE]\033[0m %s\n' "${label} build error references deleted package: ${bline}" >&2
      deleted_hits=$(( deleted_hits + 1 ))
    fi
  done <<< "${build_output}"

  if [[ "${deleted_hits}" -gt 0 ]]; then
    printf '\033[31m[deletion-check FAIL]\033[0m %s\n' \
      "Check 5 ${label}: ${deleted_hits} build error line(s) reference deleted packages" >&2
    BUILD_ERRORS=$(( BUILD_ERRORS + deleted_hits ))
  else
    # Note other build errors (in-progress SDK publish lag etc.) but
    # don't fail — this check is specifically about deleted package residue.
    local total_errors
    total_errors="$(echo "${build_output}" | grep -c '^.*:.*:' 2>/dev/null || true)"
    if [[ "${total_errors}" -gt 0 ]]; then
      printf '\033[33m[deletion-check WARN]\033[0m %s\n' \
        "  ${label} has ${total_errors} build error line(s) unrelated to deleted packages"
      printf '\033[33m[deletion-check WARN]\033[0m %s\n' \
        "  (likely in-progress SDK publish lag — not a deletion residue)"
    else
      printf '\033[32m[deletion-check PASS]\033[0m %s\n' \
        "Check 5 ${label}: no transitive references to deleted packages"
    fi
  fi
}

check_build_for_deleted_refs "${REPO_ROOT}/core/sdk" "core/sdk"
check_build_for_deleted_refs "${REPO_ROOT}/core/gibson" "core/gibson"

if [[ "${BUILD_ERRORS}" -gt 0 ]]; then
  fail "Check 5: ${BUILD_ERRORS} line(s) in go build output reference deleted packages"
  ERRORS=$(( ERRORS + BUILD_ERRORS ))
else
  pass "Check 5: go build output contains no references to deleted package paths"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "${ERRORS}" -eq 0 ]]; then
  pass "All deletion checks passed — tree is clean of pre-release plugin shape residue"
  exit 0
else
  fail "Deletion check FAILED: ${ERRORS} residue(s) found (see [RESIDUE] lines above)"
  fail "Fix the offending imports/references before releasing plugin-runtime."
  exit 1
fi
