#!/usr/bin/env bash
phase="$(kubectl -n velero get backups.velero.io "$name" -o jsonpath='{.status.phase}')"
kubectl -n velero delete backup.velero.io "$1" --ignore-not-found
kubectl -n gibson get backups.postgresql.cnpg.io -o name
kubectl -n velero get restores.velero.io -o name
# kubectl get backup in a comment is not a call
echo "run kubectl get backup by hand"
