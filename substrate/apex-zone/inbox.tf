# ----------------------------------------------------------------------------
# The one active SES receipt rule set of the account (hosted#647).
#
# SES keeps ONE active receipt rule set per account and region. Staging,
# drill and prod share account 447184491447 and us-east-1, so no environment
# can own the set: the second activation would replace the first. This
# workspace owns the set and its activation, once. Each environment's stage 0
# (substrate/gibson-bootstrap/inbox.tf) adds only its own rule to it, for its
# own `inbox.<env domain>`, with its own bucket and MX record.
#
# No teardown reaches this workspace (scripts/check-apex-zone-ownership.py),
# and no other root may declare a rule set (scripts/check-ses-rule-set-owner.py).
# ----------------------------------------------------------------------------

resource "aws_ses_receipt_rule_set" "inbox" {
  rule_set_name = var.inbox_rule_set_name
}

resource "aws_ses_active_receipt_rule_set" "inbox" {
  rule_set_name = aws_ses_receipt_rule_set.inbox.rule_set_name
}
