# ----------------------------------------------------------------------------
# The kubernetes-goat target: one EC2 instance running k3s, carrying a
# deliberately vulnerable cluster for Gibson's agents to assess and exploit.
#
# THIS IS A TARGET, NOT A PLATFORM CLUSTER. It joins the staging VPC by id and
# builds no network of its own. It is NOT a stage 1 root under ADR-0083: it
# runs no platform, reconciles no Argo tree and holds no state anyone needs.
# That is why it lives outside bootstrap/, beside substrate/, and why
# scripts/check-stage1-shape.py does not read it.
#
# It carries one instance, one security group, one role and one profile. There
# is no VPC, no subnet, no gateway, no route table, no Elastic IP, no DNS
# record and no certificate.
# ----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
  }
}
