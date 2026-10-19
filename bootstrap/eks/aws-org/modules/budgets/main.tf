# ----------------------------------------------------------------------------
# AWS Budgets — three thresholds + email-only SNS subscription.
#
# No Lambda actions, no auto-cutoff, no paid pager destinations. R10.1.
# ----------------------------------------------------------------------------

resource "aws_sns_topic" "cost_alerts" {
  name              = "zeroroot-ai-prod-cost-alerts"
  display_name      = "zeroroot-ai-prod cost alerts"
  kms_master_key_id = "alias/aws/sns" # AWS-managed key — no PHI here, no need for CMK.

  tags = {
    Name = "zeroroot-ai-prod-cost-alerts"
  }
}

resource "aws_sns_topic_subscription" "cost_alerts_email" {
  topic_arn = aws_sns_topic.cost_alerts.arn
  protocol  = "email"
  endpoint  = var.alerts_email_address

  # Email subscriptions require manual confirmation via the link AWS sends
  # to var.alerts_email_address. The subscription remains "PendingConfirmation"
  # until the operator clicks. Document in README.
}

# ----------------------------------------------------------------------------
# Three budgets at the soft / hard / emergency tiers.
# ----------------------------------------------------------------------------

resource "aws_budgets_budget" "soft" {
  name              = "zeroroot-ai-prod-monthly-soft"
  budget_type       = "COST"
  limit_amount      = tostring(var.soft_alert_amount)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  cost_filter {
    name = "TagKeyValue"
    values = [
      "user:Project$gibson",
    ]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alerts_email_address]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alerts_email_address]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }
}

resource "aws_budgets_budget" "hard" {
  name              = "zeroroot-ai-prod-monthly-hard"
  budget_type       = "COST"
  limit_amount      = tostring(var.hard_alert_amount)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  cost_filter {
    name = "TagKeyValue"
    values = [
      "user:Project$gibson",
    ]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alerts_email_address]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }
}

resource "aws_budgets_budget" "emergency" {
  name              = "zeroroot-ai-prod-monthly-emergency"
  budget_type       = "COST"
  limit_amount      = tostring(var.emergency_alert_amount)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  cost_filter {
    name = "TagKeyValue"
    values = [
      "user:Project$gibson",
    ]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alerts_email_address]
    subscriber_sns_topic_arns  = [aws_sns_topic.cost_alerts.arn]
  }
}
