# eks/apex-zone

The `zeroroot.ai` apex hosted zone and its mail records. Permanent.

Decisions: ADR-0083 (the
substrate contract), `CONTEXT.md` "Apex zone" and "SMTP relay". Issue:
deploy#1741.

## In plain words

The company's domain, and the DNS records that make its mail work, belong to
the company. They do not belong to an environment. Before this workspace the
prod estate created them and a `prevent_destroy` flag was the only thing that
kept a teardown from deleting the mail records. This workspace owns them
instead, and no teardown can reach it.

## Why it is under `eks/`

Every Terraform root in this repo lives under `eks/`, including the two other
roots that are not environments: `eks/aws-org` (the Organization) and
`eks/public-site` (the marketing site). The CI `fmt` and `validate` jobs and
the `exit-test-terraform.yml` path filter key on `eks/`. A new top-level
directory would need its own wiring and would separate this root from the
roots it resembles most.

## What it owns

| Resource | Live value |
|---|---|
| hosted zone `zeroroot.ai.` | the live zone id. `scripts/apex-zone-id.sh` prints it, and `make apex-zone-plan` and the exit test both read it that way. It is never committed. |
| `zeroroot.ai MX` | `1 smtp.google.com.` (Google Workspace inbound) |
| `zeroroot.ai TXT` | `v=spf1 include:_spf.google.com include:amazonses.com ~all` |
| `google._domainkey.zeroroot.ai TXT` | the Google Workspace DKIM key, selector `google` |
| SES domain identity `zeroroot.ai`, us-east-1 | verified, Easy DKIM signing |
| SES domain identity `zeroroot.ai`, us-east-2 | verified, Easy DKIM signing, the production sending region |
| six `<token>._domainkey.zeroroot.ai CNAME` | one per Easy DKIM token, three per identity |

The DKIM CNAMEs are derived from the identities. A key rotation on the SES
side shows up as a plan here, never as silent drift.

## What it does not own

- Application records (`app.`, `api.`, `www.`, `docs.`, the apex `A`/`AAAA`
  aliases) and their ACM validation CNAMEs. Those are environment property or
  belong to `eks/public-site`.
- The `staging.zeroroot.ai NS` delegation record. Stage 0 of the environment
  that owns the sub-zone writes it (`eks/gibson-bootstrap`, deploy#1742). It
  is the one record an environment writes into the apex.
- The SES email-address identity `sales@zeroroot.ai` in us-east-1. It is not
  a DNS record and no code in this repo declares it.

## Not declared, because it does not exist live

- A `_dmarc.zeroroot.ai TXT` record.
- A MAIL FROM domain (`mail.zeroroot.ai`) with its MX and SPF records.

Both are deliverability records the relay owner should publish. This
workspace was imported with an empty plan and applies nothing on its own.
Adding either is a change to live company mail and is an owner decision.

The zone's tags still name the workspace that created it
(`Workspace = zeroroot-ai-prod`, `Environment = prod`). Changing them is a
change to the live zone. They stay until an owner decides otherwise.

## Permanent, and how that differs from the retain machinery

This is the one workspace in this repo that is meant to outlive everything,
so it carries the one `prevent_destroy` that stays. ADR-0083 deletes every
other `prevent_destroy`, every `state rm` in a pre-destroy script, every
`teardown:keep` tag and `eks-import-persistent.sh`. Those were retain flags on
an ephemeral estate: a destroy was expected, and the flag was there to make
one resource survive it. Here no destroy is expected at all. The guard and the
intent agree.

There is no destroy target. `scripts/check-apex-zone-ownership.py` fails the
build on any `terraform destroy` of this workspace in the Makefile, a workflow
or a bringup script.

## State

The prod backend from `eks/gibson-bootstrap` (envs/prod), key
`apex-zone/terraform.tfstate`. The key is not env-prefixed because there is
one apex and one state for it.

```bash
make apex-zone-init     # terraform init against the prod backend
make apex-zone-plan     # read-only, -detailed-exitcode, must exit 0
```

Or by hand:

```bash
terraform -chdir=eks/apex-zone init \
  -backend-config="bucket=zeroroot-ai-prod-tfstate-<account-id>-us-east-1" \
  -backend-config="dynamodb_table=zeroroot-ai-prod-tf-locks" \
  -backend-config="kms_key_id=alias/zeroroot-ai-prod-tf-bootstrap"
terraform -chdir=eks/apex-zone plan -lock=false -detailed-exitcode
```

## The import

`imports.tf` holds an `import` block for the zone, every record and both
identities. The import ran on 2026-09-01 as an apply whose plan was
`12 to import, 0 to add, 0 to change, 0 to destroy`, and a fresh plan after it
was empty. The blocks stay in the code. On a state that already holds a
resource they are no-ops. On a lost state they re-import instead of creating a
second zone.

Imported, by Terraform address:

```
aws_route53_zone.apex
aws_route53_record.mx
aws_route53_record.spf
aws_route53_record.google_dkim
aws_sesv2_email_identity.virginia
aws_sesv2_email_identity.ohio
aws_route53_record.ses_dkim_virginia["<dkim-token>"]
aws_route53_record.ses_dkim_virginia["<dkim-token>"]
aws_route53_record.ses_dkim_virginia["<dkim-token>"]
aws_route53_record.ses_dkim_ohio["<dkim-token>"]
aws_route53_record.ses_dkim_ohio["<dkim-token>"]
aws_route53_record.ses_dkim_ohio["<dkim-token>"]
```

## Changing a mail record

1. Get the owner's decision. Mail is company property.
2. Change the code. Never change the zone in the console to match the code.
3. `make apex-zone-plan`. Read every line.
4. `terraform -chdir=eks/apex-zone apply`. There is no make target for this
   on purpose.
5. `make apex-zone-plan` again. It must exit 0.

## If `exit-test-terraform.yml` reports a non-empty plan

Exit code 2 from the `apex-zone plan is empty` job means the live zone and the
code disagree. Read the plan log artifact. If a human changed the zone, the
code is behind: import or declare what changed so the code matches reality.
If the code changed and nobody applied it, that apply is step 4 above and
needs the owner. Never apply to make the exit test green.

## If `eks/gibson` state still holds one of these

No live state does today: prod's state is empty and staging's DNS resources
were swept on 2026-09-01. If a future `terraform state list` in `eks/gibson`
shows any of the addresses below, remove them from that state. They are owned
here, and a `terraform destroy` of that environment would otherwise delete
company mail.

```bash
terraform -chdir=eks/gibson state rm \
  'module.route53.aws_route53_zone.this' \
  'module.route53.aws_route53_record.mx[0]' \
  'module.route53.aws_route53_record.spf[0]' \
  'module.route53.aws_route53_record.dkim["google"]' \
  'module.ses.aws_ses_domain_identity.this' \
  'module.ses.aws_ses_domain_dkim.this' \
  'module.ses.aws_route53_record.dkim[0]' \
  'module.ses.aws_route53_record.dkim[1]' \
  'module.ses.aws_route53_record.dkim[2]'
```

## Guards

- `scripts/check-apex-zone-ownership.py` (CI job `apex-zone-guard`, on every
  PR): no mail record, no SES identity and no hosted zone of any shape in
  `eks/gibson`; no `terraform destroy` of this workspace or of
  `eks/gibson-bootstrap` anywhere; the zone here carries `prevent_destroy`.
  Its `--selftest` rejects seven fixtures first.
- `exit-test-terraform.yml`, job `apex-zone plan is empty` (on `main` and
  daily, never on a PR): `terraform plan -detailed-exitcode` on this workspace
  exits 0.

## CI access

The exit-test job assumes `eks-plan-readonly` (`eks/aws-org/github-oidc.tf`),
the same role as the `eks/gibson` plan. `ReadOnlyAccess` covers `route53:Get*`,
`route53:List*` and `ses:Get*`, `ses:List*` (SESv2 actions share the `ses:`
prefix), and the role's `kms:Decrypt` via S3 reads the state object. The plan
runs with `-lock=false`, so the lock table is never touched. No policy was
widened.
