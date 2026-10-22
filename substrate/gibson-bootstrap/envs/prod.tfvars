# PRODUCTION, stage 0 of ADR-0083. Applied by `make substrate ENV=prod`,
# which selects this file and the local state path from the one ENV. Not yet
# applied: the prod estate still keeps its state in the old
# zeroroot-ai-prod-tfstate bucket (README.md § Prod).

environment    = "prod"
aws_account_id = "447184491447"
cost_center    = "platform-prod"

# Prod's zone IS the apex. This workspace creates no hosted zone and no NS
# record for prod. The apex is owned by eks/apex-zone.
zone_name      = "zeroroot.ai"
apex_zone_name = "zeroroot.ai"

# COMPLIANCE: no principal deletes a prod audit object before six years.
audit_lock_mode = "COMPLIANCE"

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

# The key rotation role (rotation-role.tf): the access keys of this env rotate in
# .github/workflows/rotate-credentials.yml.
rotation_role_enabled = true

# preflight.yml reads the keyring with this role (keyring-reader-role.tf).
keyring_reader_role_enabled = true
