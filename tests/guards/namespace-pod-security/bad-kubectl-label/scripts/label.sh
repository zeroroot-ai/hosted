#!/usr/bin/env bash
kubectl label namespace gibson --overwrite pod-security.kubernetes.io/enforce=privileged
