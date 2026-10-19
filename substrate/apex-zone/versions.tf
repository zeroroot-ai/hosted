terraform {
  # import blocks with for_each need 1.7. The repo pins 1.9.8 in CI.
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
  }
}
