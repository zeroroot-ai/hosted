output "instance_id" {
  value = aws_instance.node.id
}

output "node_count" {
  value = var.node_count
}
