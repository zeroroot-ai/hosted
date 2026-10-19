# ----------------------------------------------------------------------------
# Root-level computed values. Kept minimal — most locals live in their modules.
#
# The four cost tags (Environment + Project + Owner + CostCenter) are a
# convention of this estate. No SCP enforces them (hosted#418). ManagedBy +
# Workspace are operational metadata. Environment is the canonical env
# indicator across cost reports, alerting, and ServiceMonitor labels; it comes
# from var.environment, supplied by envs/<env>.tfvars (deploy#1397).
# ----------------------------------------------------------------------------

# The partition (aws, aws-us-gov, aws-cn), read at the ROOT on purpose.
#
# Terraform defers every data source declared inside a module invoked with
# `depends_on`, whenever that dependency has pending changes. modules/iam-irsa
# is invoked that way, it built an AWS-managed policy ARN from the partition,
# and `aws_iam_role_policy_attachment.policy_arn` is ForceNew — so the deferred
# partition made the ARN "known after apply" and forced the EBS CSI attachment
# to be REPLACED on every plan. Measured on exit-test-terraform run
# 34990262565; the same shape as deploy#1588 defect 2, where a bucket name
# interpolated a deferred account id and the unknown name forced the bucket to
# be replaced.
#
# Nothing defers a root data source, so reading it here and passing it in is
# what keeps the plan free of replacements. Any future module that needs a
# partition takes it from here rather than reading its own.
data "aws_partition" "current" {}

locals {
  common_tags = {
    Environment = var.environment
    Project     = "zeroroot-ai"
    Owner       = "platform"
    CostCenter  = var.cost_center
    ManagedBy   = "terraform"
    Workspace   = var.workspace_name
  }
}
