resource "aws_route" "default" {
  route_table_id = "rtb-1"
}

resource "aws_route_table_association" "public" {
  subnet_id = "subnet-1"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = "sg-1"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role = "node"
}

resource "aws_eip_association" "node" {
  instance_id = "i-1"
}
