# ----------------------------------------------------------------------------
# Providers.
#
# No default_tags on purpose. The live zone carries the tags the prod estate
# gave it on 2026-06-04, and those are declared on the resource itself so the
# plan against the live zone is empty. The SES identities carry no tags. A
# provider-level tag set would put a tag update on every identity, which is a
# change to live company mail this workspace does not make on its own.
#
# Two regions, and that is a fact of the live estate, not a choice made here.
# SES production sending access was granted in us-east-2 (see
# eks/gibson/providers.tf). The us-east-1 identity predates it and is still
# verified and signing. Both identities publish DKIM CNAMEs into the apex zone,
# so both are company property and both are owned here.
# ----------------------------------------------------------------------------

provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "ohio"
  region = "us-east-2"
}
