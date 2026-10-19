# ----------------------------------------------------------------------------
# Cost Explorer cost categories.
#
# Three dimensions per R10.2: Environment, Project, Component. Categories
# group line items by tag value so a single Cost Explorer query can answer
# "how much did 'prod' cost this month?" without fishing for per-resource
# tag drift.
#
# IMPORTANT: cost-allocation tags must be ACTIVATED in the Billing console
# (Billing → Cost allocation tags → Activate) before they show up in Cost
# Explorer. This is a manual one-shot step, documented in README.
# ----------------------------------------------------------------------------

resource "aws_ce_cost_category" "environment" {
  name         = "gibson-environment"
  rule_version = "CostCategoryExpression.v1"

  rule {
    value = "prod"
    # type is always "REGULAR" for tag-expression rules; the CE API returns
    # it even when omitted, so leaving it implicit makes every plan show a
    # perpetual `- type = "REGULAR" -> null` no-op diff (deploy#696).
    type = "REGULAR"
    rule {
      tags {
        key           = "Environment"
        values        = ["prod"]
        match_options = ["EQUALS"]
      }
    }
  }

  rule {
    value = "org"
    # type is always "REGULAR" for tag-expression rules; the CE API returns
    # it even when omitted, so leaving it implicit makes every plan show a
    # perpetual `- type = "REGULAR" -> null` no-op diff (deploy#696).
    type = "REGULAR"
    rule {
      tags {
        key           = "Environment"
        values        = ["org"]
        match_options = ["EQUALS"]
      }
    }
  }

  default_value = "untagged"
}

resource "aws_ce_cost_category" "project" {
  name         = "gibson-project"
  rule_version = "CostCategoryExpression.v1"

  rule {
    value = "gibson"
    # type is always "REGULAR" for tag-expression rules; the CE API returns
    # it even when omitted, so leaving it implicit makes every plan show a
    # perpetual `- type = "REGULAR" -> null` no-op diff (deploy#696).
    type = "REGULAR"
    rule {
      tags {
        key           = "Project"
        values        = ["gibson"]
        match_options = ["EQUALS"]
      }
    }
  }

  default_value = "untagged"
}
