# ----------------------------------------------------------------------------
# The VPC: 3-AZ, multi-NAT, VPC endpoints to keep AWS service traffic off
# the internet (cost + security). No flow log: the audit bucket it archived
# to left with the rest of the AWS control-plane surface (ADR-0083,
# deploy#1744), and account-level network forensics are the account owner's
# tooling, not the platform's.
# ----------------------------------------------------------------------------

locals {
  # /16 split into 3 × /20 public, 3 × /19 private, 3 × /22 intra.
  # cidrsubnet preserves room for more subnets if needed later.
  public_subnets  = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 4, i)]      # /20 × 3
  private_subnets = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 3, i + 2)]  # /19 × 3
  intra_subnets   = [for i, az in var.availability_zones : cidrsubnet(var.vpc_cidr, 6, i + 40)] # /22 × 3
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
  intra_subnets   = local.intra_subnets

  enable_nat_gateway      = true
  single_nat_gateway      = var.single_nat_gateway
  one_nat_gateway_per_az  = !var.single_nat_gateway
  enable_dns_hostnames    = true
  enable_dns_support      = true
  map_public_ip_on_launch = false

  # EKS subnet discovery tags.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # Karpenter discovery tag.
    "karpenter.sh/discovery" = var.cluster_name
  }

  enable_flow_log = false
}

# ----------------------------------------------------------------------------
# VPC endpoints — keep AWS service traffic off NAT.
# Gateway endpoints are free (S3, DynamoDB); interface endpoints cost ~$7/mo
# per AZ each. Limit to what's actually used.
# ----------------------------------------------------------------------------

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.cluster_name}-vpc-endpoints"
  description = "Allow HTTPS from VPC CIDR to interface endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-vpc-endpoints"
  }
}

# Gateway endpoint — S3 (free, route-table based)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = {
    Name = "${var.cluster_name}-s3-gateway"
  }
}

# Interface endpoints — one per AZ each, ~$7/mo each.
locals {
  interface_endpoints = toset([
    "ecr.api",
    "ecr.dkr",
    "sts",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "logs",
  ])
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.cluster_name}-${each.value}"
  }
}
