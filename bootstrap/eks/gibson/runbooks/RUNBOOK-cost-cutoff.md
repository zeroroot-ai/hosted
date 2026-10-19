# RUNBOOK — emergency cost cutoff

> **Audience:** the operator who got the $5k AWS Budgets emergency
> alert.
>
> **Spec linkage:** R10.1 emergency-tier playbook.
>
> **Target completion time:** under 30 minutes from alert receipt to
> "spend stopped, customers informed".

> **Hard rule:** there is **NO automated cutoff** by design. An
> automated kill of production pre-revenue is too dangerous. This
> runbook is the manual playbook.

> **Environment.** Since deploy#1397 one Terraform root (`eks/gibson`) serves
> both environments, so this runbook does too. Export the env first —
> `export ENV=staging` or `export ENV=prod` — and every command below is
> copy-pasteable. In prose, `<env>` means the same thing.

---

## When this runbook fires

The `zeroroot-ai-<env>-monthly-emergency` AWS Budget at $5,000 USD has
crossed 100% of its threshold. SNS sends an email to
`alerts@zeroroot.ai`. The email subject contains "AWS Budget Alert -
zeroroot-ai-<env>-monthly-emergency".

This is an **escalation** — the soft ($1k) and hard ($3k) tiers fired
earlier in the month. The team failed to address those, and now the
account is on track to massively overspend.

---

## Phase 1 — Identify (5 min)

### 1.1 Open Cost Explorer

Sign in to `zeroroot-ai-mgmt` as `BillingViewer` Identity Center session.
**Billing → Cost Explorer → Explorer → Group by: Service → time:
Month-to-date → Filter: Project = gibson**.

### 1.2 Find the largest line items

The chart should be dominated (in normal operation) by:
- **Aurora Serverless v2** (~50%).
- **EKS** (control plane + nodes).
- **NAT Gateway data transfer**.
- **EBS** (PVCs).
- **EFS** (HF model cache).

If the dominant line is something else (e.g. Bedrock, ElastiCache, S3
egress, Sagemaker), THAT is your suspect.

### 1.3 Drill into the suspect

Group by **Usage Type** within the dominant service. Look for the
specific usage type driving spend — usually:
- A runaway compute loop.
- An unintended cross-AZ NAT path.
- Bedrock inference calls without caching.
- Compromised credentials calling expensive APIs.

---

## Phase 2 — Mitigate (15 min)

Pick the right mitigation per cause. Each command goes through
**Terraform** or **GitOps PR** if at all possible (NFR-O1 — no manual
kubectl patches outside incident response).

### 2A. Runaway compute (daemon / sandbox)

```bash
# Scale down the offending workload.
kubectl scale deployment/<runaway> -n gibson --replicas=0
# Wait for pods to terminate, then investigate root cause.
kubectl logs -n gibson <pod> --previous --tail=500
```

> The scale-down is a documented exception to NFR-O1 because it IS
> incident response. Open a follow-up PR to gitops to set replicas=0
> in chart values until the bug is fixed.

### 2B. Compromised credentials / unexpected API calls

Treat as a SEV-1 security incident. Switch to `RUNBOOK-incident.md`
immediately. Steps:

1. Identify the principal making the calls via CloudTrail.
2. Disable the principal's access key (if IAM user) or revoke the
   IRSA role's policy.
3. Force-rotate every Secrets Manager secret the compromised principal
   could read.
4. File HIPAA breach notification if PHI was exposed (R13.7).

### 2C. Cross-AZ NAT data transfer surprise

Most common cause: a workload talking to AWS API endpoints over the
NAT path instead of the VPC endpoint. Confirm via VPC Flow Logs
(audit bucket).

```bash
# Check VPC endpoints exist for the service in question.
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)"
```

If the endpoint is missing: open a PR adding it to the network module.

### 2D. Bedrock / LLM cost runaway

```bash
# Identify the workload via the IRSA role used.
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=bedrock.amazonaws.com \
  --max-results 50
```

Likely causes:
- Daemon caching disabled — restart with caching ON.
- Tenant abusing system LLM keys without quota — enforce quotas.

---

## Phase 3 — Inform (10 min)

### 3.1 Status update internally

Slack `#ops`:

```
SEV-2: zeroroot-ai-${ENV} cost emergency. $5k budget tripped at <ISO>.
Suspect: <line-item>. Mitigation: <action> at <ISO>. ETA stop: <ISO>.
Customer impact: <none / latency / outage>.
```

### 3.2 Customer comms (if customer-facing)

Switch to `RUNBOOK-incident.md` and follow the customer-comms section.
Most cost incidents are not customer-facing — confirm before
broadcasting unnecessarily.

### 3.3 Update budget thresholds

If the emergency was a legitimate growth event (not a bug), update the
budget thresholds via Terraform PR, NOT manually. The
`module.budgets` vars `soft_alert_amount`, `hard_alert_amount`,
`emergency_alert_amount` are the source of truth. **Operator sign-off
required for any change >25%** per R10.3.

---

## Phase 4 — File (post-recovery)

`enterprise/deploy/docs/cost-incident-<date>.md`:

| Field | Value |
|---|---|
| Trigger | $5k emergency alert at <ISO> |
| Suspected line item | <service / usage type> |
| Confirmed root cause | <prose> |
| Mitigation | <commands run, PRs opened> |
| Stopped at | <ISO> |
| Total overrun | $<diff> |
| Follow-ups | <bullets> |

---

## What this runbook does NOT do

- **Auto-kill anything.** A bad cutoff during an actual demo / customer
  test is worse than the spend.
- **Block the account.** Service Control Policies are not for cost
  control — they're for compliance.
- **Page anyone.** No paid pager — operator monitors `alerts@zeroroot.ai`
  during business hours; off-hours, the email sits until morning.

---

## References

- `RUNBOOK-incident.md` (security-tinged cost incidents).
- `RUNBOOK-troubleshooting.md` (technical mitigations).
- Spec: `requirements.md` R10.1, R10.3.
