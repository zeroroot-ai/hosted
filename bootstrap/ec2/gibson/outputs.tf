output "node_public_ip" {
  description = "The Elastic IP every host of this environment resolves to."
  value       = aws_eip.node.public_ip
}

output "instance_id" {
  description = "The instance id. The recreate verb uses it to reach the host through SSM."
  value       = aws_instance.node.id
}

output "nested_virtualization" {
  description = "True when the instance runs with nested virtualization enabled. The recreate verb then proves that /dev/kvm exists on the node."
  # Read from the instance, not from the local. The recreate applies phase 1
  # with -target, and a targeted apply writes no output that depends on no
  # targeted resource: on 2026-10-06 `terraform output` said "not found" and
  # the /dev/kvm check was skipped in silence.
  value = try(aws_instance.node.cpu_options[0].nested_virtualization, "") == "enabled"
}

output "node_count" {
  description = "How many instances form the cluster. The recreate verb waits for this many Ready nodes."
  # Counted from the instances, not read from the variable. The recreate
  # applies phase 1 with -target, and a targeted apply writes no output that
  # depends on no targeted resource (hosted#609, the class of hosted#498).
  # scripts/check-ec2-phase1-outputs.py holds every phase 1 read to this.
  value = 1 + length(aws_instance.agent)
}

output "agent_instance_ids" {
  description = "The instance ids of the agent nodes, empty on a one-node cluster (hosted#453)."
  value       = aws_instance.agent[*].id
}
