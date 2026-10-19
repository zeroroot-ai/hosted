output "instance_id" {
  description = "The instance id. An operator reaches the target through SSM with it, and nothing else reaches it at all."
  value       = aws_instance.goat.id
}

output "private_ip" {
  description = "The address the platform node dials on 6443. No public name resolves to this machine."
  value       = aws_instance.goat.private_ip
}

