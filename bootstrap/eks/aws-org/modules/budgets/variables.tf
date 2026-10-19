variable "alerts_email_address" {
  description = "Email destination for SNS subscription. Email-only per R10.1."
  type        = string
}

variable "soft_alert_amount" {
  description = "Soft (80% / forecasted-100%) alert threshold in USD. Default 1000."
  type        = number
  default     = 1000
}

variable "hard_alert_amount" {
  description = "Hard (100% actual) alert threshold in USD. Default 3000."
  type        = number
  default     = 3000
}

variable "emergency_alert_amount" {
  description = "Emergency (100% actual) alert threshold in USD. Triggers RUNBOOK-cost-cutoff.md. Default 5000."
  type        = number
  default     = 5000
}
