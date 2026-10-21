# ----------------------------------------------------------------------------
# The platform network, found by name. bootstrap/ec2/gibson tags the VPC with
# its cluster_name, the public subnet with "<cluster_name>-public" and the node
# security group with "<cluster_name>-node". A lookup fails the plan when the
# platform is not up, which is correct: this target has nowhere to go.
# ----------------------------------------------------------------------------

data "aws_vpc" "platform" {
  tags = { Name = var.platform_cluster_name }
}

data "aws_subnet" "platform_public" {
  vpc_id = data.aws_vpc.platform.id
  tags   = { Name = "${var.platform_cluster_name}-public" }
}

data "aws_security_group" "platform_node" {
  vpc_id = data.aws_vpc.platform.id
  tags   = { Name = "${var.platform_cluster_name}-node" }
}

# ----------------------------------------------------------------------------
# The security group. NOTHING inbound comes from the internet, on any port.
#
# One ingress rule exists: the Kubernetes API on 6443, reachable only from the
# platform node's own security group. It is written as a security-group
# reference, never an address range, so the rule follows the platform node
# across a rebuild and grants nothing to anything else in the VPC.
#
# Port 22 is absent and so is a key pair. Port 80 and 443 are absent: the
# goat's scenario pages are reached through a kubectl port-forward over an SSM
# session, exactly as the platform's API is. The operator reaches the host
# through SSM Session Manager, which needs no inbound port and leaves an audit
# record.
#
# This matters more here than anywhere else in the estate. The workloads on
# this node are deliberately vulnerable, and several scenarios escape the
# container to the host. An open port would publish that.
# ----------------------------------------------------------------------------

resource "aws_security_group" "goat" {
  name        = var.target_name
  description = "The kubernetes-goat target: the Kubernetes API from the platform node, and nothing else inbound"
  vpc_id      = data.aws_vpc.platform.id

  tags = { Name = var.target_name }
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  security_group_id = aws_security_group.goat.id

  # AWS restricts a rule description to a-zA-Z0-9 and a fixed punctuation set
  # that excludes the apostrophe. An apostrophe here fails the apply with
  # InvalidParameterValue, AFTER the instance and the group are created, which
  # leaves the target up and unreachable. Keep this plain.
  description                  = "The Kubernetes API, from the platform node only"
  referenced_security_group_id = data.aws_security_group.platform_node.id
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.goat.id

  description = "The node pulls k3s, helm, the scenario images and the goat repository"
  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

# ----------------------------------------------------------------------------
# The instance role. The two things the node does, and nothing else.
#
# Every workload on this node is meant to be broken into, and a break-out
# reaches the instance role. So the role holds only these actions:
#
#   1. What the SSM agent needs for a Session Manager shell and port forward:
#      ssm:UpdateInstanceInformation and the four ssmmessages channel actions.
#      The managed policy AmazonSSMManagedInstanceCore is NOT attached: it
#      reads every SSM parameter of the account.
#   2. ssm:GetParameters on the ONE parameter that holds the deploy token of
#      the reconcile (var.deploy_token_parameter_name), and no other. The
#      reconcile calls get-parameters, the plural form, which is the action
#      granted here. The SecureString uses the AWS managed alias/aws/ssm key,
#      whose key policy lets a principal of this account decrypt through SSM,
#      so the role carries no kms action.
#
# The role has no bucket, secret, registry or write action of any kind.
# ----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "goat" {
  name               = var.target_name
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "goat" {
  statement {
    sid    = "SessionManager"
    effect = "Allow"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadTheDeployToken"
    effect    = "Allow"
    actions   = ["ssm:GetParameters"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.deploy_token_parameter_name}"]
  }
}

resource "aws_iam_role_policy" "goat" {
  name   = "goat-node"
  role   = aws_iam_role.goat.id
  policy = data.aws_iam_policy_document.goat.json
}

resource "aws_iam_instance_profile" "goat" {
  name = var.target_name
  role = aws_iam_role.goat.name
}

# ----------------------------------------------------------------------------
# The instance.
#
# There is no Elastic IP. Nothing resolves to this machine and no DNS record
# names it. The platform reaches it on its private address inside the VPC, and
# an operator reaches it through SSM.
#
# No sandbox runtime is here on purpose, and that is the one place this root
# departs from bootstrap/ec2/gibson. The platform node runs setec sandboxes
# because a tenant's code runs there. Here the escape IS the exercise: a scenario that
# cannot reach the host teaches nothing, and the separate instance is what
# contains it.
# ----------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

resource "aws_instance" "goat" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.platform_public.id
  vpc_security_group_ids = [aws_security_group.goat.id]
  iam_instance_profile   = aws_iam_instance_profile.goat.name

  # A public address, because the staging VPC has no NAT gateway and the node
  # pulls every image through the internet gateway. It publishes nothing: the
  # security group above accepts no inbound packet from outside the VPC.
  associate_public_ip_address = true

  # IMDSv2 only, hop limit 1. A pod on this node cannot reach the metadata
  # service at all. The role holds only the SSM agent actions and one
  # parameter read (above), and the goat's metadata scenario serves its own
  # fake endpoint.
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

  user_data                   = local.node_init
  user_data_replace_on_change = true

  tags = { Name = var.target_name }

  # THE AMI IS READ AT CREATE TIME AND NEVER DRIFTS THE RUNNING NODE. The data
  # source above resolves "latest" on every plan and Amazon publishes a new
  # AL2023 image every few weeks, so without this rule every plan wants to
  # destroy and recreate the node. Same rule, same reason, as
  # bootstrap/ec2/gibson.
  lifecycle {
    ignore_changes = [ami]
  }
}

locals {
  node_init = templatefile("${path.module}/templates/node-init.sh.tftpl", {
    k3s_version        = var.k3s_version
    helm_version       = var.helm_version
    target_name        = var.target_name
    aws_region         = var.aws_region
    goat_repo_url      = var.goat_repo_url
    goat_repo_ref      = var.goat_repo_ref
    token_parameter    = var.deploy_token_parameter_name
    reconcile_interval = var.reconcile_interval
  })
}
