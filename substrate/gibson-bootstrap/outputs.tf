# Outputs feed substrate.sh, which writes the keyring and substrate.env. The
# sensitive ones reach the keyring file and nothing else.

output "bucket_name" {
  description = "The durable bucket. Also the s3 backend bucket of eks/gibson for this env, key tfstate/eks-gibson/terraform.tfstate."
  value       = aws_s3_bucket.durable.id
}

output "bucket_region" {
  value = var.aws_region
}

output "bucket_endpoint" {
  description = "S3 endpoint preflight and the platform address the bucket at."
  value       = "https://s3.${var.aws_region}.amazonaws.com"
}

output "platform_access_key_id" {
  description = "Keyring member BUCKET_ACCESS_KEY."
  value       = aws_iam_access_key.platform[var.key_slots["platform"].active].id
  sensitive   = true
}

output "platform_secret_access_key" {
  description = "Keyring member BUCKET_SECRET_KEY."
  value       = aws_iam_access_key.platform[var.key_slots["platform"].active].secret
  sensitive   = true
}

output "dns_access_key_id" {
  description = "Keyring member DNS_ACCESS_KEY."
  value       = aws_iam_access_key.dns[var.key_slots["dns"].active].id
  sensitive   = true
}

output "dns_secret_access_key" {
  description = "Keyring member DNS_SECRET_KEY."
  value       = aws_iam_access_key.dns[var.key_slots["dns"].active].secret
  sensitive   = true
}

output "setec_disk_repo" {
  description = "substrate.env SETEC_DISK_REPO: the repository URL of the signed setec sandbox disks (D85). The overlay of the env names the same URL as setec.launcher.diskRepo."
  value       = aws_ecr_repository.setec_disks.repository_url
}

output "belief_trainer_repo" {
  description = "substrate.env BELIEF_TRAINER_REPO: the repository URL of the belief trainer image copy (gibson#31). The overlay of the env names the same URL as gibson-operators.tenantOperator.beliefTrainer.image.repository."
  value       = aws_ecr_repository.belief_trainer.repository_url
}

output "setec_disk_builder_access_key_id" {
  description = "Keyring member SETEC_DISK_PUSH_ACCESS_KEY: the disk builder push credential."
  value       = aws_iam_access_key.setec_disk_builder[var.key_slots["setec-disk-builder"].active].id
  sensitive   = true
}

output "setec_disk_builder_secret_access_key" {
  description = "Keyring member SETEC_DISK_PUSH_SECRET_KEY."
  value       = aws_iam_access_key.setec_disk_builder[var.key_slots["setec-disk-builder"].active].secret
  sensitive   = true
}

output "smtp_host" {
  value = local.smtp_host
}

output "smtp_port" {
  value = var.smtp_port
}

output "smtp_user" {
  description = "substrate.env SMTP_USER: the SES SMTP user's access key id, or the operator's relay user."
  value       = local.ses_relay ? aws_iam_access_key.smtp[var.key_slots["smtp"].active].id : var.smtp_user
  sensitive   = true
}

output "smtp_password" {
  description = "Keyring member SMTP_PASSWORD: the SES SMTP password (v4, bound to aws_region), or the operator's relay password."
  value       = local.ses_relay ? aws_iam_access_key.smtp[var.key_slots["smtp"].active].ses_smtp_password_v4 : var.smtp_password
  sensitive   = true
}

output "zone_name" {
  value = var.zone_name
}

output "zone_id" {
  description = "Hosted zone id of the environment's zone. eks/gibson reads the zone by name as a data source, never through this output."
  value       = local.zone_id
}

output "zone_nameserver" {
  description = "One authoritative nameserver of the environment's zone, for the preflight NS check."
  value       = local.zone_name_servers[0]
}

output "apex_zone_name" {
  value = var.apex_zone_name
}

output "apex_zone_nameserver" {
  description = "One authoritative nameserver of the apex, for the preflight mail-record check."
  value       = data.aws_route53_zone.apex.name_servers[0]
}

output "apex_dkim_selectors" {
  description = "DKIM selectors preflight expects on the apex: Google Workspace's, then the SES Easy DKIM tokens of the relay region."
  value       = concat(["google"], sort(data.aws_sesv2_email_identity.apex.dkim_signing_attributes[0].tokens))
}

# Recorded, not created: no API installs a GitHub App. substrate.sh writes
# both into substrate.env, and the App's private key stays in the keyring.
output "argocd_github_app_id" {
  description = "Argo CD GitHub App id (public)"
  value       = var.argocd_github_app_id
}

output "argocd_github_app_installation_id" {
  description = "Argo CD GitHub App installation id (public)"
  value       = var.argocd_github_app_installation_id
}

# The access key ids of each user, by slot, for scripts/substrate-rotate.sh.
# Ids are not secrets.
output "access_key_ids" {
  description = "The access key id in each slot of each substrate IAM user."
  value = {
    platform = { for k, v in aws_iam_access_key.platform : k => v.id }
    smtp     = { for k, v in aws_iam_access_key.smtp : k => v.id }
    dns      = { for k, v in aws_iam_access_key.dns : k => v.id }

    setec-disk-builder = { for k, v in aws_iam_access_key.setec_disk_builder : k => v.id }
  }
}

output "inbox_domain" {
  description = "The test mail domain of this environment. The signup driver signs up as <slug>@this domain (hosted#647)."
  value       = local.inbox_domain
}

output "inbox_bucket" {
  description = "The bucket that holds the test mail of inbox_domain for one day (hosted#647)."
  value       = aws_s3_bucket.inbox.id
}

output "edge_cert_secret" {
  description = "The Secrets Manager secret that keeps the edge TLS certificate of this environment across recreates."
  value       = aws_secretsmanager_secret.edge_cert.name
}

output "keyring_secret" {
  description = "The Secrets Manager secret that holds the keyring and substrate.env of this environment (keyring-secret.tf)."
  value       = aws_secretsmanager_secret.keyring.name
}

output "rotation_role_arn" {
  description = "The key rotation role (rotation-role.tf). Set it as the variable KEY_ROTATION_ROLE_ARN of the GitHub environment of this env. Empty when the role is off."
  value       = var.rotation_role_enabled ? aws_iam_role.rotation[0].arn : ""
}

output "keyring_reader_role_arn" {
  description = "The keyring reader role (keyring-reader-role.tf). Set it as the variable KEYRING_READER_ROLE_ARN of the GitHub environment of this env. Empty when the role is off."
  value       = var.keyring_reader_role_enabled ? aws_iam_role.keyring_reader[0].arn : ""
}
