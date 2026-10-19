output "instance_id" {
  value = aws_instance.node.id
}

output "node_count" {
  value = 1 + length(aws_instance.agent)
}
