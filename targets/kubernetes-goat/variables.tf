# ----------------------------------------------------------------------------
# Every variable an environment must name. The platform cluster name has no
# default: this root joins an existing VPC, and a default that guesses one is
# how the wrong estate gets a vulnerable machine in it.
# ----------------------------------------------------------------------------

variable "environment" {
  description = "The environment this target belongs to. Supplied by envs/<env>.tfvars."
  type        = string
}

variable "workspace_name" {
  description = "The Terraform workspace name, recorded as a tag."
  type        = string
}

variable "target_name" {
  description = "The target's name. Names the instance, the security group, the role and the profile."
  type        = string
}

variable "cost_center" {
  description = "The CostCenter tag the SCP requires."
  type        = string
}

variable "aws_account_id" {
  description = "The account this target runs in. It names the one SSM parameter the instance role may read, and a precondition compares it with the session."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit account id."
  }
}

variable "aws_region" {
  description = "The region this target runs in."
  type        = string
  default     = "us-east-1"
}

# ----------------------------------------------------------------------------
# The existing network. This root creates none of it.
# ----------------------------------------------------------------------------

variable "platform_cluster_name" {
  description = "The cluster_name of the stage 1 root this target joins (bootstrap/ec2/gibson). The VPC, the public subnet and the node security group are found by their Name tags, which that root derives from this name. An id is never pinned: a recreate makes new ids, and a pinned id names a network that no longer exists."
  type        = string
}

# ----------------------------------------------------------------------------
# The instance.
# ----------------------------------------------------------------------------

variable "instance_type" {
  description = "The instance the target cluster runs on. The default is 2 vCPU and 4 GB, which carries the goat's twelve workloads at 50 to 100 MiB each with room for k3s itself."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_gb" {
  description = "The instance volume. It holds the scenario images and the checked-out repository, and nothing that must survive the instance."
  type        = number
  default     = 30
}

variable "k3s_version" {
  description = "The exact k3s version. Pinned so an unattended rebuild cannot change the Kubernetes version under a published finding."
  type        = string
  default     = "v1.33.4+k3s1"
}

variable "helm_version" {
  description = "The exact helm version the reconcile uses for the metadata-db chart."
  type        = string
  default     = "v3.19.0"
}

# ----------------------------------------------------------------------------
# The fix loop. An agent opens a merge request against the goat repository, it
# merges, and the next reconcile applies it. That is the demo.
# ----------------------------------------------------------------------------

variable "goat_repo_url" {
  description = "The repository the target reconciles from, over HTTPS. It is private, so the reconcile reads a deploy token from SSM at run time."
  type        = string
  default     = "https://gitlab.com/zero-root/kubernetes-goat.git"
}

variable "goat_repo_ref" {
  description = "The branch the target tracks. A merged merge request on this branch is what the next reconcile picks up."
  type        = string
  default     = "main"
}

variable "deploy_token_parameter_name" {
  description = <<-EOT
    The SSM Parameter Store name holding the GitLab project deploy token, as a
    SecureString encrypted with the default alias/aws/ssm key. The value is
    "username:token" — the deploy token's own username, a colon, then the token
    with read_repository scope and nothing else.

    THE VALUE NEVER ENTERS TERRAFORM. This root passes the NAME into user data
    and the instance reads the value itself on every reconcile, so no token
    reaches the plan, the state file or the instance's user data. The operator
    creates the parameter by hand (see README.md).
  EOT
  type        = string
}

variable "reconcile_interval" {
  description = "How often the reconcile timer runs, as a systemd time span. Two minutes is short enough that a demo does not wait on it."
  type        = string
  default     = "2min"
}
