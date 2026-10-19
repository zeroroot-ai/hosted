terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
    # Packages the lead-path Lambda source. Declared here as well as in the
    # module so the root's lock file pins it.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}
