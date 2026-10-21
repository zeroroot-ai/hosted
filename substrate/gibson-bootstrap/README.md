# `eks/gibson-bootstrap`: stage 0, the substrate bootstrap, for an AWS environment

Decisions: ADR-0083 (the
substrate contract), [`docs/bringup.md`](../../docs/bringup.md) (the stages
and the verbs), `CONTEXT.md` "Substrate bootstrap", "Durable bucket",
"Bringup keyring". Issue: deploy#1742. The kind version of the same stage is
[`kind/substrate/substrate.sh`](../../kind/substrate/substrate.sh).

## In plain words

An environment is three stages. This workspace is stage 0 on AWS: the four
things that outlive every cluster of an environment. It creates them once,
writes the bringup keyring and `substrate.env`, and no teardown mode reaches
it. Then `make preflight ENV=<env>` proves every line of `substrate.env` live,
and only then may stage 1 start.

| Input of the contract | On AWS | File |
|---|---|---|
| durable bucket | `zeroroot-ai-<env>-durable-<account>`, S3, one per environment | `bucket.tf` |
| bucket credential | IAM user `zeroroot-ai-<env>-platform`. No `s3:Delete*` except `s3:DeleteObject` under `backups/velero/`, which kopia needs (deploy#1734); never `s3:DeleteObjectVersion` | `credentials.tf` |
| SMTP relay | SES at `email-smtp.us-east-1.amazonaws.com:587`, IAM user `zeroroot-ai-<env>-smtp` | `credentials.tf` |
| DNS sub-zone | `<env>.zeroroot.ai`, delegated from the apex with one NS record | `zone.tf` |
| bringup keyring | a file, generated once by `scripts/keyring.sh` | `substrate.sh` |
| setec disk registry | private ECR repository `zeroroot-ai-<env>-setec-disks` with immutable tags, and IAM user `zeroroot-ai-<env>-setec-disk-builder` with push on it and nothing else (D85). The node role of stage 1 pulls. `substrate.env` names it as `SETEC_DISK_REPO` | `ecr.tf` |
| belief trainer registry | private ECR repository `zeroroot-ai-<env>-belief-trainer` with immutable tags (gibson#31). `scripts/belief-trainer-image.sh` copies the trainer image that the overlay pins into it. The node role of stage 1 pulls. `substrate.env` names it as `BELIEF_TRAINER_REPO` | `ecr.tf` |

## Run it

```bash
AWS_PROFILE=zeroroot-prod make substrate ENV=staging
make preflight ENV=staging
```

`make substrate` calls `substrate.sh <SUBSTRATE_DIR>/<env> <env>` and nothing
else runs this workspace. The script:

1. inits Terraform on the state in the durable bucket, under `tfstate/stage0/`
   (a new environment has no bucket yet, so its first apply uses a local state
   file, and the script then runs `terraform init -migrate-state` once),
2. plans `envs/<env>.tfvars` and refuses a plan that deletes anything,
3. applies the plan,
4. writes the keyring once, from three Terraform outputs plus three
   generated randoms,
5. writes `substrate.env`.

A second run plans nothing, keeps the keyring, and rewrites `substrate.env`
with the same values.

## Where the files live

`SUBSTRATE_DIR` defaults to `/bulk/substrate`. It is outside the checkout for
the same reason `KIND_PV_DIR` is: it must survive a reboot, a deleted
worktree and every cluster. Never put it under `/tmp`.

| File under `SUBSTRATE_DIR/<env>/` | Mode | Holds |
|---|---|---|
| `terraform.tfstate` | 0600 | only the first apply of a new environment, until the bucket exists |
| `keyring.env` | 0600 | the bringup keyring: seal key, Velero password, bucket credential, SMTP password |
| `substrate.env` | 0644 | endpoints, names, the keyring fingerprints. No secrets |

`substrate.env` is the one artifact stage 1 may read. Its keys are the ones
`scripts/preflight.sh` reads, plus three that only an AWS environment has:
`APEX_ZONE_NAME`, `APEX_ZONE_NAMESERVER` and `APEX_DKIM_SELECTORS`, which
switch on the apex mail-record check. kind sets none of them.

## The durable bucket

One bucket, four prefixes, one lifecycle rule each. Preflight proves the
rules for the first three exist.

| Prefix | Holds | Lifecycle |
|---|---|---|
| `tfstate/` | Terraform state of stage 1 (`eks/gibson`, key `tfstate/eks-gibson/terraform.tfstate`) | current versions never expire, noncurrent versions expire after 90 days |
| `backups/` | Velero, CNPG WAL and base backups, the OpenBao archive | `STANDARD_IA` after 30 days, expired at 180, noncurrent versions at 30 |
| `audit/` | the append-only audit log | expired after 2192 days (six years), never before |
| `preflight/` | the canaries preflight writes and cannot delete | expired after one day |

Versioning is on. Encryption is SSE-S3 (`AES256`). Public access is blocked.
Object lock is enabled on the bucket, with no default retention. Locking of
the Terraform state is S3 native (`use_lockfile`), so there is no DynamoDB
table.

**Audit retention.** S3 has no per-prefix default retention, so the bucket
policy enforces it: a `PutObject` under `audit/` must carry an object lock in
the environment's mode for at least 2192 days, or it is denied for every
principal. The lifecycle rule expires the object after the same 2192 days.
The mode is `GOVERNANCE` on staging and `COMPLIANCE` on prod
(`audit_lock_mode` in `envs/<env>.tfvars`). On prod no principal, not even
the account root, deletes an audit object before its retention ends. On
staging the account owner with `s3:BypassGovernanceRetention` can still empty
the bucket when staging is decommissioned. Object lock needs nothing from
KMS.

**No KMS key.** The old bootstrap encrypted its state bucket with a KMS key
it created. ADR-0083 puts no cloud KMS in the data path. This workspace
creates no key of any kind.

**No `prevent_destroy`.** ADR-0083 deletes the retain machinery, and
`docs/bringup.md` lists `prevent_destroy` on buckets among the things that
no longer exist. What keeps the durable bucket is that no path destroys it:
this workspace has no destroy target, `substrate.sh` refuses a plan that
deletes anything, and `scripts/check-apex-zone-ownership.py` fails the build
on a `terraform destroy` of this workspace in the Makefile, a workflow or a
script. A bucket that holds objects cannot be deleted by a raw
`terraform destroy` either.

## The platform credential

IAM user `zeroroot-ai-<env>-platform`, path `/substrate/`. Its access key is
the keyring's `BUCKET_ACCESS_KEY` and `BUCKET_SECRET_KEY`. Every workload
that touches the durable bucket uses it, and so does preflight.

Its IAM policy allows: list the bucket and its versions, read its versioning,
lifecycle and object-lock configuration, get and put objects, abort a
multipart upload, get and put an object retention. It allows no delete and
no change to the bucket. The bucket policy denies `s3:Delete*`,
`s3:BypassGovernanceRetention` and every `s3:PutBucket*` configuration
action to this user as well, so the guarantee holds even if the IAM policy
is widened later. Preflight proves it with an attempted delete on every run.
The same allow list configures MinIO on kind, so preflight proves one shape
on both substrates.

## The SMTP relay

By default SES through its SMTP endpoint in `aws_region`. This workspace
creates IAM user `zeroroot-ai-<env>-smtp`, allowed `ses:SendRawEmail` and
`ses:SendEmail` as the company's domain identity and nothing else. The SMTP
user is the access key id (`SMTP_USER` in `substrate.env`). The SMTP password
is the SES SMTP password the provider derives from the secret key
(`ses_smtp_password_v4`, bound to the region), and it is the keyring's
`SMTP_PASSWORD`. The SES domain identity and its DKIM records are company
property and live in `eks/apex-zone`.

An operator who brings another relay sets `smtp_host`, `smtp_port`,
`smtp_user` and `smtp_password` together in the environment's tfvars or as
`TF_VAR_` variables. Then this workspace creates no SMTP user and the
supplied credential goes into the keyring.

## The DNS credential

IAM user `zeroroot-ai-<env>-dns`, path `/substrate/`. Its access key is the
keyring's `DNS_ACCESS_KEY` and `DNS_SECRET_KEY`. Two operators use it, both
umbrella subcharts: cert-manager publishes the ACME DNS-01 challenge record
for the edge certificate, and external-dns publishes the platform's records.
The bringup writes it into the Secret `gibson/route53-credential` (keys
`access-key-id`, `secret-access-key`), which both operators read by that
name (`helm/gibson/values-eks.yaml` in charts). Stage 1 mints no IRSA role
(ADR-0083), so this is the one credential the two operators have.

Its IAM policy allows: change and list the records of the environment's
zone, read that zone, and the unscoped reads Route53 needs to find it
(list hosted zones, list by name, list tags, get a change). It allows
nothing on any other zone and nothing outside Route53. Preflight proves it
lists the zone on every run (check 8). A keyring written before this user
existed gains the two members on the next `make substrate`: they are input
members, set after generate, and nothing else in the keyring changes.

## The DNS sub-zone

Only the zone name decides, there is no flag. `zone_name = staging.zeroroot.ai`
is a sub-zone env: this workspace creates the hosted zone and one NS record in
the apex. That NS record is the one write into the apex an environment makes.
`zone_name = zeroroot.ai` is the apex env (prod): this workspace creates
nothing in DNS and `substrate.env` names the apex as the environment's zone.

The apex is owned by `eks/apex-zone`, read here as a data source, never
created. `eks/gibson` reads the environment's zone by name as a data source
and creates no zone in either shape. `scripts/check-apex-zone-ownership.py`
fails the build on any `aws_route53_zone` in `eks/gibson`.

## State of this workspace, and secrets in it

The state of this workspace lives in the durable bucket it creates
(ADR-0083, amendment of 2026-10-21):

| Object | Holds |
|---|---|
| `tfstate/stage0/terraform.tfstate` | the state, with S3 native lock files (`use_lockfile`) |
| `tfstate/stage0/key-slots.tfvars.json` | the active access key slot of each user |
| `tfstate/stage0/key-rotation.json` | the time of the last switch of each user |

The state holds the IAM access keys in clear text. So the bucket policy
(`bucket.tf`, `DenyStage0StateToEveryoneElse`) denies this prefix to every
principal except the key rotation role (`rotation-role.tf`) and the roles in
`stage0_state_principal_role_names` (the operator role of the workstation, and
for drill the bringup role). `bucket.tf` also sets `prevent_destroy` on the
bucket, because the bucket holds its own state.

## The key rotation role

`rotation-role.tf` makes `zeroroot-ai-<env>-key-rotation` where
`rotation_role_enabled = true` (staging and prod). Only the workflow
`.github/workflows/rotate-credentials.yml` can assume it, off `main`, in the
GitHub environment of the env, through OIDC. It can write the access keys of the
four stage 0 users, read the stage 0 resources so `terraform plan` can refresh,
and read and write `tfstate/stage0/`. It reaches the cluster as the other
workflows do: an SSM command and port forward to the one instance tagged
`Name=zeroroot-ai-<env>` for staging, and `eks:DescribeCluster` for prod. It
cannot change any other resource.

## The keyring reaches GitHub

`BRINGUP_KEYRING` is a GitHub environment secret, and `SUBSTRATE_ENV_FILE` is an
environment variable. The first load is one command per environment, by the
person who holds the keyring:

```bash
gh secret set BRINGUP_KEYRING --env staging -R zeroroot-ai/hosted < /bulk/substrate/staging/keyring.env
gh variable set SUBSTRATE_ENV_FILE --env staging -R zeroroot-ai/hosted < /bulk/substrate/staging/substrate.env
```

After that, a rotation writes both through a GitHub App
(`.github/workflows/rotate-credentials.yml`).

## Rotation

Each rotation runs in `.github/workflows/rotate-credentials.yml`, and nowhere
else. `keyring.sh rotate`, `keyring.sh retire` and `substrate-rotate.sh` refuse to
run unless `GITHUB_ACTIONS` is true. The workflow is `workflow_dispatch` only.
The GitHub environment of the env gates each run with its required reviewers.

| Credential | Dispatch | ADR-0171 row |
|---|---|---|
| `platform`, `smtp`, `dns`, `setec-disk-builder` | `step: rotate`. A run that finds an open rotation continues it. | 12 |
| `OPENBAO_SEAL_KEY`, `VELERO_REPO_PASSWORD`, `SETEC_DISK_SIGNING_SEED` | `step: rotate`, then `step: retire` after the cluster runs on the new value | 11 |

An access key has two slots (`key_slots`, `tfstate/stage0/key-slots.tfvars.json`).
`scripts/substrate-rotate.sh` adds the free slot, makes it active, writes the
new key into the keyring and `substrate.env`, pushes the keyring to the
cluster, restarts each workload that reads the Secret keys of that user, waits
until AWS reports the new key in use, waits until the old key has stayed
unused for four hours after the switch, and then deletes the old key. A run
that stops (the new key not used yet, the quiet time not over) exits 10.
The workflow writes the new keyring and `substrate.env` back to the
environment, and a later dispatch continues the rotation. A rotation that
exits with any other code writes nothing back.

`VELERO_REPO_PASSWORD` rotate needs the input `velero_prefix`. A new password
starts a new kopia repository at a new prefix, so merge the overlay change of
`bucket.prefix` first. The step refuses unless the overlay names that prefix.

The keyring has 12 members since hosted#528 deleted `CNPG_BACKUP_KEY`. The set
fingerprint in a `substrate.env` written before that change covers 13 lines,
so `keyring.sh verify` fails on it. Run `make substrate ENV=<env>` one time on
each environment, then load the new `substrate.env` with
`gh variable set SUBSTRATE_ENV_FILE`.

## Prod

`envs/prod.tfvars` is code, not yet applied. The prod estate's state, and the
state of `eks/apex-zone` and `eks/public-site`, still live in the old
`zeroroot-ai-prod-tfstate-<account>-us-east-1` bucket with its DynamoDB lock
table and KMS key. They move to `tfstate/` in the prod durable bucket when
prod's stage 0 is applied, with `terraform init -migrate-state`. Until then
that bucket, table and key stay, unmanaged by any workspace in this repo.

## Terraform version

`>= 1.11`: `eks/gibson` locks its state in this bucket with `use_lockfile`,
which is general availability from 1.11. `.terraform-version` at the repo
root pins the one version CI runs for `fmt`, `validate`, the guards, the
verbs and the exit tests. The `install-terraform` action reads it. The
workstation runs the same version.

## Related

- `eks/gibson/backend.tf`: the backend this workspace serves.
- `eks/apex-zone`: the apex zone and its mail records.
- `scripts/preflight.sh`, `tests/harness/preflight.bats`: the verb and its
  failing fixtures.
- `.github/workflows/exit-test-terraform.yml`: the `plan (staging)` job inits
  against this bucket on `main` and on dispatch.
