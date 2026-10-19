variable "name" {
  description = "Short identifier for the surface this lead path belongs to (e.g. \"www\")."
  type        = string
}

variable "sales_inbox" {
  description = "Address the SNS topic emails. The subscription is created PendingConfirmation; a human must click the link AWS sends before any lead is delivered."
  type        = string
}

