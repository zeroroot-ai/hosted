# module.budgets

Three AWS Budgets thresholds + a single SNS topic with email-only
subscription. Cost Explorer cost categories on Environment + Project
dimensions for tag-based reports.

## Manual cost-allocation-tag activation

After first apply, AWS does not automatically activate the four
required cost-allocation tags (`Environment`, `Project`, `Owner`,
`CostCenter`). The provider default tags put them on every resource, but Cost Explorer ignores
them until activated in the **Billing** console.

**One-shot procedure (`zeroroot-ai-mgmt`, BillingViewer permission set):**

1. Sign in to `zeroroot-ai-mgmt`.
2. Navigate to **Billing → Cost allocation tags → User-defined tags**.
3. Select `Environment`, `Project`, `Owner`, `CostCenter`.
4. Click **Activate**.
5. Wait 24 hours for tag-allocated cost data to populate.

Until step 5 completes, the three Budgets in this module fire on
**untagged** spend (which is fine — they always cover the entire
account); but the Cost Explorer cost-category breakdown will be empty.

## Email confirmation

The `aws_sns_topic_subscription` resource creates a pending email
subscription. AWS emails a confirmation link to
`var.alerts_email_address`. **An operator must click that link** before
SNS delivers any actual alert. Until confirmed, the subscription shows
as `PendingConfirmation`.

## Why no automation

Per R10.1, no Lambda-driven cost actions. No paid pager destinations
(no PagerDuty, no Opsgenie, no Statuspage). The emergency-tier budget
fires the email and points at `RUNBOOK-cost-cutoff.md` for the manual
playbook. We deliberately do not auto-kill production workloads.

## Reference

- AWS Budgets: https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html
- Cost Explorer cost categories: https://docs.aws.amazon.com/cost-management/latest/userguide/manage-cost-categories.html
- Spec: `.spec-workflow/specs/production-eks-deploy/requirements.md` (R10.1, R10.2)
