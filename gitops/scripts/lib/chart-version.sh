# shellcheck shell=bash
# Shared promotion-pin readers (gitops#448). Sourced, not executed.
#
# The single source of truth for an env's umbrella chart version is the OCI
# source's `targetRevision` in that env's platform Application. The old
# `chartVersion:` marker in envs/<env>/values.yaml was DELETED in gitops#448:
# the promotion wrote it into the $values file, so every promotion commit made
# both the Application spec and the $values ref stale at once, and Argo's
# unordered peer reconciliation (app-of-apps vs the gibson app) raced on every
# promotion — three stalled syncs recovered by hand before the marker was
# removed. Read the version from the Application, never from values.yaml.
#
# Consumers: bump-chart-version.sh, check-profile-coherence.sh,
# check-pdb-drainability.sh, verify-chart-signature.sh, check-prod-promotion.sh,
# check-promotion-isolation.sh, prod-on-green.sh, promote-staging.yml.

# The OCI registry path the umbrella chart is published to (the
# publish-umbrella-chart workflow in zeroroot-ai/charts). Application
# edits/reads are scoped to the source whose repoURL is exactly this.
OCI_REPO="${OCI_REPO:-ghcr.io/zeroroot-ai/charts}"

# The root of the Argo tree, resolved from THIS file's location and not from
# the caller's working directory. The two were the same until ADR-0086, when
# the tree moved under gitops/ in the hosted repo. resolve_app defaulted to
# ".", so from then on bump-chart-version.sh, check-promotion-isolation.sh and
# prod-on-green.sh looked for envs/<env>/ beside the repo root, found nothing,
# and reported "no platform Application" for every env. $REPO_ROOT still wins,
# which is how the selftests point the readers at a fixture directory.
CHART_VERSION_TREE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---------------------------------------------------------------------------
# oci_revision_walk <mode> <file> [<version>]
#
# One state machine, two modes:
#   read   — print the targetRevision of the OCI umbrella source
#   write  — emit the file with that one targetRevision replaced by <version>
#
# <file> may be "-" for stdin (read mode; used on `git show` output).
#
# Either way it exits 3 unless EXACTLY ONE source in the file has
# repoURL == $OCI_REPO with a targetRevision. Zero matches means the file shape
# changed under us; two means the edit would be ambiguous. Both are bugs worth
# stopping a promotion for, and both used to be invisible (gitops#380).
# ---------------------------------------------------------------------------
oci_revision_walk() {
  local mode="$1" file="$2" version="${3:-}"
  awk -v mode="$mode" -v oci="$OCI_REPO" -v ver="$version" '
    # Strip "key:" and any surrounding quotes / trailing comment from a scalar.
    function value(line,   v) {
      v = line
      sub(/^[[:space:]]*-?[[:space:]]*[A-Za-z][A-Za-z0-9_]*:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      gsub(/^'"'"'|'"'"'$/, "", v)
      return v
    }
    # Comments never change state (a source block legitimately has comments
    # between its repoURL and its targetRevision) and are never rewritten.
    /^[[:space:]]*#/ { if (mode == "write") print; next }
    # A new list item ends the previous source block.
    /^[[:space:]]*-[[:space:]]/ { in_src = 0 }
    # ...and re-opens it if this item is the OCI umbrella source.
    /^[[:space:]]*-?[[:space:]]*repoURL:[[:space:]]/ {
      if (value($0) == oci) in_src = 1
    }
    in_src && /^[[:space:]]*targetRevision:[[:space:]]/ {
      n++
      if (mode == "read") {
        print value($0)
      } else {
        match($0, /^[[:space:]]*targetRevision:[[:space:]]*/)
        printf "%s\"%s\"\n", substr($0, 1, RLENGTH), ver
      }
      in_src = 0
      next
    }
    { if (mode == "write") print }
    END { exit (n == 1 ? 0 : 3) }
  ' "$file"
}

# ---------------------------------------------------------------------------
# resolve_app <env> — the platform Application of an environment. Each
# environment keeps it at the env root (envs/<env>/gibson.yaml). The second
# path, envs/<env>/apps/gibson.yaml, serves the test trees that the promotion
# guards build. Honours $REPO_ROOT (default: the Argo tree this file sits in).
# ---------------------------------------------------------------------------
resolve_app() {
  local root="${REPO_ROOT:-$CHART_VERSION_TREE_ROOT}"
  if [ -f "${root}/envs/$1/gibson.yaml" ]; then
    echo "${root}/envs/$1/gibson.yaml"
  elif [ -f "${root}/envs/$1/apps/gibson.yaml" ]; then
    echo "${root}/envs/$1/apps/gibson.yaml"
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# sibling_apps <env> — the Applications that MUST move with the platform one.
#
# gibson-crds, gibson-operator-crds and gibson-velero are sibling RELEASES of
# the platform, not dependencies of it (gitops#563/#564), and zeroroot-ai/charts
# publishes them beside the umbrella at the same version (deploy#1785, the
# operator CRDs split out in charts#82). check-overlay-crd-releases.py refuses
# an overlay whose two CRD releases disagree, so a bump that left one behind
# could not merge. So an env pins three versions that have to be one version. A
# promotion that moves only the platform pin leaves the other two addressing a
# chart tag that may not exist at all: gitops#564 landed them pinned to the
# env's then-current umbrella version, and neither chart was published at that
# version, so both Applications pointed at nothing (measured on staging while
# running deploy#1746).
#
# They live in the same directory as the platform Application, which differs
# per env, so resolve rather than assume. Prints one path per line, and
# nothing when an env declares none.
# ---------------------------------------------------------------------------
sibling_apps() {
  local app dir name
  app="$(resolve_app "$1")" || return 1
  dir="$(dirname "$app")"
  for name in gibson-crds gibson-operator-crds gibson-velero; do
    [ -f "${dir}/${name}.yaml" ] && echo "${dir}/${name}.yaml"
  done
  return 0
}

# ---------------------------------------------------------------------------
# follower_envs <env> — the envs whose pins move in the same commit as <env>.
#
# Drill is the throwaway copy of staging (ADR-0095). Its values.yaml follows
# the staging values.yaml, so its chart pins must follow the staging pins. A
# promotion that moved only staging left drill on 0.135.0 while its values
# followed staging to 0.136.8. The 0.135.0 tenant-operator template requires
# tenantOperator.billing.stripeExpectedMode, which those values no longer
# carry, so the drill platform Application could not render (drill run
# 37460863468). check-promotion-order.py refuses a drill pin that differs
# from the staging pin. Prints one env per line, and nothing for other envs.
# ---------------------------------------------------------------------------
follower_envs() {
  case "$1" in
    staging) echo drill ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# env_chart_version <env> — THE way to read an env's pinned umbrella version.
# Prints the version; fails loudly (exit 2) if the Application is missing or
# does not contain exactly one OCI umbrella source.
# ---------------------------------------------------------------------------
env_chart_version() {
  local env="$1" app
  app="$(resolve_app "$env")" || {
    echo "::error::no platform Application for env '${env}' (envs/${env}/gibson.yaml or envs/${env}/apps/gibson.yaml)" >&2
    return 2
  }
  oci_revision_walk read "$app" || {
    echo "::error::${app} has no single OCI umbrella source with a targetRevision — cannot determine the pinned chart version" >&2
    return 2
  }
}
