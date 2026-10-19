#!/usr/bin/env bash
# check-smoke-probes-loud.sh: no probe of the promotion proof sends its error
# to /dev/null (scripts/lib/smoke-probe.sh, THE RULE).
#
# Staging run 38465547479 failed step 6 with "secret/infra/* missing". The
# secrets were there. OpenBao refused the list, the refusal went to /dev/null,
# and the fallback "[]" read as "missing". The same form sat in about thirty
# probes of these files.
#
# lib/cluster-probe.sh is in the list because the drill and kind run it too.
#
# The rule for the files below: no redirect that throws stderr away:
# `2>/dev/null`, `>/dev/null 2>&1`, `&>/dev/null`, `>&/dev/null` or `2>&-`. A
# probe runs through capture (lib/cluster-probe.sh) or keeps its stderr. The
# one exception is the exact form `command -v <tool> >/dev/null 2>&1`, which
# tests that a tool exists and has no error worth reading. Only that form is
# removed from a line before the check, so a second redirect on the same line
# still fails (hosted#727).
#
#   check-smoke-probes-loud.sh             exit 1 on a hidden error
#   check-smoke-probes-loud.sh --selftest  prove it fails on a fixture
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=(
  scripts/smoke-signup.sh
  scripts/lib/smoke-probe.sh
  scripts/lib/cluster-probe.sh
  scripts/prove-bringup.sh
  scripts/prove-promotion.sh
  scripts/bringup-status.sh
)

# judge <root> <file...>: the hidden errors, one per line, as file:line: text.
judge() {
  local root="$1" f
  shift
  for f in "$@"; do
    [ -f "$root/$f" ] || { echo "$f: the file is gone. Update FILES in check-smoke-probes-loud.sh"; continue; }
    # Comment lines are prose, not code. A `command -v` test is the exception.
    # Number the lines, drop comment lines, remove the one exempt form, then
    # look for any redirect that discards stderr in what is left.
    awk '{ printf "%d:%s\n", NR, $0 }' "$root/$f" \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | sed -E 's/command -v [A-Za-z0-9_.-]+ >\/dev\/null 2>&1//g' \
      | grep -E '2>[[:space:]]*/dev/null|>[[:space:]]*/dev/null[[:space:]]+2>&1|&>[[:space:]]*/dev/null|>&[[:space:]]*/dev/null|2>&-' \
      | sed "s|^|$f:|" || true
  done
}

if [ "${1:-}" = "--selftest" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/scripts"
  printf '%s\n' \
    'command -v kubectl >/dev/null 2>&1 || exit 2' \
    '# the old form was 2>/dev/null || echo "[]"' \
    'capture keys bao_kv_list pod tok ns secret/infra' > "$tmp/scripts/good.sh"
  printf '%s\n' \
    "KEYS=\$(bao_kv_list pod tok ns secret/infra 2>/dev/null || echo '[]')" > "$tmp/scripts/bad.sh"
  printf '%s\n' \
    'kubectl get secret x >/dev/null 2>&1 && echo ready' > "$tmp/scripts/bad2.sh"
  printf '%s\n' \
    'command -v kubectl >/dev/null 2>&1 && kubectl get y 2>/dev/null' > "$tmp/scripts/bad3.sh"
  printf '%s\n' 'kubectl get y &>/dev/null || true' > "$tmp/scripts/bad4.sh"
  printf '%s\n' 'kubectl get y 2>&- || true' > "$tmp/scripts/bad5.sh"
  [ -z "$(judge "$tmp" scripts/good.sh)" ] || { echo "GUARD BROKEN: a command -v test or a comment was flagged" >&2; exit 2; }
  [ -n "$(judge "$tmp" scripts/bad.sh)" ] || { echo "GUARD BROKEN: a probe that hides its error and falls back to [] passed" >&2; exit 2; }
  [ -n "$(judge "$tmp" scripts/bad2.sh)" ] || { echo "GUARD BROKEN: a probe that sends stdout and stderr to /dev/null passed" >&2; exit 2; }
  [ -n "$(judge "$tmp" scripts/gone.sh)" ] || { echo "GUARD BROKEN: a file that is gone passed" >&2; exit 2; }
  [ -n "$(judge "$tmp" scripts/bad3.sh)" ] || { echo "GUARD BROKEN: a second redirect on a command -v line passed" >&2; exit 2; }
  [ -n "$(judge "$tmp" scripts/bad4.sh)" ] || { echo "GUARD BROKEN: &>/dev/null passed" >&2; exit 2; }
  [ -n "$(judge "$tmp" scripts/bad5.sh)" ] || { echo "GUARD BROKEN: 2>&- passed" >&2; exit 2; }
  echo "✅ self-test: a hidden error fails, a command -v test and a comment pass, a missing file fails"
  exit 0
fi

out="$(judge "$ROOT" "${FILES[@]}")"
if [ -n "$out" ]; then
  echo "✗ a probe of the promotion proof hides its error. Run it through capture (scripts/lib/smoke-probe.sh):" >&2
  printf '  %s\n' "$out" >&2
  exit 1
fi
echo "✅ no probe of the promotion proof hides its error (${#FILES[@]} files)"
