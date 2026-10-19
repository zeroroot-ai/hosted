# RUNBOOK: purge the last backup of a deleted tenant

A tenant delete takes one last backup. Velero deletes it after 30 days (ADR-0075). A tenant owner can ask for an earlier purge. This page gives the hosted steps only.

The procedure, the checks of the request and the refusals are on the public page: [`charts: docs/runbooks/purge-tenant-backup.md`](https://github.com/zeroroot-ai/charts/blob/main/docs/runbooks/purge-tenant-backup.md). Read it first. The one purge script is `charts: scripts/purge-tenant-backup.sh`. The make verb of this repo calls that script and adds only `ENV` and the cluster access.

## Before you start

1. Do the three steps of "Before you start" on the public page. Record the request in the change record.
2. Clone `zeroroot-ai/charts` beside this repo, or set `CHARTS_ROOT=<checkout>`.
3. Get the AWS credential of the environment. Staging and drill need read-only EC2 and SSM, and `session-manager-plugin` on `PATH`. Prod needs the EKS access of the operator role.

## Purge the backup

1. Run `make purge-tenant-backup ENV=<env> TENANT=<tenant name>`. `ENV` is `kind`, `staging`, `drill` or `prod`.
2. If the script names more than one last backup, get the uid of the deleted tenant from the change record or the audit log.
3. Then run `make purge-tenant-backup ENV=<env> TENANT=<tenant name> TENANT_UID=<uid>`.
4. Wait for the line `backup <name> is deleted`.
5. Write the backup name and the time in the change record.

## How the verb reaches the cluster

| ENV | Access |
|---|---|
| `kind` | the kube context `kind-$(CLUSTER)` |
| `staging`, `drill` | `scripts/with-cluster.sh`, an SSM forward that lives as long as the script (ADR-0095) |
| `prod` | the kubeconfig that `make eks-kubeconfig ENV=prod` writes |

The verb refuses a run with no `ENV` or no `TENANT`. `tests/harness/purge-tenant-backup.bats` (`make check-verbs`) proves each refusal, and proves that the tenant reaches the script unchanged.

## If the delete fails

Follow "If the delete fails" on the public page. Run the Velero log command through the same access, for example `make with-cluster ENV=staging CMD='kubectl -n velero logs deploy/velero --tail=200'`.
