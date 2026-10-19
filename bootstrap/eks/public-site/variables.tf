variable "aws_region" {
  description = "Region for this workspace. Must be us-east-1: CloudFront reads its ACM certificates from that region only, and the org SCP pins everything else there anyway."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.aws_region == "us-east-1"
    error_message = "aws_region must be us-east-1 — CloudFront certificates are read from us-east-1 only."
  }
}

variable "apex_domain" {
  description = "The registered apex domain whose hosted zone already exists (e.g. zeroroot.ai). Read as a data source; this workspace never creates or owns the zone."
  type        = string
  default     = "zeroroot.ai"
}

variable "sales_inbox" {
  description = "Address the contact-sales SNS topic emails. The subscription is created PendingConfirmation; a human must confirm it before any lead is delivered."
  type        = string
  default     = "sales@zeroroot.ai"
}
