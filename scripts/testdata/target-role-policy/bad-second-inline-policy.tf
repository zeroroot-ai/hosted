resource "aws_iam_role_policy" "goat" {
  name   = "goat-node"
  role   = aws_iam_role.goat.id
  policy = local.instance_role_policy
}

resource "aws_iam_role_policy" "extra" {
  name   = "extra"
  role   = aws_iam_role.goat.id
  policy = data.aws_iam_policy_document.extra.json
}
