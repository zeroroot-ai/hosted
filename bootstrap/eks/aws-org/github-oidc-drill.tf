# ----------------------------------------------------------------------------
# drill-bringup: the role of the drill (ADR-0095), and of the drill only.
#
# Staging, prod and drill share one AWS account. Before this role, the drill ran
# as eks-bringup, the role of the prod verbs. The drill GitHub environment has
# no required reviewer, so a drill run had the access of the prod verbs without
# the prod approval. Now eks-bringup trusts only staging and prod
# (github-oidc.tf), and drill.yml assumes this role.
#
# The trust: GitHub OIDC, the drill environment only, off main, from drill.yml
# only.
#
# The access: AdministratorAccess inside the permission boundary
# PB-DrillBringup. The drill applies stage 1 (a VPC, an instance, its node role)
# and rotates the access keys of the drill IAM users through stage 0, so it
# needs wide access to the resources of drill. The boundary allows only the
# services that drill uses (EC2, SSM, IAM, S3, Route 53, Secrets Manager, SES,
# ECR, STS, KMS and the tagging API), so every other service is denied. In
# those services it takes away each resource of another environment and each
# path out of the boundary:
#
#   - the KMS and login denies of PB-OperatorMaxPermissions;
#   - an IAM write on anything but the drill names (zeroroot-ai-drill-*, the
#     drill users under /substrate/, and the service-linked roles). So the role
#     cannot change itself, its boundary, eks-bringup or any role of staging
#     or prod, and it cannot pass another role to a service;
#   - a role or user that the role creates, or a policy that it puts on one,
#     must carry this boundary. The boundary cannot be removed;
#   - an assume of any role but the drill roles;
#   - each S3 bucket but the drill buckets and the AWS buckets of the SSM agent;
#   - the secrets, parameters, registries and key aliases of staging and prod,
#     by name;
#   - each resource tagged with another Environment, in every service but
#     Route 53, and each volume or snapshot without the drill tag;
#   - a DNS record outside the drill zone, and a delete of a hosted zone;
#   - a write of the SES identities and of the receipt rules, which every
#     environment shares.
#
# scripts/check-role-callers.py fails when a workflow assumes
# DRILL_BRINGUP_ROLE_ARN and gh_drill_bringup_job_workflow_refs does not name
# it, or the reverse, and when eks-bringup trusts the drill environment.
# ----------------------------------------------------------------------------

locals {
  drill_environment = "drill"
  drill_bringup_env_sub = (
    "repo:${var.github_org}@*/${var.github_deploy_repo}@*:environment:${local.drill_environment}"
  )
  gh_drill_bringup_job_workflow_refs = [
    for w in ["drill.yml"] :
    "${var.github_org}/${var.github_deploy_repo}/.github/workflows/${w}@refs/heads/main"
  ]

  drill_boundary_name = "PB-DrillBringup"
}

data "aws_iam_policy_document" "drill_bringup_trust" {
  count = length(var.prod_account_id) > 0 ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.drill_bringup_env_sub]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:environment"
      values   = [local.drill_environment]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:ref"
      values   = ["refs/heads/main"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = local.gh_drill_bringup_job_workflow_refs
    }
  }
}

# The boundary is one JSON template, policies/permission-boundary-drill.json.tftpl,
# so scripts/check-iam-arn-service.py can render it with no AWS credentials and
# fail when its compact size reaches the IAM limit of 6144 characters. Its
# statements, by Sid, in the order of the list in the header:
#
#   AllowTheServicesOfDrill            the services of drill, and no other
#   DenyTheOperatorBoundaryActions     the KMS and login denies of the operator
#   DenyIamWritesOutsideDrill          IAM writes on drill names only
#   DenyAnIdentityWithoutThisBoundary  a new or changed identity carries it
#   DenyRemovingTheBoundary            the boundary cannot be removed
#   DenyAssumingAnotherRole            no assume of a role that is not drill's
#   DenyBucketsOutsideDrill            the drill buckets and the SSM agent buckets
#   DenyResourcesNamedForAnotherEnvironment  secrets, parameters, registries
#                                      and key aliases of staging and prod
#   DenyResourcesTaggedWithAnotherEnvironment  every service but Route 53
#   DenyVolumesAndSnapshotsOutsideDrill  untagged volumes and snapshots
#   DenyCommandsOnInstancesOutsideDrill  SSM on drill instances only
#   DenyRecordsOutsideTheDrillZone     DNS records in the drill zone only
#   DenyZoneDeletes                    no zone delete, no DNSSEC change
#   DenySharedMailWrites               no write of the shared SES setup

resource "aws_iam_policy" "drill_boundary" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name        = local.drill_boundary_name
  description = "Permission boundary of drill-bringup and of each identity it makes: the operator boundary, and no resource of staging or prod (ADR-0095)."
  policy = templatefile("${path.module}/policies/permission-boundary-drill.json.tftpl", {
    account_id      = var.prod_account_id
    region          = var.aws_region
    drill_zone_name = var.drill_zone_name
  })

  # Environment=drill: the tag fence of the boundary lets the drill read its
  # own role and boundary. The IAM fence still keeps it from changing them.
  tags = merge(local.common_tags, { Environment = local.drill_environment })
}

resource "aws_iam_role" "drill_bringup" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  name                 = "drill-bringup"
  description          = "The role of zeroroot-ai/hosted drill.yml, workflow_dispatch off main, in the drill GitHub environment only. Bounded by PB-DrillBringup: no resource of staging or prod."
  assume_role_policy   = data.aws_iam_policy_document.drill_bringup_trust[0].json
  permissions_boundary = aws_iam_policy.drill_boundary[0].arn
  # 6 hours, the GitHub limit of one job, as eks-bringup (github-oidc.tf).
  max_session_duration = 21600

  tags = merge(local.common_tags, { Environment = local.drill_environment })
}

resource "aws_iam_role_policy_attachment" "drill_bringup_admin" {
  count    = length(var.prod_account_id) > 0 ? 1 : 0
  provider = aws.prod

  role       = aws_iam_role.drill_bringup[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
