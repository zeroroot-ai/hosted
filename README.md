# hosted

ZeroRoot's own estate. Not distributed.

This repo is a **consumer** of `zeroroot-ai/charts`. It holds no chart source,
and a guard enforces that: any `helm/**/templates/` path fails the build.

## Three directories, because there are three lifecycles

| Directory | Stage | A teardown |
|---|---|---|
| `substrate/` | 0 — the durable bucket, the DNS sub-zone, the SMTP relay, the keyring | **survives both modes** |
| `bootstrap/` | 1 — the VPC, the cluster, node groups, Argo CD, and the observability stack | destroys it |
| `gitops/` | 2 — the platform, synced by Argo, plus the SaaS overlay | goes with stage 1 |

Two stages of bringup, three directories of ownership. Stage 0 and stage 1 have
**opposite lifecycles** — stage 1 is destroyed on every teardown and stage 0 must
never be — and they use different state storage: stage 0 keeps Terraform state
local under `/bulk/substrate/<env>`, stage 1 uses the durable bucket as its
backend. Sharing a directory is how a `terraform destroy` reaches too far.

## The verbs

```sh
make substrate ENV=kind                    # stage 0, once per workstation
make preflight ENV=kind                    # prove every line of substrate.env live
make recreate  ENV=kind                    # preflight -> stage 1 -> stage 2
make teardown  ENV=kind MODE=wipe|preserve # MODE has no default, on purpose
```

## The drill budget

The drill (`.github/workflows/drill.yml`) destroys and rebuilds the `drill`
environment from nothing. Two budgets limit it: time and certificates.

**Time.** The drill is four jobs. GitHub stops a job at 360 minutes, so each
job stops before that. Each job gets its own OIDC credential, which lasts 6
hours.

| Job | Limit | What it does |
|---|---|---|
| `up` | 345 min | recreate from nothing, the node ceiling, the smoke, the open access key rotation |
| `restore` | 350 min | seed, preserve, restore, read each record back |
| `rotation` | 250 min | rotate each credential class, and start the access key rotation (a rotation dispatch) |
| `teardown` | 60 min | teardown, archive clear, report; always runs |

The step limits in `up` are the fixed waits of the scripts plus 30 percent.
The workflow header shows the sums. The drill node terminates itself after 360
minutes (`bootstrap/ec2/gibson/envs/drill.tfvars`), so a node that a dead run
leaves cannot bill for long.

**Certificates.** Let's Encrypt issues at most 5 certificates for one exact
set of names in 7 days. A drill that asks for a new edge certificate on
each recreate, run once a day, uses that limit in 5 days. The drill reached it on 2026-10-12.
So:

1. The teardown keeps the edge certificate in the Secrets Manager secret
   `zeroroot-ai/<env>/edge-tls` (stage 0, `substrate/gibson-bootstrap/edge-cert.tf`).
2. The next bringup writes it back before Argo CD syncs the platform. It does
   this only when the certificate has more than 30 days left and names the
   hosts that the overlay asks for (`scripts/lib/edge-cert.sh`).
3. cert-manager keeps a valid certificate and asks Let's Encrypt for nothing.

The drill names its edge hosts in `gitops/envs/drill/values.yaml`
(`certManager.envoyEdge.dnsNames`). Staging and prod leave the names to the
chart, so their bringup does not restore the certificate yet. Each of their
recreates asks for one new certificate. With the kept certificate, the drill
asks for a new one about once every 60 days.

## Promotion, and what proves prod runs what staging tested

A promotion is a one-line bump of the OCI `targetRevision` in
`gitops/envs/<env>/gibson.yaml`, staging first, then the same version to prod
(ADR-0080). `gitops/chart-digests.yaml` records the registry digest each
pinned version resolved to when it was admitted, and whether
`zeroroot-ai/charts` signed it. Record a version with:

```sh
gitops/scripts/verify-chart-signature.sh --record 0.128.0
```

Never hand-edit a digest. Three guards hold the rule (hosted#116, launch
blocker 5):

- `make check-promotion` runs in the merge gate. Every guard proves it can
  still fail, then `check-promotion-order.py` refuses a pin the ledger does
  not record and a prod pin ahead of staging.
- `make check-promotion-pr` runs on every pull request. A change set moves
  the prod pin only to the version staging pins, and never a pin and its
  `values.yaml` together (gitops#448).
- `exit-test-chart-signing.yml` runs on `main` and on dispatch. It checks the
  order offline, then pulls each pinned version with no token and checks that
  the tag still resolves to the recorded digest and that the digest carries
  the `zeroroot-ai/charts` cosign signature.

Run a promotion with the workflows. `promote-bump` opens the one-line PR and
records the digest. `promote-staging` proves the version on a real staging and,
on a green smoke, dispatches the prod bump itself (ADR-0080):

```sh
gh workflow run promote-bump.yml    -f env=staging -f chart_version=0.128.0
gh workflow run promote-staging.yml -f chart_version=0.128.0
```

Never move the prod pin by hand. `promote-bump` with `env=prod` is the only
path, and `check-prod-promotion.sh` refuses any other version.

A pin bump never changes `values.yaml` (`check-promotion-isolation.sh`). When
the new chart reads a key that an env must set, that value lands in the PR
right after the pin bump. Merge that values PR next. Until it merges,
`check-promotion-pr` fails each other PR. The belief trainer image
(`gibson-operators.tenantOperator.beliefTrainer.image`, gibson#31) is one such
key: `check-overlay-belief-trainer.py --base` fails a change set that leaves it
unset while the pinned chart reads it. The recreate verbs copy the pinned
digest into the ECR repository of the env (`scripts/belief-trainer-image.sh`).

## Signup, and what proves a customer can get in

`exit-test-signup.yml` (hosted#122) stands the baseline
profile up on kind with `make recreate ENV=kind`, the CI rung, and one overlay,
`test/signup/values.yaml`, that swaps the profile's non-delivering `log` mail
transport for the chart's Mailpit sink. A browser then signs up with a fresh
address, reads the verification mail from Mailpit, follows the link, sets a
password, and the test asserts the Tenant reaches Ready and its founding
member reaches Active. The same run proves the gate can refuse: completion
without verification, a forged token and a reused token must all bounce.

`make check-signup-exit-test` runs the offline guards in the merge gate. Run the
drill by hand against a kind cluster you stood up with that overlay:

```sh
npm --prefix test/signup install && npx --prefix test/signup playwright install --with-deps chromium
bash test/signup/exit-test-signup.sh
```

## Where the charts come from

`CHARTS_ROOT` points at a checkout of `zeroroot-ai/charts`, defaulting to a
sibling directory:

```sh
git clone git@github.com:zeroroot-ai/charts.git ../charts
make recreate ENV=kind
```

The kind inner loop deliberately allows an **unreleased** checkout, because
forcing a chart release into a loop run dozens of times a day costs more than it
buys.

The baseline install exit test is that inner loop on a runner. It lives in
`charts` (`exit-test-baseline-install.yml`, charts#472), because it tests the
chart source. hosted holds no copy.

The merge is the gate for the released path. Each environment overlay pins a
**published** chart version, so no environment runs a chart that a customer
cannot get.
