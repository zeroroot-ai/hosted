# ----------------------------------------------------------------------------
# The bringup keyring and substrate.env of this environment, in Secrets
# Manager (ADR-0083 amendment of 2026-10-13, drill sweep row 24).
#
# Only drill keeps its keyring here (var.keyring_in_aws). The drill rotates
# its own access keys (scripts/substrate-rotate.sh, in .github/workflows/
# drill.yml), so a runner must read and write the keyring, and the GitHub
# workflow token cannot write a GitHub Environment secret. Every drill job
# reads the keyring from this secret (scripts/stage0-store.sh), and the
# rotation writes the new one here. The trust holds for drill only: drill is
# disposable, its keyring protects a disposable environment, and the bringup
# role can already read everything the keyring protects. Staging and prod
# keep their keyring on the operator workstation.
#
# The value is a JSON object {"keyring": "<keyring.env>", "substrate_env":
# "<substrate.env>"}. Encrypted with KMS (the Secrets Manager key of the
# account). The principals of var.keyring_principal_role_names read and write
# it: the bringup role, and the operator role that runs stage 0 from the
# workstation. The resource policy denies every other principal.
# ----------------------------------------------------------------------------

data "aws_iam_role" "keyring" {
  for_each = var.keyring_in_aws ? toset(var.keyring_principal_role_names) : toset([])
  name     = each.value
}

resource "aws_secretsmanager_secret" "keyring" {
  count       = var.keyring_in_aws ? 1 : 0
  name        = "zeroroot-ai/${var.environment}/keyring"
  description = "The bringup keyring and substrate.env of ${var.environment} (ADR-0083). Written by stage 0 and by the access key rotation of the drill, read by each drill job (scripts/stage0-store.sh)."
  # Stage 0 outlives every cluster. A stage 0 destroy (never a teardown)
  # removes it at once.
  recovery_window_in_days = 0

  tags = {
    Name = "zeroroot-ai/${var.environment}/keyring"
  }
}

data "aws_iam_policy_document" "keyring" {
  count = var.keyring_in_aws ? 1 : 0

  statement {
    sid     = "StageZeroReadsAndWrites"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    principals {
      type        = "AWS"
      identifiers = [for r in data.aws_iam_role.keyring : r.arn]
    }
    resources = ["*"]
  }

  # Nobody else reads or writes the keyring, whatever their IAM policy grants.
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
      values   = [for r in data.aws_iam_role.keyring : r.arn]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "keyring" {
  count               = var.keyring_in_aws ? 1 : 0
  secret_arn          = aws_secretsmanager_secret.keyring[0].arn
  policy              = data.aws_iam_policy_document.keyring[0].json
  block_public_policy = true
}
