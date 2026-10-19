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
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: restricted
        pod-security.kubernetes.io/audit: restricted
        pod-security.kubernetes.io/warn: restricted
    syncOptions:
      - CreateNamespace=true
YAML
