locals {
  docs_content_security_policy = ""
}

module "docs" {
  content_security_policy = local.docs_content_security_policy
}

module "docs_staging" {
  content_security_policy = local.docs_content_security_policy
}
