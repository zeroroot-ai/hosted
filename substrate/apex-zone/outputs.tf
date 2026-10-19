output "name_servers" {
  description = "The four name servers the registrar (Namecheap) delegates to. If these change, the registrar must change too."
  value       = aws_route53_zone.apex.name_servers
}

output "inbox_rule_set_name" {
  description = "The one active SES receipt rule set. Each environment's stage 0 adds its own inbox rule to it (hosted#647)."
  value       = aws_ses_active_receipt_rule_set.inbox.rule_set_name
}
