#!/usr/bin/env bash
# Two operators put a Backup kind in the cluster. A bare backup reads the first.
phase="$(kubectl -n velero get backup "$name" -o jsonpath='{.status.phase}')"
