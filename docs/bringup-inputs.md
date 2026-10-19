# Bringup inputs — the one-shot gather list

Every secret, token, tfvar and file a `recreate.yml` run reads, in dependency
order. When all of it is in place, `gh workflow run recreate.yml -f env=<env>`
completes without a second touch. The workflow offers prod only (ADR-0095):
an operator rebuilds staging with `make recreate ENV=staging` from a
workstation, and the same inputs apply. The examples use staging.

Two AWS accounts: management `000000000000` (profile `zeroroot-mgmt`) and
workload `000000000000` (profile `zeroroot-prod`). The EKS estate lives in the
workload account.

## 1. The org GitHub App (once, human)

Create under `zeroroot-ai`: permission `Contents: read`, no webhook. Install
it on the repositories Argo clones (`hosted` and every gitops source). Record
the App ID, the installation ID, and a generated private-key PEM. Set the
`ghcr.io/zeroroot-ai/charts/gibson` package public so ArgoCD pulls the chart
with no credential.

The App is not the image pull credential. A GitHub App installation token
reads public packages only (measured 2026-09-10 on the private `billing`
package: HTTP 403 with `Packages: read`). Images are pulled with the keyring
member `GHCR_PULL_TOKEN` (step 3).

## 2. aws-org apply (once, management account)

Profile `zeroroot-mgmt`. Creates the OIDC provider and the `eks-bringup` /
`eks-plan-readonly` roles CI assumes. `bootstrap/eks/aws-org/terraform.tfvars`:

| tfvar | value |
|---|---|
| `prod_account_email` | the workload account root email (the only strictly required one) |
| `prod_account_id` | `000000000000` |
| `prod_account_name` | `Zero Root AI` |
| `mgmt_name_prefix` | `zero-day-ai-mgmt` |
| `findings_bucket_name_prefix` | `zero-day-ai-prod` |
| `cloudtrail_bucket_name_prefix` | `gibson-org` |
| `users` | the Identity Center user list |

## 3. Stage-0 substrate (once, workload account)

Profile `zeroroot-prod`. `make substrate ENV=<env>` creates the durable bucket,
the SMTP relay, the DNS sub-zone, the DNS credential, and writes
`/bulk/substrate/<env>/`. It generates most of the keyring itself. Then confirm the sub-zone NS records are
delegated in the apex. The operator input members:

| keyring input | what it is | needed? |
|---|---|---|
| `GHCR_PULL_TOKEN` | a machine user's personal access token (classic) with `read:packages`; the user holds Read on every private first-party package (`billing`) | yes: it is the one image pull credential (ADR-0084) |
| `STRIPE_SECRET_KEY` | the Stripe secret key of the environment's account (`sk_test_` or `sk_live_`, or a restricted `rk_` key) | yes on staging, drill and prod: preflight check 10 fails without it (hosted#450) |
| `STRIPE_PUBLISHABLE_KEY` | the publishable key of the same account and mode (`pk_test_` or `pk_live_`) | the same |
| `STRIPE_WEBHOOK_SECRET` | the signing secret of the account's webhook endpoint (`whsec_`), from `scripts/stripe-webhook-preflight.sh` | the same |

The bringup copies the three Stripe members into the OpenBao key
`gibson-stripe-credentials`, so a rebuild keeps them. No person writes them
into OpenBao by hand.

There is no LLM key input. The platform holds no LLM credential of its own:
a tenant's providers and their keys live in that tenant's provider
configuration and reach the daemon through the secrets broker.

If you set a member (`scripts/keyring.sh set /bulk/substrate/<env>/keyring.env
GHCR_PULL_TOKEN <token>`), run `make substrate ENV=<env>` once more, then
`make preflight ENV=<env>` (must exit 0 on every check). The second
substrate run applies nothing; it rewrites `substrate.env`, which carries the
fingerprint of every keyring member, and preflight checks the keyring against
those. Set a member and skip that run, and preflight fails check 1 on the
member you just set (staging, 2026-09-10).

## 4. GitHub environment (set before recreate.yml)

`recreate.yml` reads exactly these on the `<env>` environment.

| kind | name | source |
|---|---|---|
| var | `EKS_BRINGUP_ROLE_ARN` | `arn:aws:iam::000000000000:role/eks-bringup` |
| var | `EKS_PLAN_READONLY_ROLE_ARN` | the read-only role |
| var | `SUBSTRATE_ENV_FILE` | contents of `/bulk/substrate/<env>/substrate.env` |
| secret | `BRINGUP_KEYRING` | contents of `/bulk/substrate/<env>/keyring.env` |
| var | `ARGOCD_GITHUB_APP_ID` | the App ID (step 1) |
| var | `ARGOCD_GITHUB_APP_INSTALLATION_ID` | the installation ID (step 1) |
| secret | `ARGOCD_GITHUB_APP_PRIVATE_KEY` | the App private-key PEM (step 1) |

`gh variable set SUBSTRATE_ENV_FILE --env <env> -R zeroroot-ai/hosted < /bulk/substrate/<env>/substrate.env`
and `gh secret set BRINGUP_KEYRING --env <env> -R zeroroot-ai/hosted < /bulk/substrate/<env>/keyring.env`.

## 5. Committed config in this repo

| file | change |
|---|---|
| `gitops/envs/<env>/gibson.yaml` | promote the chart pin to the intended released version |

## 6. Not required for a CI run

- `operator_cidrs` — the workflow discovers the runner's own `/32`.
- `argocd_sso_client_secret` — only for ops SSO through Dex, passed as a `TF_VAR`.

## The run

1. `gh workflow run recreate.yml -R zeroroot-ai/hosted -f env=<env>`
2. Every Argo `Application` Synced + Healthy, then `PlatformBootstrap/gibson` Ready.
3. `make eks-smoke ENV=<env>`.
