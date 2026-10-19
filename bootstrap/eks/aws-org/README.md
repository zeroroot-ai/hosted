# aws-org workspace

This workspace owns the AWS Organizations topology, SCPs, IAM Identity
Center permission sets, the cross-account `ZeroDayAIProdAdmin` role into
`zeroroot-ai-prod`, the org-wide CloudTrail destination bucket, the security
findings bucket, the GitHub Actions OIDC trust, and the workspace's own
state bucket / lock table.

It runs from `zeroroot-ai-mgmt`. Its blast radius is the Organization itself.

---

## Live topology (deploy#696, ADR-0073 — read before planning)

The bootstrap flow below describes a from-scratch org. The **live**
deployment predates the zeroroot rebrand and does NOT match the
defaults:

- Org `o-xxxxxxxxxx`, management account **000000000000** ("Zero Day AI").
- Workload account **000000000000** ("Zero Root AI") — a *member* of that
  org, sitting under the org **root** (deliberately NOT the SCP-attached
  `workload` OU; see the `ignore_changes` note on
  `aws_organizations_account.prod` in `main.tf`). Staging and prod
  co-tenant here per ADR-0073; `prod_account_id = "000000000000"`.
- The old vended account 931609664535 is SUSPENDED (closed); it auto-leaves
  the org after the post-closure window. Its IAM resources are gone and
  were dropped from state.
- Mgmt-account resource names carry the legacy prefixes. The operator
  `terraform.tfvars` (gitignored) MUST set, in addition to the variables in
  `terraform.tfvars.example`:

  ```hcl
  prod_account_id               = "000000000000"
  prod_account_name             = "Zero Root AI"
  prod_account_email            = "aws-prod@example.com"   # the live account root address
  mgmt_name_prefix              = "zero-day-ai-mgmt"
  findings_bucket_name_prefix   = "zero-day-ai-prod"
  cloudtrail_bucket_name_prefix = "gibson-org"
  ```

- Backend (matches `.terraform/terraform.tfstate` after init):

  ```bash
  terraform init \
    -backend-config="bucket=zero-day-ai-mgmt-tfstate-000000000000-us-east-1" \
    -backend-config="dynamodb_table=zero-day-ai-mgmt-tf-locks" \
    -backend-config="kms_key_id=alias/zero-day-ai-mgmt-tf-state"
  ```

Re-homing prod into its own account/org is an explicit future migration
(ADR-0073 "Considered options"), not something this workspace does.

---

## Prerequisites

1. `zeroroot-ai-mgmt` and `zeroroot-ai-prod` AWS account roots provisioned with
   hardware MFA per `runbooks/RUNBOOK-account-bootstrap.md`. **This is
   manual; do not skip.**

2. The operator running this workspace has hardware-MFA-protected sign-in
   to `zeroroot-ai-mgmt` with permissions to manage Organizations, Identity
   Center, IAM, CloudTrail, S3, KMS. On first apply they sign in as root;
   thereafter as an Identity Center user with administrator permission set.

3. `aws` CLI v2, Terraform >= 1.6, jq.

---

## Apply order

The workspace is applied ONCE on bootstrap. Subsequent applies are rare
(SCP edits, new permission sets, new SCP-attached OUs).

```text
1. aws_organizations_organization        (creates the org)
2. aws_organizations_organizational_unit (workload OU)
3. aws_organizations_account             (zeroroot-ai-prod account; AWS emails the
                                          root password to var.prod_account_email)
4. SCPs                                  (attach to workload OU)
5. IAM Identity Center permission sets   (no upstream IdP; users seeded
                                          manually post-apply via console)
6. CloudTrail org trail + bucket
7. State bucket + lock table             (used by THIS workspace's backend
                                          after the local→s3 migration)
8. Security findings bucket
9. (second apply) cross-account roles + GitHub OIDC roles
   — these depend on var.prod_account_id which is populated AFTER step 3
```

The ordering is enforced by `depends_on` references between the resources;
operators run a single `terraform apply` per round.

---

## Bootstrap (local-backend → s3-backend dance)

Because this workspace creates its own state bucket, the very first apply
must use a local backend. After the bucket exists we migrate state into
it.

### Step 1 — first apply (local backend)

`backend.tf` ships with the `backend "s3"` block commented out. Leave it.

```bash
cd enterprise/deploy/eks/aws-org/

cp terraform.tfvars.example terraform.tfvars   # then fill in
# Required: prod_account_email
# Leave prod_account_id empty on first apply

terraform init
terraform plan -out=plan.out
terraform apply plan.out
```

This creates the org, the workload OU, the zeroroot-ai-prod member account, the
SCPs, Identity Center permission sets, CloudTrail, state bucket + lock
table, security findings bucket. Local state lives in `terraform.tfstate`.

### Step 2 — capture outputs

```bash
terraform output prod_account_id
terraform output state_bucket_name
terraform output state_lock_table_name
```

Note the values. The `prod_account_id` feeds the second apply; the bucket
and table feed the backend migration.

### Step 3 — uncomment the s3 backend

Edit `backend.tf` and uncomment the `terraform { backend "s3" { ... } }`
block.

### Step 4 — migrate state

```bash
terraform init -migrate-state \
  -backend-config="bucket=$(terraform output -raw state_bucket_name)" \
  -backend-config="dynamodb_table=$(terraform output -raw state_lock_table_name)" \
  -backend-config="kms_key_id=$(terraform output -raw state_kms_key_arn)"
```

Confirm with `yes` when prompted. Then:

```bash
rm terraform.tfstate terraform.tfstate.backup
terraform plan
```

The plan must report zero changes. If it does not, restore the local state
file (you kept a copy, right?) and investigate.

### Step 5 — second apply with prod_account_id populated

Add `prod_account_id = "<12-digit-id>"` to `terraform.tfvars`. Then:

```bash
terraform plan -out=plan.out
terraform apply plan.out
```

This adds the `aws.prod`-aliased resources — the `ZeroDayAIProdAdmin` and
`ZeroDayAIProdReadOnly` cross-account roles, the operator permission boundary,
and the GitHub Actions OIDC IdP + tf-plan/tf-apply roles in `zeroroot-ai-prod`.

### Step 6 — verify SCPs attached

```bash
WORKLOAD_OU_ID=$(terraform output -raw workload_ou_id) \
  ./scripts/verify-scp-attached.sh
```

Must exit 0.

### Step 7 — declare Identity Center users in Terraform

Operators are declared in IaC, not the console. Add an entry per operator to
the `users` list in `terraform.tfvars` (see `terraform.tfvars.example`):

```hcl
users = [
  {
    given_name      = "Ada"
    family_name     = "Lovelace"
    email           = "ada.lovelace@example.com"
    permission_sets = ["ZeroDayAIProdAdmin", "BillingViewer"]
  },
]
```

Then apply:

```bash
terraform plan -out=plan.out
terraform apply plan.out
```

This creates an `aws_identitystore_user` per operator and an
`aws_ssoadmin_account_assignment` for each listed permission set against the
zeroroot-ai-mgmt management account (operators then cross-account assume-role
into zeroroot-ai-prod). Valid `permission_sets` values are `ZeroDayAIProdAdmin`,
`ZeroDayAIProdReadOnly`, and `BillingViewer`.

Onboarding a new operator is now a Terraform PR — append one entry and apply.
The resources live in `modules/identity-center`; the permission sets they
reference are owned by `identity-center.tf`. Documented in
`runbooks/RUNBOOK-account-bootstrap.md` Phase 5.

### Step 8 — manual MFA-delete on state and CloudTrail buckets

Terraform cannot enable MFA-delete (the API requires an MFA code in the
request body). The account root user must run:

```bash
# As root in zeroroot-ai-mgmt, with hardware MFA assembled:
aws s3api put-bucket-versioning \
  --bucket $(terraform output -raw state_bucket_name) \
  --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "<root-mfa-serial> <code>"

aws s3api put-bucket-versioning \
  --bucket $(terraform output -raw cloudtrail_bucket_name) \
  --versioning-configuration Status=Enabled,MFADelete=Enabled \
  --mfa "<root-mfa-serial> <code>"
```

---

## Files

| File | Owns |
|------|------|
| `versions.tf` | Provider + Terraform version constraints |
| `providers.tf` | Default provider + `aws.prod` alias |
| `backend.tf` | Backend (commented out for first apply) |
| `variables.tf` | Inputs |
| `locals.tf` | Common tag set |
| `main.tf` | Org + workload OU + zeroroot-ai-prod account |
| `outputs.tf` | Outputs feeding bootstrap + downstream workspaces |
| `scps.tf` | The two SCPs and their attachments |
| `policies/deny-root-user.json` | Root user denial |
| `policies/deny-regions-except-us-east-1.json` | Region pinning |
| `policies/permission-boundary-operator.json` | PB-OperatorMaxPermissions body |
| `identity-center.tf` | Three permission sets + SSO instance lookup |
| `modules/identity-center/` | Operator users + permission-set assignments (sourced from `users` var) |
| `cross-account-roles.tf` | ZeroDayAIProdAdmin / ReadOnly in zeroroot-ai-prod |
| `cloudtrail.tf` | Org trail + KMS key |
| `cloudtrail-bucket.tf` | CloudTrail destination bucket |
| `state-bucket.tf` | This workspace's own state backend |
| `findings-bucket.tf` | Security findings (GuardDuty) bucket in mgmt |
| `github-oidc.tf` | GitHub Actions OIDC IdP + tf-plan / tf-apply roles |
| `scripts/verify-scp-attached.sh` | Operator check: assert both SCPs on the workload OU |
| `runbooks/RUNBOOK-account-bootstrap.md` | Manual operator account-creation procedure |

---

## Rollback

`aws_organizations_organization` cannot be `terraform destroy`'d cleanly —
AWS does not allow programmatic deletion of an organization. Closing the
zeroroot-ai-prod account is a 90-day irreversible operation that requires
console action.

Rollback steps if a bad SCP attachment locks the workload OU out of a
required action:

1. From zeroroot-ai-mgmt root (NOT an Identity Center session — root is exempt
   from SCPs at the org root level), navigate to **Organizations → Policies
   → Service control policies → <bad-policy>**, click **Targets**, and
   detach from the workload OU.
2. Open a PR reverting the SCP change.
3. Re-apply.

For state corruption recovery, see the standard Terraform-state-recovery
runbook.

---

## References

- AWS Organizations: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_introduction.html
- IAM Identity Center: https://docs.aws.amazon.com/singlesignon/latest/userguide/getting-started.html
- Spec: `.spec-workflow/specs/production-eks-deploy/design.md` (Component 1)
- Spec: `.spec-workflow/specs/production-eks-deploy/requirements.md` (R0.*, R12.*, R13.*)
