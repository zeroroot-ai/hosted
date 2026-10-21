#!/usr/bin/env bash
# keyring-pushed.sh — the name of the marker file that says the cluster may hold
# the new keyring (scripts/rotate-credential.sh, scripts/substrate-rotate.sh).
# It lives in the state directory. The rotate-credentials workflow writes the
# keyring back to the environment on ANY exit when the marker exists.
PUSHED_MARKER=".cluster-keyring-pushed"
