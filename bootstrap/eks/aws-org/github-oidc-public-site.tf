# ----------------------------------------------------------------------------
# public-site-publish — the role zeroroot-ai/www and zeroroot-ai/docs-site
# assume to publish their built sites.
#
# In plain words: this is what lets CI copy the built website into the bucket
# and tell the CDN to stop serving the old copy. It can do nothing else.
#
# Why it lives here rather than beside the buckets in eks/public-site: every
# GitHub OIDC role in this estate is declared in this file's siblings, and the
# owner chose to keep that true (2026-08-18). The cost is that adding a
# publish role requires a plan of THIS workspace, which needs the operator
# tfvars — see README.md.
#
# Scope, deliberately narrow:
#   - Only the two publish workflows, pinned by job_workflow_ref, so no other
#     workflow in either repo can assume it even on the same branch.
#   - Only tag refs. A publish is cut from a release tag, never from a branch
#     (ADR-0077) — so a push to main cannot reach the bucket at all.
#   - Only the named buckets and distributions. No wildcards.
#
# The whole thing is gated on the ARNs being supplied. A trust policy without
# a grant is a role that exists and can do nothing, which reads as broken; a
# grant without a trust policy is a dangling permission. They ship together.
# ----------------------------------------------------------------------------

locals {
  public_site_publish_enabled = (
    length(var.prod_account_id) > 0
    && length(var.public_site_bucket_arns) > 0
    && length(var.public_site_distribution_arns) > 0
  )

  # Tag refs only. `ref_type:tag` is carried in the sub claim as
  # `repo:<org>/<repo>:ref:refs/tags/<tag>`; the wildcard is on the tag name,
  # never on the ref TYPE, so a branch push produces a sub that matches nothing.
  gh_publish_subs = [
    "repo:${var.github_org}@*/${var.github_www_repo}@*:ref:refs/tags/*",
    "repo:${var.github_org}@*/${var.github_docs_repo}@*:ref:refs/tags/*",
  ]

  gh_publish_job_workflow_refs = [
    "${var.github_org}/${var.github_www_repo}/.github/workflows/publish-site.yml@refs/tags/*",
    "${var.github_org}/${var.github_docs_repo}/.github/workflows/publish-site.yml@refs/tags/*",
  ]

  public_site_bucket_object_arns = [for arn in var.public_site_bucket_arns : "${arn}/*"]
}

data "aws_iam_policy_document" "public_site_publish_trust" {
  count = local.public_site_publish_enabled ? 1 : 0

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

    # StringLike, not StringEquals: the tag name varies per release. The ref
    # TYPE is still fixed to refs/tags, so a branch can never match.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.gh_publish_subs
    }

    # Pins the single workflow file in each repo. Without this, any workflow in
    # either repo running on a tag could assume the role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = local.gh_publish_job_workflow_refs
    }
  }
}

data "aws_iam_policy_document" "public_site_publish" {
  count = local.public_site_publish_enabled ? 1 : 0

  statement {
    sid    = "ListTheTargetBuckets"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = var.public_site_bucket_arns
  }

  statement {
    sid    = "WriteSiteObjects"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      # DeleteObject is required by `aws s3 sync --delete`, which is how a
      # removed page stops being served. Scoped to these buckets' objects only.
      "s3:DeleteObject",
    ]
    resources = local.public_site_bucket_object_arns
  }

  statement {
    sid    = "InvalidateTheDistributions"
    effect = "Allow"
    actions = [
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
    ]
    resources = var.public_site_distribution_arns
  }
}

resource "aws_iam_role" "public_site_publish" {
  count    = local.public_site_publish_enabled ? 1 : 0
  provider = aws.prod

  name                 = "public-site-publish"
  description          = "Assumed by zeroroot-ai/www and zeroroot-ai/docs-site publish-site.yml on a release tag. Writes the two public-site buckets and invalidates their distributions. Nothing else."
  assume_role_policy   = data.aws_iam_policy_document.public_site_publish_trust[0].json
  permissions_boundary = aws_iam_policy.operator_permission_boundary[0].arn
  max_session_duration = 3600

  tags = local.common_tags
}

resource "aws_iam_role_policy" "public_site_publish" {
  count    = local.public_site_publish_enabled ? 1 : 0
  provider = aws.prod

  name   = "public-site-publish"
  role   = aws_iam_role.public_site_publish[0].id
  policy = data.aws_iam_policy_document.public_site_publish[0].json
}

output "public_site_publish_role_arn" {
  description = "ARN of the publish role. Set as PUBLISH_ROLE_ARN (or a repo variable) in www and docs-site. Empty until the public_site_* ARNs are supplied."
  value       = local.public_site_publish_enabled ? aws_iam_role.public_site_publish[0].arn : ""
}
