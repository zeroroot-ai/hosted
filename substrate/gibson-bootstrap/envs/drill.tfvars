# DRILL, stage 0 of ADR-0083. Applied by `make substrate ENV=drill`, which
# selects this file and the local state path from the one ENV.
#
# `drill` is the throwaway environment (ADR-0095). It exists so the
# destroy-recreate-restore-smoke cycle and the ADR-0070 teardown-verify gate run
# against the real AWS shape without taking staging away from whoever is using
# it. Stage 0 is the part that OUTLIVES a drill: the bucket, the keyring, the
# SMTP relay and the delegated zone stay, and only stage 1 is destroyed between
# runs. Standing stage 0 up repeatedly would make the drill slow and would churn
# a delegated zone for no reason.

environment    = "drill"
aws_account_id = "447184491447"
cost_center    = "platform-drill"

# A sub-zone, delegated from the apex with one NS record that substrate/apex-zone
# owns. It must be its own zone and not a prefix inside staging's: a drill that
# wrote records into staging.zeroroot.ai would be editing the permanent
# environment's DNS, which is exactly the coupling this environment exists to
# avoid.
zone_name      = "drill.zeroroot.ai"
apex_zone_name = "zeroroot.ai"

# GOVERNANCE, like staging. A throwaway environment is decommissioned by
# definition, and the account owner must be able to bypass the audit lock on the
# day it goes. COMPLIANCE is for prod.
audit_lock_mode = "GOVERNANCE"

# SMTP: the SES defaults, as staging. The drill's smoke run signs a tenant up,
# so it sends mail like any other environment.

# argocd_github_app_id / argocd_github_app_installation_id are supplied per run
# through TF_VAR_*, not committed (hosted#108). Both default to "", so a missing
# one fails at preflight rather than silently here.

# The drill keeps its keyring and substrate.env in Secrets Manager, and its
# stage 0 state in the prod state bucket (ADR-0083 amendment of 2026-10-13):
# the drill rotates its own access keys (scripts/substrate-rotate.sh).
keyring_in_aws = true

# Drill rotates its keys in drill.yml as the bringup role, which then reads tfstate/stage0/.
stage0_state_principal_role_names = ["OrganizationAccountAccessRole", "eks-bringup"]
