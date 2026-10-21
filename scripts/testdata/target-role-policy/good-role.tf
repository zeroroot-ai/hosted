locals {
  instance_role_policy = jsonencode({})
}

resource "aws_iam_role" "goat" {
  name = "x"
}

resource "aws_iam_role_policy" "goat" {
  name   = "goat-node"
  role   = aws_iam_role.goat.id
  policy = local.instance_role_policy
}
