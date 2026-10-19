#!/usr/bin/env bash
# Fixture of scripts/check-namespace-pod-security.py.
log "stage 2: Application gibson"
kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gibson
spec:
  destination:
    namespace: ${NS}
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
YAML
