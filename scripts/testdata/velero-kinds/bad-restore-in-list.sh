#!/usr/bin/env bash
kubectl -n velero get restores,schedules.velero.io -o name
