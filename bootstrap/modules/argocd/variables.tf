
variable "git_repo_url" {
  description = "Git repository URL ArgoCD watches. Default: https://github.com/zeroroot-ai/hosted, which carries the Argo tree under gitops/ (ADR-0086)."
  type        = string
  default     = "https://github.com/zeroroot-ai/hosted"
}

variable "git_revision" {
  description = "Git ref ArgoCD tracks (branch, tag, or SHA). Default: main."
  type        = string
  default     = "main"
}

variable "route53_zone_name" {
  description = "Public hosted zone (e.g. zeroroot.ai). Used for argocd.<zone>."
  type        = string
}




variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (subchart of argo-helm)."
  type        = string
  # 10.11.6 is the chart the kind dev cluster runs (bootstrap/kind/gibson,
  # argocd_version), so every environment runs one Argo CD. It is Argo CD
  # 3.5.6. Argo CD 3.0.x (chart 8.1.3) stranded a child Application at phase
  # Running when its parent synced (argoproj/argo-cd#29253, fixed by #28201 in
  # 3.4.4), and the drill failed on it (hosted#24). 7.7.5 was Argo CD 2.13.1,
  # whose ServerSideDiff broke on
  # cert-manager Certificates: "error reverting webhook removed fields in
  # predicted live resource: .status.conditions: element 0: associative
  # list with keys may not have a null element" (argoproj/argo-cd#22375,
  # fixed in v2.14.8). The first staging recreate from fresh (2026-09-10)
  # spent every umbrella sync retry on exactly that ComparisonError.
  default = "10.11.6"
}


variable "app_of_apps_path" {
  description = <<-EOT
    Path inside the Argo tree that the bootstrap App-of-Apps Application
    points at. Must be a directory whose top-level *.yaml are Argo
    Application CRs. The directory source is NON-recursive (`recurse = false`
    in main.tf) and excludes the plain Helm values files that live alongside
    them — see the comment on that argument for why both are deliberate.

    Per-env clusters pass their env's overlay path: "gitops/envs/prod" for
    the production EKS cluster, "gitops/envs/staging" for staging (ADR-0072).

    REQUIRED, deliberately no default (deploy#1395). This variable used to
    default to "apps/prod" — a tree that was retired — so any
    caller that forgot to pass it pointed a live cluster at a path that does
    not exist, and did so silently. A missing overlay path must be a
    plan-time error.
  EOT
  type        = string

  validation {
    # drill is the throwaway environment of ADR-0095. It has its own overlay,
    # and this rule refused it: the drill teardown and recreate stopped here
    # on 2026-10-06 (run 37413963774).
    condition     = can(regex("^gitops/envs/(staging|drill|prod)$", var.app_of_apps_path))
    error_message = "app_of_apps_path must be gitops/envs/staging, gitops/envs/drill or gitops/envs/prod — the Argo tree lives under gitops/ in this repo (ADR-0086)."
  }
}

# ----------------------------------------------------------------------------
# Per-env platform axes (deploy#1397). Each list is APPENDED, in order, to the
# module's own baseline — the baseline is what every env's umbrella renders,
# these are what one env renders. Empty on prod today.
# ----------------------------------------------------------------------------

variable "extra_managed_api_groups" {
  description = "API groups the application-controller may manage beyond the platform baseline in controller-rbac.tf."
  type        = list(string)
  default     = []
}

variable "extra_platform_namespaces" {
  description = "Namespaces the `default` AppProject may target beyond argocd/gibson/zitadel."
  type        = list(string)
  default     = []
}

variable "extra_platform_source_repos" {
  description = "Source repos the `default` AppProject may pull from beyond the three first-party ones."
  type        = list(string)
  default     = []
}

variable "extra_cluster_resources" {
  description = "Cluster-scoped kinds the `default` AppProject may apply beyond the platform baseline."
  type = list(object({
    group = string
    kind  = string
  }))
  default = []
}

# The argocd module no longer takes a github_pat (ADR-0083). ArgoCD's repo-creds
# Secret is seeded from the org GitHub App by scripts/keyring-to-cluster.sh, and
# the umbrella chart's OCI package is public, so no credential flows through
# Terraform. See main.tf.



# ----------------------------------------------------------------------------
# Ops SSO — a PLUGGABLE github | gitlab | oidc identity plane through the
# bundled Dex (reworks deploy#1332, which wired AWS Identity Center SAML;
# deploy#1214).
#
# This is deliberately a SEPARATE identity plane from Zitadel (the customer
# IdP) for blast-radius: an ops-console compromise must not reach the customer
# control plane and vice versa. zeroroot's own ops use GitHub (org zeroroot-ai);
# on-prem customers pick github, gitlab, or generic OIDC. GitHub is NOT
# OIDC-compliant, so it MUST route through Dex's github connector; gitlab and
# oidc route through Dex too, for one uniform mechanism.
#
# All three providers have an OAuth client secret (SAML did not) — it is
# delivered to Dex via configs.secret.extra as "$dex.sso.clientSecret", never
# inlined into argocd-cm. Until a provider is selected the Dex connector is
# omitted and ArgoCD comes up on local break-glass admin only, then SSO is
# wired on a re-apply. See eks/aws-org/runbooks/RUNBOOK-argocd-sso.md.
# ----------------------------------------------------------------------------

variable "sso_provider" {
  description = <<-EOT
    Ops SSO provider, routed through the bundled Dex. One of:
      - "none"   (default) — no Dex connector; local break-glass admin only.
      - "github" — Dex github connector (GitHub is not OIDC-compliant).
      - "gitlab" — Dex gitlab connector.
      - "oidc"   — Dex generic OIDC connector.
    github additionally requires sso_github_org; gitlab and oidc require
    sso_base_url (enforced by preconditions on the helm_release).
  EOT
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "github", "gitlab", "oidc"], var.sso_provider)
    error_message = "sso_provider must be one of: none, github, gitlab, oidc."
  }
}

variable "sso_client_id" {
  description = "OAuth application client ID for the selected SSO provider. Public identifier, not a secret. Unused when sso_provider=none."
  type        = string
  default     = ""
}

variable "sso_client_secret" {
  description = <<-EOT
    OAuth application client secret for the selected SSO provider. Unlike the
    former SAML path (certificate-based, no client secret), github/gitlab/oidc
    all issue one. Delivered to Dex as the argocd-secret key referenced by
    "$dex.sso.clientSecret" in the connector config (configs.secret.extra), so
    it never lands in the argocd-cm ConfigMap. Pass via
    TF_VAR_argocd_sso_client_secret so it never lands in version control; state
    stores it sensitively. Unused when sso_provider=none.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "sso_github_org" {
  description = <<-EOT
    GitHub organization whose membership gates login (Dex github connector
    `orgs`). REQUIRED when sso_provider=github; unused otherwise. e.g.
    zeroroot-ai.
  EOT
  type        = string
  default     = ""
}

variable "sso_base_url" {
  description = <<-EOT
    For sso_provider=gitlab: the GitLab base URL (e.g. https://gitlab.com). For
    sso_provider=oidc: the OIDC issuer URL. REQUIRED for gitlab and oidc;
    unused for github and none.
  EOT
  type        = string
  default     = ""
}

variable "sso_admin_group" {
  description = <<-EOT
    The group subject mapped to ArgoCD role:admin in configs.rbac policy.csv.
    Per-provider format:
      - github → "<org>:<team-slug>"  e.g. "zeroroot-ai:platform-admins"
      - gitlab → the group path       e.g. "platform/admins"
      - oidc   → the raw value of the group claim
    Defaults to "argocd-admins"; set it to match what the provider emits.
  EOT
  type        = string
  default     = "argocd-admins"
}


variable "app_of_apps_enabled" {
  description = "Create the app-of-apps Application. The recreate verb sets it false for the one window a restore needs: the secret store comes back before the platform Application exists (ADR-0083, deploy#1746)."
  type        = bool
  default     = true
}
