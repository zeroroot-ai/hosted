# ----------------------------------------------------------------------------
# The network. One public subnet and an internet gateway, and nothing else.
#
# There is no NAT gateway on purpose. The instance sits in the public subnet
# with an Elastic IP, so it reaches the internet through the gateway directly.
# A NAT gateway would add about thirty dollars a month and an hourly data
# charge to carry the same packets.
# ----------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.cluster_name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.cluster_name }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route" "default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ----------------------------------------------------------------------------
# The security group. ONE port is open to the world, because it is the
# product: 443, the edge.
#
# Port 80 is closed. The chart's edge Service carries a single port, https,
# so nothing would answer on 80 and an open port with nothing behind it is
# an invitation, not a redirect.
#
# Port 22 is absent and so is a key pair. The operator reaches the host through
# SSM Session Manager, which needs no inbound port and leaves an audit record.
# Port 6443 is closed unless an environment names an address range.
# ----------------------------------------------------------------------------

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "The one cluster node: the edge port, and nothing inbound that is not the product"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.cluster_name}-node" }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.node.id
  description       = "HTTPS, the edge"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  for_each = toset(var.api_allow_cidrs)

  security_group_id = aws_security_group.node.id
  description       = "The Kubernetes API, for an operator address this environment named"
  cidr_ipv4         = each.value
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

# A second node talks to the server on 6443 and carries pod traffic over the
# Cilium tunnel (hosted#453). The rule admits the group to itself and nothing
# else, and it exists only when the cluster has two nodes, so the plan of a
# one-node environment does not change.
resource "aws_vpc_security_group_ingress_rule" "intra_cluster" {
  count = var.node_count > 1 ? 1 : 0

  security_group_id            = aws_security_group.node.id
  description                  = "The nodes of this cluster, to each other"
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "The node pulls images, reaches the durable bucket and sends mail"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ----------------------------------------------------------------------------
# The instance role. It carries the SSM agent permissions, and ecr.tf adds
# pull on the setec disk repository of stage 0 (D85). Nothing else.
#
# The platform's own AWS access comes from the stage 0 access keys in the
# bringup keyring, exactly as it does on kind. Stage 1 grants the node no
# bucket access, so a compromised pod cannot reach the durable bucket through
# the instance metadata service.
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  node_permissions_boundary_arn = var.node_permissions_boundary_name == "" ? null : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.node_permissions_boundary_name}"
}

resource "aws_iam_role" "node" {
  name                 = "${var.cluster_name}-node"
  assume_role_policy   = data.aws_iam_policy_document.assume_ec2.json
  permissions_boundary = local.node_permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node.name
}

data "aws_partition" "current" {}

# ----------------------------------------------------------------------------
# The instance, and the address that outlives it.
#
# The Elastic IP is a separate resource on purpose: the DNS records point at
# it, so replacing the instance does not change the address and no record has
# to be rewritten while the environment is down.
# ----------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

resource "aws_eip" "node" {
  domain = "vpc"

  tags = { Name = var.cluster_name }
}

resource "aws_instance" "node" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # IMDSv2 only. A token-less metadata read is how a request-forgery bug in a
  # pod becomes the instance role.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Gzip, because EC2 refuses user data over 16 KB and the rendered script is
  # near that size. Cloud-init reads gzip user data as is.
  user_data_base64            = base64gzip(local.node_init)
  user_data_replace_on_change = true

  # Nested virtualization gives the node /dev/kvm (hosted#448). The block is
  # absent for every other family, so the plan of an m6a node does not change.
  dynamic "cpu_options" {
    for_each = local.nested_virtualization ? [1] : []
    content {
      nested_virtualization = "enabled"
    }
  }

  # A poweroff from inside the box TERMINATES it when a ceiling is armed, and
  # merely stops it otherwise. The cloud-init timer below is what powers it off;
  # this line is what makes that final. Without it a self-terminating instance
  # would stop instead, which keeps billing the EBS volume and reads as "gone"
  # in a console glance.
  instance_initiated_shutdown_behavior = var.self_terminate_after_minutes > 0 ? "terminate" : "stop"

  tags = { Name = var.cluster_name }

  # THE AMI IS READ AT CREATE TIME AND NEVER DRIFTS THE RUNNING NODE. The
  # data source above resolves "latest" on every plan, and Amazon publishes
  # a new AL2023 image every few weeks. Without this rule each release made
  # the staging plan want to destroy and recreate the node, which the
  # Terraform exit test refuses (blocker 1 went red on 2026-09-29, one day
  # after the hosted#209 rebuild, runs 36513078561 and 36524663471). A
  # running node does not change its image by itself, so the plan must not
  # claim it does. A recreate from zero still boots the newest image, and a
  # user-data change still replaces the node on purpose (the line above).
  lifecycle {
    ignore_changes = [ami]
  }

  # The route to the internet gateway is a real dependency, not a formality.
  # Cloud-init downloads k3s on the first boot, so an instance
  # that starts before the route exists comes up with neither and says so
  # only in its own log.
  #
  # It is also what makes the targeted first phase correct. Nothing else in
  # this root refers to the gateway or the route, so a plan targeting the
  # instance alone left both out, and the address association then failed
  # with `Gateway.NotAttached` on a VPC that had no gateway (measured on the
  # first staging bringup, 2026-09-22).
  depends_on = [aws_route.default]
}

resource "aws_eip_association" "node" {
  instance_id   = aws_instance.node.id
  allocation_id = aws_eip.node.id
}

# ----------------------------------------------------------------------------
# The second node (hosted#453). It exists only when node_count is 2.
#
# It is the same type, the same image, the same volume, the same profile and
# the same security group as the server, so a proof that needs "a second node
# of the same class" (D57, setec#183) gets one. Its cloud-init arms the same
# ceiling first, and it joins the server as a k3s agent with the agent token
# below.
# It has no address of its own that anything resolves: the Elastic IP of the
# server is the edge, and the agent is reached through SSM like the server.
#
# The token is an AGENT token (K3S_AGENT_TOKEN on the server). It lets a node
# join as an agent and nothing else: it cannot join a server or read the
# cluster datastore. The server keeps the server token that k3s mints for
# itself, and that token never leaves the server. The agent token travels in
# the user data of both instances. Two paths read user data: the metadata
# service of the instance (IMDSv2, hop limit 1, so no pod reaches it), and the
# EC2 API for a principal with ec2:DescribeInstanceAttribute. The token is in
# the Terraform state too. It is minted for this estate and dies with it. A
# one-node cluster renders no token, so its user data does not change.
# ----------------------------------------------------------------------------

resource "random_password" "agent_token" {
  count = var.node_count > 1 ? 1 : 0

  length  = 48
  special = false
}

resource "aws_instance" "agent" {
  count = var.node_count - 1

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data_base64            = base64gzip(local.agent_init)
  user_data_replace_on_change = true

  dynamic "cpu_options" {
    for_each = local.nested_virtualization ? [1] : []
    content {
      nested_virtualization = "enabled"
    }
  }

  # The same ceiling as the server: a poweroff terminates it, and the reaper
  # finds it by the Environment tag like every resource of this root.
  instance_initiated_shutdown_behavior = var.self_terminate_after_minutes > 0 ? "terminate" : "stop"

  tags = { Name = "${var.cluster_name}-agent-${count.index}" }

  lifecycle {
    ignore_changes = [ami]
  }

  # The agent downloads k3s through the gateway, and it joins a server that
  # must exist first.
  depends_on = [aws_route.default, aws_instance.node]
}

locals {
  # The families on which AWS supports nested virtualization. The family is the
  # text before the first dot of the type.
  nested_virtualization_families = ["c8i", "m8i", "r8i"]
  nested_virtualization          = contains(local.nested_virtualization_families, split(".", var.instance_type)[0])

  # The one pin of the kubelet ECR credential provider (D85, ecr.tf). The
  # SHA-256 is the one artifacts.k8s.io publishes beside the binary.
  ecr_credential_provider_version = "v1.37.0"
  ecr_credential_provider_sha256  = "842e0fd8159f5ed8df2f38e6521e1e4f0a1ee80cf1e1ac119bbf20bf9c20681c"

  # Empty on a one-node cluster, so the server's user data is unchanged there.
  agent_token = var.node_count > 1 ? random_password.agent_token[0].result : ""

  node_init = templatefile("${path.module}/templates/node-init.sh.tftpl", {
    k3s_version                  = var.k3s_version
    node_ip                      = aws_eip.node.public_ip
    instance_type                = var.instance_type
    cluster_name                 = var.cluster_name
    service_cidr                 = var.service_cidr
    self_terminate_after_minutes = var.self_terminate_after_minutes
    agent_token                  = local.agent_token
    ecr_credential_provider = templatefile("${path.module}/templates/ecr-credential-provider.sh.tftpl", {
      ecr_credential_provider_version = local.ecr_credential_provider_version
      ecr_credential_provider_sha256  = local.ecr_credential_provider_sha256
      log_prefix                      = "node-init"
    })
  })

  agent_init = templatefile("${path.module}/templates/agent-init.sh.tftpl", {
    k3s_version                  = var.k3s_version
    server_ip                    = aws_instance.node.private_ip
    instance_type                = var.instance_type
    cluster_name                 = var.cluster_name
    self_terminate_after_minutes = var.self_terminate_after_minutes
    agent_token                  = local.agent_token
    ecr_credential_provider = templatefile("${path.module}/templates/ecr-credential-provider.sh.tftpl", {
      ecr_credential_provider_version = local.ecr_credential_provider_version
      ecr_credential_provider_sha256  = local.ecr_credential_provider_sha256
      log_prefix                      = "agent-init"
    })
  })
}
