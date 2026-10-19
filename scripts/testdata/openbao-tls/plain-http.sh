#!/usr/bin/env bash
# Fixture of check-openbao-tls-callers.py: each line below must fail.
kubectl exec openbao-0 -c openbao -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status'
export VAULT_ADDR=http://openbao.gibson.svc:8200
curl -fsS "http://127.0.0.1:8200/v1/sys/health"
