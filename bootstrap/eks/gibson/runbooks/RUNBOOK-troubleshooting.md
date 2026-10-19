# RUNBOOK — troubleshooting

> **Audience:** stressed on-call engineer. Half-screen one-pager per
> scenario.
>
> **Spec linkage:** R11.3, NFR-R2.
>
> **Triage budget:** under 10 minutes per scenario.

> **Environment.** Since deploy#1397 one Terraform root (`eks/gibson`) serves
> both environments, so this runbook does too. Export the env first —
> `export ENV=staging` or `export ENV=prod` — and every command below is
> copy-pasteable. In prose, `<env>` means the same thing.

---

## Dashboard 5xx surge

**Symptom:** SLO `SignupErrorBudgetBurnRateFast` fires; users report
500s.

**First-look:**
```bash
kubectl logs -n gibson deployment/gibson-dashboard --tail=100
kubectl top pods -n gibson -l app=gibson-dashboard
kubectl describe deployment gibson-dashboard -n gibson | grep -A3 Conditions
```

**Likely causes:**
1. Dashboard pod crash-loop → check logs for stack trace.
2. Postgres connection pool exhausted → see "Postgres connection-pool
   exhaustion" below.
3. ESO ExternalSecret failed to sync (post-rotation) → see "ESO sync
   failure" below.
4. NLB target unhealthy → check
   `aws elbv2 describe-target-health --target-group-arn <arn>`.

**Fix:**
- Restart dashboard: `kubectl rollout restart deployment/gibson-dashboard -n gibson`.
- If memory pressure: scale: `kubectl scale deployment/gibson-dashboard --replicas=4`.

---

## Daemon panic loop

**Symptom:** `RunMissionLatencyFastBurn` fires; daemon pods crash-loop.

**First-look:**
```bash
kubectl logs -n gibson deployment/gibson --tail=200 | grep -i panic
kubectl describe pod -n gibson -l app=gibson | grep -A5 "Last State"
kubectl get events -n gibson --sort-by='.lastTimestamp' | tail -20
```

**Likely causes:**
1. Bad config from ESO-synced Secret → check `kubectl get externalsecret -n gibson`.
2. Aurora connection refused → see "Postgres connection-pool exhaustion".
3. KMS key access revoked → check `aws kms describe-key --key-id alias/zeroroot-ai-<env>-daemon-keyprovider`.
4. New release with regression → revert via `RUNBOOK-rollback.md` "Helm release rollback".

**Fix:**
- Rollback latest release if the panic timestamp matches a recent deploy.
- Otherwise: re-seed offending secret, rollout restart.

---

## Postgres connection-pool exhaustion

**Symptom:** `psql: too many connections for role "<db>"` in
dashboard / daemon logs.

**First-look:**
```bash
kubectl exec -n gibson deployment/gibson-dashboard -- env | grep DATABASE
psql "<rds-writer-endpoint>" -c "select datname, count(*) from pg_stat_activity group by 1;"
```

**Likely causes:**
1. PgBouncer not deployed (chart-side feature) → temporary mitigation
   via `pgbouncer` sidecar; permanent fix in sister
   `helm-eks-readiness-and-pg-split` spec.
2. Application connection leak → restart deployments to drain.

**Fix:**
- Restart consumers in this order:
  ```bash
  kubectl rollout restart deployment/gibson-dashboard -n gibson
  kubectl rollout restart deployment/gibson -n gibson
  ```

> **Known limitation (NFR-R2):** Aurora is single-AZ in Phase 1. A
> cluster-instance failure means downtime of 5-10 minutes during
> failover; multi-AZ HA is tracked as a follow-up spec.

---

## ALB / NLB 502 surge

**Symptom:** outside requests get 502; inside-cluster reqs to the same
service work.

**First-look:**
```bash
aws elbv2 describe-target-health --target-group-arn <arn>
kubectl get svc -n gibson | grep envoy
kubectl logs -n gibson deployment/envoy --tail=100 | grep -i error
```

**Likely causes:**
1. Envoy pod unhealthy → restart Envoy.
2. NLB target group health check probing wrong path → confirm
   `alb.ingress.kubernetes.io/healthcheck-path` annotation.
3. ACM cert expired (rare; ACM auto-rotates) → check
   `aws acm describe-certificate --certificate-arn <arn>`.

**Fix:**
- Restart Envoy.
- If cert problem: re-issue via Terraform `terraform apply -target=module.route53.aws_acm_certificate_validation.wildcard`.

---

## ESO sync failure

**Symptom:** `kubectl get externalsecret -n gibson` shows
`SecretSyncedError`.

**First-look:**
```bash
kubectl describe externalsecret -n gibson <name> | tail -30
kubectl get secret -n external-secrets -l app=external-secrets
kubectl logs -n external-secrets deployment/external-secrets --tail=50
```

**Likely causes:**
1. SM secret missing or sentinel `{"populate":false}` → run
   the OpenBao secret path (deploy#1759).
2. ESO IRSA / Pod Identity broken → confirm
   `kubectl describe pod -n external-secrets <pod> | grep Role`.
3. KMS key access denied → check `aws kms get-key-policy`.

**Fix:**
- Reseed the SM secret per the OpenBao secret path (deploy#1759).
- Restart ESO: `kubectl rollout restart deployment/external-secrets -n external-secrets`.

---

## ArgoCD Application stuck OutOfSync

**Symptom:** an Application reports `OutOfSync` (or `Degraded`) for longer
than a sync interval. **Nothing alerts on this** — there is no
`ArgoCDApplicationOutOfSync` rule on any cluster. The `PrometheusRule` that
declared it was staged-but-never-shipped and was deleted with deploy#1450;
every environment runs `observability.provider: external-grafana-cloud` with
no Prometheus Operator to evaluate a `PrometheusRule` at all. You find this
by looking, not by being paged.

**First-look:**
```bash
kubectl get applications -n argocd
APP=<name>
kubectl describe application -n argocd ${APP} | tail -50
```

**Likely causes:**
1. Operator manually patched a chart-managed resource (NFR-O1
   violation) → revert.
2. Chart bug — generated YAML drifts on sync.
3. Argo lost connection to git → check `argocd-repo-server` logs.

**Fix:**
- If operator-induced drift: identify the manual change, undo via PR
  to gitops, sync.
- If chart bug: pin Application's `targetRevision` to last-good per
  `RUNBOOK-rollback.md`.

---

## References

- `RUNBOOK-rollback.md`
- the OpenBao secret path (deploy#1759)
- `RUNBOOK-incident.md`
- Spec: `requirements.md` R11.3, NFR-R2
