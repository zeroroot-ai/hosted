# ----------------------------------------------------------------------------
# Input variables for the aws-org workspace.
# ----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for region-bound resources (CloudTrail bucket, state bucket). Pinned to us-east-1 per the DenyRegionsExceptUSEast1 SCP."
  type        = string
  default     = "us-east-1"
}

variable "prod_account_email" {
  description = "Root email alias for the zeroroot-ai-prod member account. Must be reachable by the shared ops mailbox before apply (the AWS account-creation email lands here)."
  type        = string
}

variable "prod_account_name" {
  description = "Display name for the zeroroot-ai-prod member account."
  type        = string
  default     = "zeroroot-ai-prod"
}

variable "prod_account_id" {
  description = "AWS account ID of zeroroot-ai-prod after Organizations creates it. Empty on first apply; populated on second apply once aws_organizations_account.prod outputs the ID. Setting this enables the prod-aliased provider for cross-account-role provisioning."
  type        = string
  default     = ""
}

variable "github_org" {
  description = "GitHub organization owning the gitops repo. Used in the github-oidc trust policies."
  type        = string
  default     = "zeroroot-ai"
}

variable "github_gitops_repo" {
  description = "GitHub repository name that carries the Argo tree and the Terraform CI workflow. That was the gitops repo until 2026-09-04 (ADR-0086); it is hosted now."
  type        = string
  default     = "hosted"
}

variable "github_deploy_repo" {
  description = "GitHub repository name that carries the bringup verb workflows, which assume the eks-bringup and eks-plan-readonly OIDC roles. That was the deploy repo until 2026-09-04 (ADR-0086); it is hosted now."
  type        = string
  default     = "hosted"
}

variable "github_apply_environment" {
  description = "GitHub Environment name in the gitops repo that tf-apply-privileged is gated on (deploy#1198). A job must declare `environment: <this>` to assume the role. Configure required reviewers + a main-only deployment branch rule on that Environment in GitHub — the approval gate itself is a repo setting Terraform cannot create."
  type        = string
  default     = "aws-prod-apply"
}

variable "github_bringup_environments" {
  description = "GitHub Environment names in the deploy repo that the eks-bringup role is gated on (deploy#1198, deploy#1746). One per environment a bringup verb may target, and each must match the `environment:` a verb job declares, or the workflow can no longer assume the role. prod carries the required reviewer; staging carries none (docs/bringup.md § Who may run what). drill is never one: drill.yml runs as drill-bringup (github-oidc-drill.tf), whose boundary takes away every resource of staging and prod. scripts/check-role-callers.py fails when this list names drill."
  type        = list(string)
  default     = ["staging", "prod"]
}

variable "drill_zone_name" {
  description = "The DNS sub-zone of drill. drill-bringup may change records only inside it (github-oidc-drill.tf)."
  type        = string
  default     = "drill.zeroroot.ai"
}

variable "platform_workspace_names" {
  description = "Workspace names under eks/ that stand up a platform S3 bucket set in the member account. Used to reconstruct the audit-bucket ARNs for the CloudTrail S3 data-event selector (deploy#1200). Must match the workspace_name passed to modules/s3 by each eks/<workspace>/main.tf — add an entry when a new workspace is added, or its audit-bucket writes and deletes go unlogged."
  type        = list(string)
  default     = ["zeroroot-ai-prod", "zeroroot-ai-staging"]
}

variable "alerts_email_address" {
  description = "Email destination for AWS Budgets cost alerts. Subscribed to the per-budget SNS topic."
  type        = string
  default     = "alerts@zeroroot.ai"
}

variable "cloudtrail_bucket_name_prefix" {
  description = "Prefix for the org-wide CloudTrail destination bucket. Bucket name is composed as '<prefix>-cloudtrail-<mgmt_account_id>-<aws_region>'. Default is the canonical 'zeroroot-ai-mgmt'. The existing mgmt account 111111111111 was bootstrapped with the legacy literal 'gibson-org'; that account's terraform.tfvars overrides this variable to preserve the existing bucket (S3 buckets cannot be renamed in place, and the bucket holds the HIPAA-mandated 6-year audit trail). Fresh bootstraps in a clean mgmt account take the default and get the canonical name. Tracked at deploy#372."
  type        = string
  default     = "zeroroot-ai-mgmt"
}

variable "mgmt_name_prefix" {
  description = "Prefix for the mgmt-account resources this workspace owns whose names cannot be changed in place: the state bucket ('<prefix>-tfstate-<mgmt_account_id>-<region>'), the state lock table ('<prefix>-tf-locks'), and the KMS aliases ('alias/<prefix>-tf-state', 'alias/<prefix>-cloudtrail', 'alias/<prefix>-findings'). Default is the canonical 'zeroroot-ai-mgmt'. The live mgmt account 103942587048 was bootstrapped with the legacy 'zero-day-ai-mgmt' prefix; its operator terraform.tfvars overrides this variable to preserve the live resources (S3 buckets and DynamoDB tables cannot be renamed, and the state bucket/KMS alias back THIS workspace's s3 backend). Same preserve-the-live-name pattern as cloudtrail_bucket_name_prefix (deploy#372). Tracked at deploy#696."
  type        = string
  default     = "zeroroot-ai-mgmt"
}

variable "findings_bucket_name_prefix" {
  description = "Prefix for the security-findings bucket ('<prefix>-security-findings-<mgmt_account_id>-<region>'). Default is the canonical 'zeroroot-ai-prod'. The live mgmt account 103942587048 was bootstrapped with the legacy 'zero-day-ai-prod' prefix; its operator terraform.tfvars overrides this variable to preserve the live bucket (same rename-in-place constraint as cloudtrail_bucket_name_prefix / deploy#372). Tracked at deploy#696."
  type        = string
  default     = "zeroroot-ai-prod"
}

variable "users" {
  description = <<-EOT
    IAM Identity Center operator users and the permission sets each is assigned
    against the management account. Consumed by modules/identity-center.

    Each entry:
      - given_name:      operator first name.
      - family_name:     operator last name.
      - email:           primary email; also the unique Identity Center user_name.
      - permission_sets: list of permission-set names assigned against
                         zeroroot-ai-mgmt. Valid values are the keys wired in
                         main.tf's identity_center module block:
                         "ZeroDayAIProdAdmin", "ZeroDayAIProdReadOnly",
                         "BillingViewer". Operators cross-account assume-role
                         into zeroroot-ai-prod from these sessions.

    Onboarding a new operator is a one-line append here (in terraform.tfvars)
    plus `terraform apply` — no console clicks (deploy#539). Defaults to empty
    so the first apply provisions the permission sets before operators exist;
    populate on the assignment apply.
  EOT
  type = list(object({
    given_name      = string
    family_name     = string
    email           = string
    permission_sets = optional(list(string), [])
  }))
  default = []
}

# NOTE: ArgoCD ops SSO no longer runs through Identity Center. It moved to a
# pluggable github|gitlab|oidc Dex connector configured per-cluster in
# bootstrap/modules/argocd (reworks deploy#1332). The former
# aws_identitystore_group.argocd_admins and its argocd_admin_group_name /
# argocd_admin_emails vars are gone with identity-center-argocd-sso.tf; admin
# is now granted by the provider's own group (e.g. the zeroroot-ai GitHub
# team). See eks/aws-org/runbooks/RUNBOOK-argocd-sso.md.

variable "github_www_repo" {
  description = "GitHub repository name for the marketing site. Its publish workflow assumes the public-site-publish OIDC role."
  type        = string
  default     = "www"
}

variable "github_docs_repo" {
  description = "GitHub repository name for the documentation site. Its publish workflow assumes the public-site-publish OIDC role."
  type        = string
  default     = "docs-site"
}

variable "public_site_bucket_arns" {
  description = "S3 bucket ARNs the publish role may write, from eks/public-site outputs (www + docs). Empty disables the role entirely — the trust policy and the grant are provisioned together or not at all."
  type        = list(string)
  default     = []
}

variable "public_site_distribution_arns" {
  description = "CloudFront distribution ARNs the publish role may invalidate, from eks/public-site outputs (www + docs)."
  type        = list(string)
  default     = []
}
