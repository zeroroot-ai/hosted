#!/usr/bin/env bash
list="$(kubectl --namespace=velero get backups -o json)"
