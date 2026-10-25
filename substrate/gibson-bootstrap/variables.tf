variable "aws_region" {
  description = "Region of the durable bucket, the SES SMTP endpoint and the IAM users. us-east-1 per the DenyRegionsExceptUSEast1 SCP."
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "The account this environment lives in. A precondition compares it with the caller's account, so a wrong AWS_PROFILE is a plan-time error and never a bucket in the wrong account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit account id."
  }
}

# ----------------------------------------------------------------------------
# Env axis. Supplied by envs/<env>.tfvars, no defaults: every resource here is
# named after the env, and a defaulted env would provision the wrong one.
# ----------------------------------------------------------------------------

variable "environment" {
  description = "Which environment this stage 0 serves. Names the bucket, the IAM users and the Environment tag."
  type        = string

  validation {
    # drill is the throwaway environment of ADR-0095. hosted#373 taught
    # substrate.sh to accept it and left this rule behind, so `make substrate
    # ENV=drill` planned cleanly and then refused at the variable. Two places
    # name the allowed environments and only one of them moved.
    condition     = contains(["staging", "prod", "drill"], var.environment)
    error_message = "environment must be staging, prod or drill."
  }
}

variable "cost_center" {
  description = "Value of the CostCenter tag. Cost Explorer groups by it."
  type        = string
}

# ----------------------------------------------------------------------------
# DNS. Only the zone name decides the shape: a sub-zone env gets a hosted
# zone and one NS record in the apex; an apex env's zone IS the apex and this
# workspace creates nothing in DNS.
# ----------------------------------------------------------------------------

variable "apex_zone_name" {
  description = "The company apex zone. Owned by eks/apex-zone, read here as a data source, never created. The NS delegation of a sub-zone is the one record an environment writes into it."
  type        = string
  default     = "zeroroot.ai"
}

variable "zone_name" {
  description = "The environment's DNS zone: <env>.zeroroot.ai for a sub-zone env (staging), zeroroot.ai itself for the apex env (prod)."
  type        = string

  validation {
    condition     = var.zone_name == var.apex_zone_name || endswith(var.zone_name, ".${var.apex_zone_name}")
    error_message = "zone_name must be the apex zone or a child of it. An environment never owns a second apex."
  }
}

# ----------------------------------------------------------------------------
# SMTP relay. The default is SES through its SMTP endpoint in aws_region, with
# an IAM user this workspace creates and a password derived from its access
# key. An operator who brings another relay sets all four, and this workspace
# creates no SMTP user.
# ----------------------------------------------------------------------------

variable "smtp_host" {
  description = "Relay host. Empty means the SES SMTP endpoint of aws_region."
  type        = string
  default     = ""
}

variable "smtp_port" {
  description = "Relay port. 587 is STARTTLS, which SES and the preflight probe both speak."
  type        = number
  default     = 587
}

# ----------------------------------------------------------------------------
# Access key slots (ADR-0171, row substrate-cloud-credentials). Each IAM user
# of credentials.tf has two key slots, a and b. `active` is the slot whose key
# the outputs give, and `keep` is the set of slots that have a key. In steady
# state keep is the active slot alone. scripts/substrate-rotate.sh adds the
# free slot, makes it active, writes the keyring, waits until each consumer
# uses the new key, and then drops the old slot. The file lives in the state
# directory of the environment, next to the keyring: substrate.sh passes
# <state-dir>/key-slots.tfvars.json, and writes it with the default once.
# ----------------------------------------------------------------------------
variable "key_slots" {
  description = "The access key slots of each substrate IAM user: the active slot and the slots that have a key."
  type = map(object({
    active = string
    keep   = set(string)
  }))
  default = {
    platform = { active = "a", keep = ["a"] }
    smtp     = { active = "a", keep = ["a"] }
    dns      = { active = "a", keep = ["a"] }
    # The push credential of the setec disk builder (ecr.tf, D85).
    setec-disk-builder = { active = "a", keep = ["a"] }
  }

  validation {
    condition     = alltrue([for k in ["platform", "smtp", "dns", "setec-disk-builder"] : contains(keys(var.key_slots), k)])
    error_message = "key_slots names the four users platform, smtp, dns and setec-disk-builder."
  }

  validation {
    condition = alltrue([for k, v in var.key_slots :
      contains(v.keep, v.active) && length(setsubtract(v.keep, ["a", "b"])) == 0
    ])
    error_message = "For each user, keep holds only slots a and b, and holds the active slot."
  }
}

variable "smtp_user" {
  description = "Relay user for an operator-supplied relay. Empty means: create the SES SMTP IAM user and use its access key id."
  type        = string
  default     = ""
}

variable "smtp_password" {
  description = "Relay password for an operator-supplied relay. Empty means: derive the SES SMTP password from the created access key. Set it together with smtp_user and smtp_host, never alone."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = (var.smtp_user == "") == (var.smtp_password == "")
    error_message = "smtp_user and smtp_password are set together or not at all."
  }
}

# ----------------------------------------------------------------------------
# Audit retention. S3 object lock has no per-prefix default, so the bucket
# policy makes every write under audit/ carry a lock of at least
# audit_retention_days in audit_lock_mode, and the lifecycle rule expires
# the object after the same number of days, never before.
# ----------------------------------------------------------------------------

variable "audit_lock_mode" {
  description = "GOVERNANCE or COMPLIANCE. COMPLIANCE on prod: no principal, not even the account root, deletes an audit object before its retention ends. GOVERNANCE on staging: the account owner with s3:BypassGovernanceRetention can still empty the bucket when staging is decommissioned."
  type        = string

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.audit_lock_mode)
    error_message = "audit_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "audit_retention_days" {
  description = "Minimum object-lock retention and the lifecycle expiry for audit/. 2192 days is six years including two leap days."
  type        = number
  default     = 2192
}

# The Argo CD GitHub App, for cloning the PRIVATE gitops repo (ADR-0083).
#
# Argo CD's app-of-apps reads its Applications from zeroroot-ai/hosted, which
# is private, so it needs a credential. No API creates or installs a GitHub
# App: an operator makes it in the UI once per organization and records its
# two ids here. Both are PUBLIC identifiers and belong in substrate.env with
# the rest of the environment's facts; the App's private key is a secret and
# lives in the keyring (scripts/keyring.sh, member GITHUB_APP_PRIVATE_KEY).
#
# Empty means the environment's Argo syncs from a public source, which is what
# kind does. preflight refuses a bringup whose Argo would clone a private repo
# with no App: the failure otherwise is stage 2 stalling to its cap with one
# Application and an error nobody reads.
variable "argocd_github_app_id" {
  description = "Argo CD GitHub App id (public). Empty on an env whose Argo needs no credential."
  type        = string
  default     = ""
}

variable "argocd_github_app_installation_id" {
  description = "Argo CD GitHub App installation id (public). Empty on an env whose Argo needs no credential."
  type        = string
  default     = ""
}

variable "inbox_rule_set_name" {
  description = "The one active SES receipt rule set, owned by substrate/apex-zone (hosted#647). This stage adds its own inbox rule to it."
  type        = string
  default     = "zeroroot-ai-inbox"
}

variable "inbox_reader_role_name" {
  description = "The IAM role of the smoke driver: the one principal that reads the test inbox of this environment (hosted#647)."
  type        = string
  default     = "eks-bringup"
}

variable "edge_cert_principal_role_names" {
  description = "The IAM roles that read and write the edge TLS secret of this environment: the bringup role(s) that run the teardown and the recreate (scripts/lib/edge-cert.sh)."
  type        = list(string)
  default     = ["eks-bringup"]
}

variable "keyring_principal_role_names" {
  description = "The IAM roles that read and write the keyring secret: the operator role that runs stage 0 from the workstation. Drill adds its own role drill-bringup. Staging and prod add no role: eks-bringup trusts both of their GitHub environments."
  type        = list(string)
  default     = ["OrganizationAccountAccessRole"]
}

variable "rotation_role_enabled" {
  description = "Make the key rotation role of this environment (rotation-role.tf). True for staging and prod: their access keys rotate in .github/workflows/rotate-credentials.yml. Drill rotates in drill.yml, as the bringup role."
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "The repository whose rotate-credentials.yml workflow may assume the key rotation role."
  type        = string
  default     = "zeroroot-ai/hosted"
}

variable "stage0_state_principal_role_names" {
  description = "The IAM roles besides the rotation role that read and write tfstate/stage0/ of the durable bucket: the operator role that runs stage 0 from the workstation. Drill adds its own role drill-bringup, which rotates its keys in drill.yml."
  type        = list(string)
  default     = ["OrganizationAccountAccessRole"]
}

variable "keyring_reader_role_enabled" {
  description = "Make the keyring reader role of this environment (keyring-reader-role.tf): preflight.yml reads the keyring with it. True for staging and prod."
  type        = bool
  default     = false
}

variable "identity_permissions_boundary_name" {
  description = "The name of the managed policy that bounds each IAM user and role of stage 0, or empty for none. Drill sets PB-DrillBringup: drill-bringup may change a policy only on an identity with that boundary (bootstrap/eks/aws-org/github-oidc-drill.tf)."
  type        = string
  default     = ""
}
