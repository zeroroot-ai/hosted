# STAGING, stage 0 of ADR-0083. Applied by `make substrate ENV=staging`,
# which selects this file and the state directory from the one ENV. See
# README.md before a run by hand.

environment    = "staging"
aws_account_id = "447184491447"
cost_center    = "platform-staging"

# A sub-zone: this workspace creates staging.zeroroot.ai and delegates it with
# one NS record in the apex, which eks/apex-zone owns.
zone_name      = "staging.zeroroot.ai"
apex_zone_name = "zeroroot.ai"

# Staging is torn down at will and, one day, decommissioned. GOVERNANCE lets
# the account owner bypass the audit lock on that day. Prod uses COMPLIANCE.
audit_lock_mode = "GOVERNANCE"

# SMTP: SES through email-smtp.us-east-1.amazonaws.com:587 with a created IAM
# user (the defaults). Set smtp_host, smtp_port, smtp_user and smtp_password
# together to bring another relay.

# Argo CD's app-of-apps clones zeroroot-ai/hosted, which is private, so it
# needs a credential. No API creates or installs a GitHub App: an operator
# makes it in the UI once and records its two PUBLIC ids here. The App's
# private key is a secret and lives in the keyring, base64-encoded:
#   scripts/keyring.sh set <keyring> GITHUB_APP_PRIVATE_KEY "$(base64 -w0 < app.pem)"

# argocd_github_app_id / argocd_github_app_installation_id are NOT here.
# They identify the installation that can clone every gitops source, so they
# are supplied per run instead of committed (hosted#108):
#
#   export TF_VAR_argocd_github_app_id=<id>
#   export TF_VAR_argocd_github_app_installation_id=<installation id>
#
# Terraform reads TF_VAR_* with no extra wiring. Both variables default to "",
# which is what an environment whose Argo needs no credential wants, so
# forgetting them fails loudly at preflight rather than silently here.

# The edge TLS secret (edge-cert.tf). Staging is recreated from a workstation
# (ADR-0095: `make recreate ENV=staging`) as OrganizationAccountAccessRole, so
# that role runs the teardown and the bringup of staging. No CI role runs
# them: eks-bringup is the role of prod, and staging-bringup only promotes.
edge_cert_principal_role_names = ["OrganizationAccountAccessRole"]

# The test inbox (inbox.tf). The staging promotion reads it as staging-bringup
# (bootstrap/eks/aws-org/github-oidc-staging.tf), not as eks-bringup.
inbox_reader_role_name = "staging-bringup"

# The key rotation role (rotation-role.tf): the access keys of this env rotate in
# .github/workflows/rotate-credentials.yml.
rotation_role_enabled = true

# preflight.yml reads the keyring with this role (keyring-reader-role.tf).
keyring_reader_role_enabled = true

# The stage 0 state of staging, its key slots and its rotation record live in its
# own durable bucket, zeroroot-ai-staging-durable-<account>, under tfstate/stage0/,
# with S3 native lock files, as drill does (backend.tf, scripts/stage0-store.sh,
# hosted#97). Its keyring lives in the Secrets Manager secret
# zeroroot-ai/staging/keyring. The bucket policy lets two principals read and
# write tfstate/stage0/: the key rotation role of staging and the operator role
# below. The bringup role is not one of them.
stage0_state_principal_role_names = ["OrganizationAccountAccessRole"]
