resource "aws_instance" "node" {
}

resource "aws_instance" "agent" {
  count = var.node_count - 1
}
