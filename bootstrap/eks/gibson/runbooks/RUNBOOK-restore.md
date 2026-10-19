# RUNBOOK — DR restore drill

> **Audience:** Database Engineer running the quarterly DR exercise OR
> recovering from a prod data-loss incident.
>
> **Spec linkage:** R9.3.
>
> **Output artifact:** every drill produces
> `enterprise/deploy/docs/dr-drill-<YYYY-MM-DD>.md` capturing snapshot age,
> restore time, schema diff result.

> **Environment.** Since deploy#1397 one Terraform root (`eks/gibson`) serves
> both environments, so this runbook does too. Export the env first —
> `export ENV=staging` or `export ENV=prod` — and every command below is
> copy-pasteable. In prose, `<env>` means the same thing.

---

## Aurora snapshot restore to isolated VPC

### 1. Identify a recent snapshot

```bash
aws rds describe-db-cluster-snapshots \
  --db-cluster-identifier zeroroot-ai-${ENV} \
  --snapshot-type automated \
  --query 'sort_by(DBClusterSnapshots, &SnapshotCreateTime) | [-5:].{id:DBClusterSnapshotIdentifier,time:SnapshotCreateTime,size:AllocatedStorage}'
```

Pick a snapshot less than 24h old.

### 2. Restore into an isolated VPC

```bash
SNAPSHOT_ID=<from step 1>
RESTORE_VPC=<isolated VPC ID — see below>
RESTORE_SUBNETS=<3 private subnets in the isolated VPC>
RESTORE_SG=<SG that allows 5432 from your bastion only>

# Create a one-shot subnet group + cluster.
aws rds create-db-subnet-group \
  --db-subnet-group-name zeroroot-ai-${ENV}-restore-${SNAPSHOT_ID} \
  --db-subnet-group-description "DR drill restore" \
  --subnet-ids ${RESTORE_SUBNETS}

aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier zeroroot-ai-${ENV}-restore-${SNAPSHOT_ID} \
  --snapshot-identifier ${SNAPSHOT_ID} \
  --engine aurora-postgresql \
  --vpc-security-group-ids ${RESTORE_SG} \
  --db-subnet-group-name zeroroot-ai-${ENV}-restore-${SNAPSHOT_ID} \
  --deletion-protection

# Spin up a writer instance.
aws rds create-db-instance \
  --db-instance-identifier zeroroot-ai-${ENV}-restore-${SNAPSHOT_ID}-0 \
  --db-cluster-identifier zeroroot-ai-${ENV}-restore-${SNAPSHOT_ID} \
  --engine aurora-postgresql \
  --db-instance-class db.serverless
```

> **Isolated VPC requirement:** the restore must NOT land in the
> production VPC. Use the same workspace's `intra` subnets — they have
> no NAT and no peering, so no risk of accidental traffic to/from
> production.

### 3. Verify schema integrity

```bash
# From bastion or test host with psql
psql "postgres://gibson_admin@<restore-cluster-endpoint>/postgres" \
  -c "\d+ public.*"
```

### 4. Schema diff against production

```bash
PG_DUMP_ARGS="--schema-only --no-owner --no-privileges"
pg_dump ${PG_DUMP_ARGS} \
  "postgres://gibson_admin@<restore-cluster-endpoint>/dashboard" \
  > /tmp/restore-schema.sql
pg_dump ${PG_DUMP_ARGS} \
  "postgres://gibson_admin@<prod-cluster-endpoint>/dashboard" \
  > /tmp/prod-schema.sql

diff -u /tmp/prod-schema.sql /tmp/restore-schema.sql > /tmp/schema.diff
wc -l /tmp/schema.diff
```

Expected: byte-equivalent (modulo `RESTORE FROM SNAPSHOT` timestamps).
A non-empty meaningful diff means snapshot drift — file an incident.

### 5. Tear down the restore

```bash
aws rds modify-db-instance \
  --db-instance-identifier zeroroot-ai-${ENV}-restore-${SNAPSHOT_ID}-0 \
  --no-deletion-protection \
  --apply-immediately

aws rds delete-db-instance \
  --db-instance-identifier zeroroot-ai-${ENV}-restore-${SNAPSHOT_ID}-0 \
  --skip-final-snapshot

aws rds delete-db-cluster \
  --db-cluster-identifier zeroroot-ai-${ENV}-restore-${SNAPSHOT_ID} \
  --skip-final-snapshot

aws rds delete-db-subnet-group \
  --db-subnet-group-name zeroroot-ai-${ENV}-restore-${SNAPSHOT_ID}
```

---

## ESO secret recovery from us-west-2 replica

If the `zeroroot-ai-<env>` SM secret store is corrupted (rare — KMS key
disable, region-wide AWS issue):

```bash
SECRET_ID="gibson/${ENV}/<name>"

# Read the replica copy from us-west-2.
aws secretsmanager get-secret-value \
  --region us-west-2 \
  --secret-id ${SECRET_ID}

# If the primary is intact but a single version is bad, see
# RUNBOOK-rollback.md "ESO secret rotation rollback".
```

For full-region failover, the replica is read-only; promote via the
us-west-2 console only after the us-east-1 region is confirmed
unrecoverable.

---

## Drill artifact

After every drill, file `enterprise/deploy/docs/dr-drill-<YYYY-MM-DD>.md`:

```markdown
# DR drill — <date>

| Field | Value |
|---|---|
| Operator | <name> |
| Snapshot ID | <from step 1> |
| Snapshot age at restore | <minutes> |
| Restore wall-clock time | <minutes> |
| Schema diff lines (excluding timestamps) | <integer> |
| ESO secret-recovery test result | <pass/fail> |
| Issues encountered | <freeform> |
| Follow-ups | <bullets> |
```

---

## References

- AWS Aurora restore-from-snapshot:
  https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_RestoreFromSnapshot.html
- Spec: `requirements.md` R9.3
