# shellcheck shell=bash
# ---------------------------------------------------------------------------
# skopeo.sh — the one skopeo check of the cloud bringup.
#
# scripts/belief-trainer-image.sh copies the trainer image with
# `skopeo copy --all --preserve-digests`. An old skopeo has no --all (the
# Debian package 0.1.36 is one), and it fails only at the copy, after
# preflight and the archive gate passed (staging, 2026-10-11). So the recreate
# and the copy script ask skopeo itself, at their start, whether its copy
# command has --all. The help text is the check: a version number says less,
# because distributions patch and rename their builds.
#
# skopeo_missing_all — prints nothing and returns 0 when skopeo is on PATH and
# its copy command has --all. Otherwise prints the reason and returns 1.
# ---------------------------------------------------------------------------
skopeo_missing_all() {
  local help
  if ! command -v skopeo >/dev/null 2>&1; then
    printf 'skopeo is not on PATH. The bringup copies the belief trainer image with skopeo copy --all. Install skopeo 1.x\n'
    return 1
  fi
  help="$(skopeo copy --help 2>&1 || true)"
  if ! printf '%s\n' "$help" | grep -qE '(^|[[:space:],])--all([[:space:],=]|$)'; then
    printf 'the skopeo on PATH (%s) has no copy --all, which the bringup uses to copy the belief trainer image with its digest. Install skopeo 1.x, or put a wrapper for quay.io/skopeo/stable first on PATH\n' \
      "$(skopeo --version 2>/dev/null | head -n1)"
    return 1
  fi
  return 0
}
