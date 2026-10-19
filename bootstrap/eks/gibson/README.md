# `eks/gibson` — stage 1 on AWS

One root, both environments. Stage 1 of the substrate contract (ADR-0083):
the cluster and its six rows, and nothing else. It provides the VPC, the EKS
cluster with its node groups and OIDC provider, Karpenter, the EBS CSI addon with `gp3` as the default
StorageClass, the AWS Load Balancer Controller, the metrics-server EKS
addon, three controller IRSA roles, and Argo CD. Both teardown modes
destroy all of it. `scripts/check-stage1-shape.py` enforces the shape: a
block-count ceiling, and none of the deleted resource classes (RDS,
Secrets Manager, KMS keys, WAFv2, GuardDuty, SES, ACM) may come back.

A root for a further cloud would be one more module of exactly this shape: the
managed cluster with its node prep, that cloud's CSI driver with a default
StorageClass, its LoadBalancer implementation, its autoscaler,
metrics-server, the three controller identities, and the same Argo CD
module. Nothing else moves per cloud — everything above the cluster is the
umbrella chart, and everything that outlives the cluster is stage 0
(`eks/gibson-bootstrap`).

This directory replaces the forked `eks/zeroroot-ai-staging` and
`eks/zeroroot-ai-prod` copies (deploy#1397). Nothing in it names an
environment; the whole env axis lives in `envs/staging.tfvars` and
`envs/prod.tfvars`.

## Layout

| Path | What it is |
|---|---|
| `*.tf` | the root — module wiring, Karpenter, tags, backend + provider config |
| `modules/` | the child modules (network, cluster, iam-irsa, bootstrap-addons, argocd) |
| `envs/<env>.tfvars` | **the env axis** — committed, no secrets |
| `terraform.tfvars` | operator-local, gitignored — only `operator_cidrs` and friends |
| `scripts/` | the apply DAG, pre-destroy preflight, smoke tests |
| `runbooks/` | rollback, restore, incident, cost-cutoff, … |

## Never run `terraform` here directly

Go through the Makefile, which threads `ENV` into both the backend config and
the `-var-file`:

```bash
make eks-init  ENV=staging     # or ENV=prod
make eks-plan  ENV=staging
make recreate  ENV=staging                  # bringup verb (scripts/recreate-aws.sh)
make teardown  ENV=staging MODE=wipe        # bringup verb (scripts/teardown-aws.sh)
```

A bare `terraform apply` in this directory has no `-var-file`, so every
env-identifying variable (`environment`, `workspace_name`, `cluster_name`,
`cost_center`, `app_of_apps_path`, `route53_zone_name`) is
unset and the plan fails. That failure is deliberate: it is the guard that
stops a staging apply landing on prod state in the shared co-tenant account
(ADR-0073). A bare `terraform init` likewise has no backend `key` and refuses
to initialise.

The apex zone `zeroroot.ai` is not this root's to touch. `eks/apex-zone`
owns it and its mail records (ADR-0083). This root creates no hosted zone,
reads no zone and writes no record: DNS records are external-dns's job, and
external-dns is an umbrella subchart (deploy#1728). `route53_zone_name` is
carried only as the environment's name axis (staging uses the sub-zone that
stage 0 created and delegated; prod uses the apex).

The verbs run the same sequence for both envs. Raw
`terraform apply`/`destroy` bypasses the cold-convergence ordering and the
teardown-gap cleanup, and WILL cycle or leave orphans (deploy#808/#810).

## First-time bootstrap

The durable bucket must exist before the first `make eks-init`. Stage 0
creates it: `make substrate ENV=<env>` (`eks/gibson-bootstrap`, see its
README), then `make preflight ENV=<env>`. Then:

```bash
make eks-init ENV=<env>
```

which derives the backend config from `ENV` plus the live account ID:

```
key          = tfstate/eks-gibson/terraform.tfstate
bucket       = zeroroot-ai-<env>-durable-<account-id>
use_lockfile = true
```

## Operator-local values

```bash
cp terraform.tfvars.example terraform.tfvars    # fill in operator_cidrs
```

Keep that file to per-operator and secret values only. Everything env-shaped
belongs in `envs/<env>.tfvars`. Terraform's precedence puts `-var-file` above
`terraform.tfvars`, so a value set in both is silently won by the env file and
the local copy is dead weight that looks live.

Secrets never go in any file:

```bash
make recreate ENV=staging  # Argo repo-creds are seeded from the org GitHub App by keyring-to-cluster.sh (ADR-0083)
```

## Adding an env-specific behaviour

Add a variable with a safe default (or no default if it identifies the env),
consume it in the root or module, and set it in `envs/<env>.tfvars`. Do not
branch on `var.environment` — the env axis is data, not a conditional. The
existing shape to copy is the four `argocd_extra_*` lists: each is one tfvars
entry rather than a fork.

## First applies

Initial applies may need `-target=module.network`, then
`-target=module.cluster` before a full apply, to break the kubernetes/helm
provider chicken-and-egg. The recreate verb (scripts/recreate-aws.sh) owns this
ordering. There is no other apply entrypoint.

## History

Originally derived from the `eks/gibson-dev/` starter template, retired in
deploy#1319. Forked into per-env copies, which drifted (50 differing entries,
two separate aws-provider-v6 migration PRs) until deploy#1397 unified them
back into this root.
