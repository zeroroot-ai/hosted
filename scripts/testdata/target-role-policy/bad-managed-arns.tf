resource "aws_iam_role" "goat" {
  name                = "x"
  managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}
