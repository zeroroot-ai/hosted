# RUNBOOK — tenant deletion (right-to-be-forgotten)

> **Audience:** Compliance Engineer or DBA fielding a
> right-to-be-forgotten request.
>
> **Spec linkage:** R9.5 of
> `.spec-workflow/specs/production-eks-deploy/requirements.md`.
>
> **SLA:** the tenant data is purged within **30 days** of receipt of
> the customer's request. Aurora point-in-time recovery retention
> (35 days) is the floor — once 35 days pass after deletion, even PITR
> cannot recover the rows.
>
> **Hard rule:** audit-log references to the tenant are PRESERVED for
> 6 years per HIPAA Security Rule § 164.316(b)(2)(i). Tenant-OWNED
> data goes; audit-trail metadata (who did what, when, against
> tenant=X) stays.

> **Last backup.** The tenant delete takes one last backup that expires
> after 30 days. To purge it earlier, follow
> [RUNBOOK-purge-tenant-backup.md](RUNBOOK-purge-tenant-backup.md).

> **Environment.** Since deploy#1397 one Terraform root (`eks/gibson`) serves
> both environments, so this runbook does too. Export the env first —
> `export ENV=staging` or `export ENV=prod` — and every command below is
> copy-pasteable. In prose, `<env>` means the same thing.

---

## Hand-off coordination

The chart-side `tenant-operator` (sister spec
`helm-eks-readiness-and-pg-split`) owns:

- `Tenant` Custom Resource teardown.
- Per-tenant K8s namespace deletion.
- Per-tenant Neo4j / Qdrant subchart cleanup.
- FGA tuple removal.

This runbook owns:

- Aurora row deletion across all per-tenant tables.
- S3 object deletion under per-tenant prefixes.
- Audit-log retention beyond the deletion (the references stay).

---

## Phase 1 — Receive and verify the request

1. Compliance officer receives the customer's deletion request via
   the documented channel (email to `legal@zeroroot.ai`).
2. Verify the requester is authorised (per the customer's account
   admin role).
3. Open a Linear / Jira ticket: `[GDPR/HIPAA] Tenant deletion -
   tenant=<id>`.
4. Capture the request artifact (email body, signature) in 1Password
   under the case file.

---

## Phase 2 — Quiesce the tenant (5 min)

```bash
# Pause incoming traffic by suspending the tenant via the dashboard
# admin API.
TENANT_ID=<id>
kubectl exec -n gibson deployment/gibson -- \
  /opt/gibson/bin/gibson-admin tenant suspend --id ${TENANT_ID}

# Confirm:
kubectl get tenant ${TENANT_ID} -n gibson -o jsonpath='{.status.phase}'
# Expect: Suspended
```

---

## Phase 3 — Tear down chart-side resources (sister spec)

The tenant-operator handles this on `Tenant` CR delete:

```bash
kubectl delete tenant ${TENANT_ID} -n gibson
```

Wait for the operator to reconcile (≤2 min). Confirm:

```bash
kubectl get namespace tenant-${TENANT_ID}
# Expect: NotFound

kubectl get pods -A -l tenant=${TENANT_ID}
# Expect: empty
```

If anything lingers, see sister spec's troubleshooting.

---

## Phase 4 — Delete tenant-owned Aurora rows (10 min)

> **Caution:** these queries are irreversible after Aurora's PITR
> window expires (35 days post-delete).

1. Connect from a bastion / Identity-Center-authed session:
   ```bash
   psql "<rds-writer-endpoint>" -U gibson_admin
   ```

2. Run the per-DB deletion in a transaction:
   ```sql
   BEGIN;

   -- dashboard DB
   \c dashboard
   DELETE FROM users WHERE tenant_id = :'TENANT_ID';
   DELETE FROM sessions WHERE tenant_id = :'TENANT_ID';
   -- ... per-table per the chart-side schema. The chart team owns the
   -- canonical list; do NOT improvise.

   COMMIT;
   ```

3. Confirm row counts went to 0:
   ```sql
   SELECT count(*) FROM users WHERE tenant_id = :'TENANT_ID';
   ```

> **DO NOT delete from `audit_log` tables.** Audit references are
> retained per R13.3.

---

## Phase 5 — Delete tenant-owned S3 objects (5 min)

```bash
TENANT_ID=<id>

for bucket in audit artifacts checkpoints; do
  aws s3 rm "s3://zeroroot-ai-${ENV}-${bucket}-<account-id>/tenants/${TENANT_ID}/" --recursive
done
```

> **DO NOT** wipe entire buckets — only the per-tenant prefix.

For S3 versioned buckets, also expire the noncurrent versions:

```bash
aws s3api list-object-versions \
  --bucket zeroroot-ai-${ENV}-artifacts-<acct> \
  --prefix "tenants/${TENANT_ID}/" \
  --query 'Versions[].[Key,VersionId]' \
  --output text |
  while read key vid; do
    aws s3api delete-object \
      --bucket zeroroot-ai-${ENV}-artifacts-<acct> \
      --key "${key}" --version-id "${vid}"
  done
```

---

## Phase 6 — Audit retention check

Confirm the audit logs retain references to the tenant for the next 6
years:

```bash
aws s3 ls "s3://zeroroot-ai-${ENV}-audit-<acct>/" \
  --recursive | grep "${TENANT_ID}" | head
# Expect: at least the historic audit entries (NOT scrubbed).
```

```sql
\c dashboard
SELECT count(*) FROM audit_log WHERE actor_tenant_id = :'TENANT_ID';
-- Expect: > 0 (audit references intact).
```

---

## Phase 7 — File evidence

`enterprise/deploy/docs/compliance/tenant-deletion-<id>-<date>.md`:

| Field | Value |
|---|---|
| Tenant ID | <id> |
| Request received | <ISO> |
| Request verified by | <officer> |
| Quiesced at | <ISO> |
| Tenant CR deleted at | <ISO> |
| Aurora rows deleted at | <ISO> |
| S3 prefix purged at | <ISO> |
| Audit-log references retained | yes (count: <n>) |
| Customer notified at | <ISO> |
| Operator | <name> |

Notify the customer of completion via email; close the Linear / Jira
ticket.

---

## Outside-30-days exceptions

If this runbook cannot complete within 30 days (database outage, etc.):

1. File an incident per `RUNBOOK-incident.md`.
2. Notify the customer of the delay with an ETA.
3. Notify the HIPAA Security Officer.
4. Escalate to AWS Support if the cause is platform-side.

---

## References

- HIPAA Security Rule § 164.316(b)(2)(i) — 6-year audit retention.
- Spec: `requirements.md` R9.5, R13.3.
- Sister: `helm-eks-readiness-and-pg-split` for tenant-operator
  details.
