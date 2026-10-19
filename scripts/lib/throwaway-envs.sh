# shellcheck shell=bash
# throwaway-envs.sh — the environments that live for one run and are then
# destroyed (ADR-0095). staging and prod are permanent and are never on it.
#
# Readers: scripts/reap-throwaway.sh (the only envs it may reap) and
# scripts/lib/restore-recovery.sh (the envs whose restore opens no catch-up
# PR, D91).
# shellcheck disable=SC2034  # read by the files that source this one
THROWAWAY_ENVS="drill"
