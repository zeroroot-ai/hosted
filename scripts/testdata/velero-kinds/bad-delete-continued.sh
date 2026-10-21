#!/usr/bin/env bash
kubectl -n velero delete \
  backup "$1" --ignore-not-found
