#!/usr/bin/env bash
# check-keyring-members-exist.sh — nothing writes a keyring member that is gone.
#
# scripts/keyring.sh owns the member list. `keyring.sh set` refuses a name that
# is not on it, by design: the keyring's shape is a contract and a typo must
# not silently invent a member.
#
# The failure mode is the other direction. Delete a member from the list and
# every writer of it becomes a landmine that only goes off on a machine where
# that writer's input happens to exist. LLM_KEYS_JSON was removed when the
# platform LLM credential was deleted — the daemon takes LLM keys from the
# tenant provider resolver, and there is no platform-wide key — and stage 0 for
# kind kept writing it. `make substrate ENV=kind` then died on the FIRST verb
# of a from-nothing bringup:
#
#   keyring: LLM_KEYS_JSON is not an input member; only GHCR_PULL_TOKEN,
#   DNS_ACCESS_KEY, DNS_SECRET_KEY and GITHUB_APP_PRIVATE_KEY may be set
#
# and only on a workstation with ~/.anthropic.tok present, because the writer
# was guarded by "if any of these token files exist". A clean CI runner would
# never have seen it. Measured 2026-09-15.
#
# So: every member name any script hands to `keyring.sh set` or `keyring.sh
# get` must still be on the list.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# KEYRING_SH is a test seam, the way GITOPS_PATH is for the bringup verbs: the
# self-test below points it at a fixture block so the short-read refusal can be
# exercised end to end rather than reasoned about.
KEYRING="${KEYRING_SH:-$HERE/keyring.sh}"
[ -r "$KEYRING" ] || { echo "check-keyring-members-exist: no scripts/keyring.sh" >&2; exit 2; }

# The member list, read from its one definition.
# The member list, read from its one definition.
#
# A PARTIAL READ MUST NOT BECOME A FINDING. This guard was observed failing
# twice on an unchanged tree, naming a different member and a different writer
# each time — BUCKET_ACCESS_KEY via scripts/preflight.sh, then GHCR_PULL_TOKEN
# via bootstrap/kind/substrate/substrate.sh — while 20 standalone runs passed.
# Both members are defined. Each failure was this pipeline returning a SHORT
# list, after which the first writer naming a missing member is accused.
#
# So the count is asserted against the block itself. `members_declared` counts
# the entries between MEMBERS=( and ) by reading the same lines; if the two
# disagree, the read was incomplete and that is the finding — not a writer.
members() {
  sed -n '/^MEMBERS=(/,/^)/p' "$KEYRING" \
    | grep -oE '^\s+[A-Z_]+:' | tr -d ' :' | sort -u
}

# How many entries the block declares, counted independently of members().
members_declared() {
  sed -n '/^MEMBERS=(/,/^)/p' "$KEYRING" \
    | grep -cE '^[[:space:]]+[A-Z_]+:[a-z0-9]+:[0-9]+$'
}

# used <file> — every member name this file hands to keyring.sh, executable
# lines only. A comment naming a member is prose, not a write.
used() {
  grep -vE '^[[:space:]]*#' "$1" \
    | grep -oE 'keyring\.sh[^|;&]*|\$KEYRING"?[^|;&]*|\$\{KEYRING\}[^|;&]*' \
    | grep -oE '\b(set|get)\b[[:space:]]+[^[:space:]]+[[:space:]]+[A-Z_]{3,}' \
    | grep -oE '[A-Z_]{3,}$' | sort -u
}

KNOWN="$(members)"
[ -n "$KNOWN" ] || { echo "check-keyring-members-exist: could not read the member list" >&2; exit 2; }

# The two counts must agree. A short read here produces a confident, wrong
# accusation against whichever writer names the member that went missing.
DECLARED="$(members_declared)"
GOT="$(printf '%s\n' "$KNOWN" | grep -c .)"
if [ "$GOT" != "$DECLARED" ]; then
  echo "check-keyring-members-exist: read ${GOT} member name(s) from ${KEYRING#"$ROOT"/} but its MEMBERS=( ) block declares ${DECLARED}. The read was incomplete, so no writer is judged: re-run. A short read here accuses whichever writer names the member that went missing, which is how this guard twice reported a defined member as undefined." >&2
  exit 2
fi

# --- self-test: a deleted member must be caught ----------------------------
#
# Skipped in the child that the short-read fixture spawns. Without this the
# child runs the self-test too, spawns its own child, and the guard never
# returns — which is what happened the first time this fixture was written.
if [ -z "${KEYRING_SELFTEST_CHILD:-}" ]; then
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/writer.sh" <<'SH'
#!/usr/bin/env bash
"$KEYRING" set "$STATE/keyring.env" DEFINITELY_NOT_A_MEMBER "$value"
SH
if [ -z "$(used "$WORK/writer.sh")" ]; then
  echo "✗ self-test broken: a keyring.sh set of an unknown member must be seen" >&2
  exit 1
fi

# FAILING FIXTURE: a SHORT read must refuse, not accuse a writer.
#
# A copy of keyring.sh with one member hidden from members() but still counted
# by members_declared() is exactly what a truncated pipeline produces. The guard
# must say the read was incomplete and exit 2, never name a writer.
cat > "$WORK/keyring-short.sh" <<'SHORT'
MEMBERS=(
  OPENBAO_SEAL_KEY:b64:32
  BUCKET_ACCESS_KEY:alnum:20
)
SHORT
short_declared="$(sed -n '/^MEMBERS=(/,/^)/p' "$WORK/keyring-short.sh" | grep -cE '^[[:space:]]+[A-Z_]+:[a-z0-9]+:[0-9]+$')"
short_got="$(sed -n '/^MEMBERS=(/,/^)/p' "$WORK/keyring-short.sh" | grep -oE '^\s+[A-Z_]+:' | tr -d ' :' | sort -u | grep -c .)"
if [ "$short_declared" != 2 ] || [ "$short_got" != 2 ]; then
  echo "✗ self-test broken: the two counts must agree on an intact block (declared=${short_declared} got=${short_got})" >&2
  exit 1
fi
# End to end: a block whose name reader and entry counter DISAGREE must make the
# guard refuse with exit 2 and judge no writer. `BROKEN:` has the name shape but
# not the name:kind:size shape, so members() sees three and members_declared()
# sees two — the same asymmetry a truncated pipeline produces.
cat > "$WORK/keyring-mismatch.sh" <<'MISMATCH'
MEMBERS=(
  OPENBAO_SEAL_KEY:b64:32
  BUCKET_ACCESS_KEY:alnum:20
  BROKEN:
)
MISMATCH
set +e
mismatch_out="$(KEYRING_SELFTEST_CHILD=1 KEYRING_SH="$WORK/keyring-mismatch.sh" "$0" 2>&1)"
mismatch_rc=$?
set -e
if [ "$mismatch_rc" != 2 ]; then
  echo "✗ self-test broken: a block whose counts disagree must exit 2, got ${mismatch_rc}" >&2
  exit 1
fi
case "$mismatch_out" in
  *"The read was incomplete"*) ;;
  *) echo "✗ self-test broken: the refusal must say the read was incomplete, got: ${mismatch_out}" >&2; exit 1 ;;
esac
case "$mismatch_out" in
  *"writes keyring member"*) echo "✗ self-test broken: a short read must judge NO writer" >&2; exit 1 ;;
esac
fi  # KEYRING_SELFTEST_CHILD

fail=0
scanned=0
while IFS= read -r f; do
  case "$f" in *"/scripts/keyring.sh") continue ;; esac
  names="$(used "$f")" || true
  [ -n "$names" ] || continue
  scanned=$((scanned + 1))
  for n in $names; do
    if ! printf '%s\n' "$KNOWN" | grep -qx "$n"; then
      printf '✗ %s writes keyring member %s, which scripts/keyring.sh does not define\n' \
        "${f#$ROOT/}" "$n" >&2
      fail=1
    fi
  done
done < <(grep -rl 'keyring\.sh\|\$KEYRING' "$ROOT/scripts" "$ROOT/bootstrap" 2>/dev/null \
         | grep -vE '/(check-keyring-members-exist\.sh|keyring\.sh)$' | sort)

if [ "$fail" = 1 ]; then
  echo "  a member deleted from the list leaves its writers behind, and they fail only where their input exists." >&2
  exit 1
fi

printf '✅ self-test: an unknown member is seen; %d writer(s) name only members scripts/keyring.sh defines (%s)\n' \
  "$scanned" "$(printf '%s' "$KNOWN" | tr '\n' ' ' | sed 's/ $//')"
