# eks/public-site

The public web surfaces, served from S3 behind CloudFront, outside every cluster.

See ADR-0077.

## In plain words

`www.zeroroot.ai` and `docs.zeroroot.ai` are files. They do not need a server
and they do not need a cluster. This workspace serves them from object storage,
so they stay up when the estate is torn down.

## Two rules that are easy to get wrong

**This root has no Environment.** Every other root here is forked into staging
and prod, and `Environment` in this repo means staging, drill or prod. The public
surfaces are production-only singletons — there is no staging marketing site.
Do not add an `envs/` directory.

**Do not move this into `eks/gibson`.** That root is full-ephemeral
(ADR-0083): a teardown
deletes everything in it. The marketing site would be destroyed on every
teardown, which is the exact failure this workspace exists to prevent.

## This is not the voided CloudFront

CloudFront was dropped as the **customer-traffic edge** on 2026-08-15 — a
distribution in front of Envoy, terminating API traffic, needing shared-secret
origin verification. That was deleted in deploy#1606 and deploy#1608 and stays
deleted.

This is object-storage delivery. It shares a product name with the voided thing
and nothing else. Do not delete it on sight.

## Usage

```bash
terraform -chdir=eks/public-site init \
  -backend-config="bucket=zeroroot-ai-<env>-tfstate-<account-id>-us-east-1" \
  -backend-config="dynamodb_table=zeroroot-ai-<env>-tf-locks" \
  -backend-config="kms_key_id=alias/zeroroot-ai-<env>-tf-bootstrap"

terraform -chdir=eks/public-site plan
terraform -chdir=eks/public-site apply
```

The state bucket and lock table come from `eks/gibson-bootstrap` and carry
`prevent_destroy`, so they survive teardown — which is the property this
workspace needs. The state key is not env-prefixed: there is one public-site
state, ever, whichever env's bucket holds the object.

## Region

`us-east-1`, enforced by a variable validation. CloudFront reads its ACM
certificates from that region only, and the org SCP pins everything there
anyway.

The region-pinning SCP allow-list
(`eks/aws-org/policies/deny-regions-except-us-east-1.json`) already names
`cloudfront` as a permitted global service. **Do not remove that entry** — this
workspace's own apply is denied by our own guardrail without it.

## Teardown

`eks-post-destroy-verify.sh` counts what is *in the account*, not what
Terraform thinks it created
(ADR-0070). It recognizes this
workspace by service (CloudFront, S3, ACM) and by the `www-*` name of the lead
path's Lambda, API, SNS topic and log group, in `arn_retained()`. No tag
exempts a resource: the resources of this workspace carry no retain tag
(hosted#411), and `scripts/check-no-retain.py` fails when one comes back.

If you add a resource of a new service to this workspace, add its service or
its `www-*` name to `arn_retained()` with a justification, or the teardown
gate goes red.

## Serving model

The bucket is private and is never an S3 website endpoint. Website hosting only
speaks HTTP and cannot be reached by an Origin Access Control, so the bucket
would have to be world-readable and the CDN would become advisory — anyone
could fetch the origin directly. REST origin plus OAC keeps the only public
door on CloudFront.

Because a REST origin does no index resolution, one CloudFront Function appends
`index.html` to directory requests. That is the **only** rewrite in this design.
Everything else the sites need is baked into their exports (see docs-site#56) —
a rule that lives only at the edge means the same bytes are broken everywhere
else, which is the defect that made the docs export container-only.

Unknown paths answer **404**, not 200 with the home page. A stale link must read
as "that page does not exist", not "the site is serving the wrong thing".

## What is here, and what is next

| Surface | Status |
|---|---|
| `docs.zeroroot.ai` | live |
| `www.zeroroot.ai` | live |
| `zeroroot.ai` apex → `www` | live, 301 from the edge function |
| `/api/contact-sales` Lambda + SNS | next, a second origin on the `www` distribution |

The apex is an **alias on the www distribution**, not a distribution of its
own. The edge function 301s any non-canonical host to `www`, so the apex costs
no extra distribution, certificate or redirect bucket.

Alias records are written with `allow_overwrite = true`. `external-dns` wrote
records for these hostnames from inside the cluster; the cluster is gone but
its records remain, aliased to load balancers that no longer exist. A plain
create fails with "already exists" and leaves the hostname pointing at nothing.
Terraform owns these names now.

The GitHub OIDC publish role lives in `eks/aws-org` with the other GitHub
roles, and consumes this workspace's bucket and distribution ARNs.

## Wiring the publish role

`eks/aws-org` holds the `public-site-publish` OIDC role (owner call
2026-08-18). It is gated on being told which buckets and distributions it may
touch, so after an apply here, feed these outputs into that workspace's
`terraform.tfvars`:

```hcl
public_site_bucket_arns = [
  "arn:aws:s3:::zeroroot-ai-www-site-<account-id>",
  "arn:aws:s3:::zeroroot-ai-docs-site-<account-id>",
]
public_site_distribution_arns = [
  "arn:aws:cloudfront::<account-id>:distribution/<www-id>",
  "arn:aws:cloudfront::<account-id>:distribution/<docs-id>",
]
```

Get them with `terraform -chdir=eks/public-site output`. Then set the role ARN
from `terraform -chdir=eks/aws-org output public_site_publish_role_arn` as the
`PUBLISH_ROLE_ARN` repository variable in `www` and `docs-site`.

The role only trusts **tag** refs and only the single `publish-site.yml` file in
each repo, so a push to `main` cannot reach the buckets.

## The staging documentation surface

`docs.staging.zeroroot.ai` is served here too, since 2026-09-22 (ADR-0095).
Staging must be able to read a docs build that is not released yet, and the one
live site cannot show it. Serving the documentation from the staging cluster
would put a chart back in front of a surface ADR-0077 took out of every chart,
so it is a second small surface in this workspace: its own bucket, its own
distribution, the same module.

It is not an environment fork. There is still no `envs/` directory here and
there never should be. There is still no staging marketing site.

It reads the delegated sub-zone `staging.zeroroot.ai`, which staging's stage 0
creates, and its certificate name validates in that zone rather than the apex.
A plan before staging's stage 0 has run fails on the zone lookup.

The publish side is a follow-up in `zeroroot-ai/docs-site`: a pre-release build
syncs into `docs_staging_bucket_name` and invalidates
`docs_staging_distribution_id`, both of which this root outputs.
