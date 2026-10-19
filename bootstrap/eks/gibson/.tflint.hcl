# ----------------------------------------------------------------------------
# tflint configuration for the unified eks/gibson Terraform root.
#
# Plugins:
#   - terraform: built-in best-practice rules.
#   - aws: AWS-resource-aware lint rules.
#
# Disabled rules carry an inline comment justification.
# ----------------------------------------------------------------------------

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Tighten on common production gotchas.
rule "aws_db_instance_default_parameter_group" {
  enabled = true
}

rule "aws_iam_policy_no_statements_with_admin_access" {
  enabled = true
}

# Naming convention: snake_case for resource and variable identifiers.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Documentation: every variable and output must have a description.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Pin module + provider versions for reproducibility.
rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# Forbid unused declarations — they accumulate as deltas to the spec.
rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Allow `module.argocd` to call helm_release without pinning every chart
# transitively — chart versions are a deliberate var. This is a noisy
# rule on chart-installing modules; disable.
rule "terraform_module_pinned_source" {
  enabled = false # see comment above
}
