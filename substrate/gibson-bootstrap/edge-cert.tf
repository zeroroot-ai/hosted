# ----------------------------------------------------------------------------
# The edge TLS certificate of this environment, kept across recreates
# (row 9 of the drill path audit, coordinator decision of 2026-10-12).
#
# Each recreate asked Let's Encrypt for a new certificate, and the drill
# reached the duplicate-certificate limit (5 per exact name set per 7 days)
# in one day. The teardown now stores the cert-manager Secret of the edge
# Certificate (the certificate chain and its key) here, and the next bringup
# restores it before Argo syncs the Certificate. cert-manager keeps a valid
# Secret that matches the Certificate and issues nothing
# (scripts/lib/edge-cert.sh).
#
# One secret per environment, encrypted with KMS (the Secrets Manager key of
# the account). Only the principals of var.edge_cert_principal_role_names
# (the bringup role) read or write it: the resource policy denies every
# other principal, whatever its IAM policy grants. Stage 0 outlives every
# cluster, so no teardown deletes it.
# ----------------------------------------------------------------------------

data "aws_iam_role" "edge_cert" {
  for_each = toset(var.edge_cert_principal_role_names)
  name     = each.value
}

resource "aws_secretsmanager_secret" "edge_cert" {
  name        = "zeroroot-ai/${var.environment}/edge-tls"
  description = "The edge TLS certificate and key of ${var.environment}, kept across recreates so Let's Encrypt issues no new one. Written by the teardown, read by the bringup (scripts/lib/edge-cert.sh)."
  # A recreate keeps it; a stage 0 destroy (never a teardown) removes it at once.
  recovery_window_in_days = 0

  tags = {
    Name = "zeroroot-ai/${var.environment}/edge-tls"
  }
}

data "aws_iam_policy_document" "edge_cert" {
  statement {
    sid     = "BringupReadsAndWrites"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    principals {
      type        = "AWS"
      identifiers = [for r in data.aws_iam_role.edge_cert : r.arn]
    }
    resources = ["*"]
  }

  # Nobody else reads or writes the key, whatever their IAM policy grants.
  statement {
    sid       = "NobodyElse"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = [for r in data.aws_iam_role.edge_cert : r.arn]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "edge_cert" {
  secret_arn          = aws_secretsmanager_secret.edge_cert.arn
  policy              = data.aws_iam_policy_document.edge_cert.json
  block_public_policy = true
}
