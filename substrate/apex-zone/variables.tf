variable "apex_domain" {
  description = "The registered apex domain. This workspace owns its hosted zone and its mail records. There is exactly one."
  type        = string
  default     = "zeroroot.ai"

  validation {
    condition     = var.apex_domain == "zeroroot.ai"
    error_message = "This workspace owns the zeroroot.ai apex and nothing else. A second apex is a second workspace."
  }
}

variable "apex_zone_id" {
  description = "The live hosted zone id. Used only by the import block, so a lost state re-imports the zone instead of creating a second one. REQUIRED: supplied per run, never defaulted, so the live id is not committed (hosted#108)."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{10,}$", var.apex_zone_id))
    error_message = "apex_zone_id must be a Route53 hosted zone id. Read it with: aws route53 list-hosted-zones-by-name --dns-name zeroroot.ai."
  }
}

variable "inbox_rule_set_name" {
  description = "The one active SES receipt rule set of the account (hosted#647). Each environment's stage 0 adds its own rule to it."
  type        = string
  default     = "zeroroot-ai-inbox"
}
