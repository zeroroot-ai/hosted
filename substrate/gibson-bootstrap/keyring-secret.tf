# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# The bringup keyring and substrate.env of this environment, in Secrets Manager
# (ADR-0083, amendment of 2026-10-22). Every environment keeps its keyring
# here. There is no other store: no GitHub environment secret, no file on a
# workstation.
#
# The value is a JSON object {"keyring": "<keyring.env>", "substrate_env":
# "<substrate.env>"}. Encrypted with KMS (the Secrets Manager key of the
# account). Four kinds of principal read or write it:
#
#   - the roles of var.keyring_principal_role_names: the operator role that runs
#     stage 0 from the workstation, and for drill only the bringup role;
#   - the key rotation role (rotation-role.tf): read and write, because the
#     rotation changes the keyring;
#   - the keyring reader role of the environment (keyring-reader-role.tf): read
#     only, for preflight, recreate and teardown.
# The resource policy denies every other principal.
# ----------------------------------------------------------------------------

data "aws_iam_role" "keyring" {
  for_each = toset(var.keyring_principal_role_names)
  name     = each.value
}

resource "aws_secretsmanager_secret" "keyring" {
  name        = "zeroroot-ai/${var.environment}/keyring"
  description = "The bringup keyring and substrate.env of ${var.environment} (ADR-0083). Written by stage 0 and by the credential rotation, read by each bringup job (scripts/stage0-store.sh)."
  # Stage 0 outlives every cluster. A stage 0 destroy (never a teardown)
  # removes it at once.
  recovery_window_in_days = 0

  tags = {
    Name = "zeroroot-ai/${var.environment}/keyring"
  }
}

data "aws_iam_policy_document" "keyring" {
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
      # The roles above, and the two roles of this root that its own IAM
      # policy lets in: the rotation role (read and write) and the reader role
      # (read only). Their IAM policies grant exactly that.
      values = concat(
        [for r in data.aws_iam_role.keyring : r.arn],
        var.rotation_role_enabled ? [aws_iam_role.rotation[0].arn] : [],
        var.keyring_reader_role_enabled ? [aws_iam_role.keyring_reader[0].arn] : [],
      )
    }
  }
}

resource "aws_secretsmanager_secret_policy" "keyring" {
  secret_arn          = aws_secretsmanager_secret.keyring.arn
  policy              = data.aws_iam_policy_document.keyring.json
  block_public_policy = true
}
