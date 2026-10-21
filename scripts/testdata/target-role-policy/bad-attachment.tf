resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.goat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
