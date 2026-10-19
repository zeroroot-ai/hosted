# RUNBOOK — ArgoCD ops SSO via a pluggable Dex connector (github | gitlab | oidc)

Wires ArgoCD (prod + staging) to an operator identity provider for sign-in,
through ArgoCD's **bundled Dex**. The provider is **pluggable**:

- **github** — zeroroot's own ops plane (org `zeroroot-ai`). GitHub is **not**
  OIDC-compliant, so it MUST go through Dex's `github` connector.
- **gitlab** — for on-prem customers on GitLab (SaaS or self-managed).
- **oidc** — for on-prem customers with any generic OIDC IdP (Okta, Keycloak,
  Entra ID, …).

Reworks deploy#1332 (which wired AWS Identity Center SAML). Tracks deploy#1214.

## Why a separate ops identity plane

Ops SSO is deliberately a **separate identity plane from Zitadel** (the customer
IdP) for blast-radius: an ArgoCD/ops-console compromise must not reach the
customer control plane, and vice versa. That is why this does not reuse Zitadel
and does not run through the platform's customer auth chain.

## What Terraform owns, and what you do by hand

| Owned by Terraform | Owned by you (this runbook) |
|---|---|
| The Dex connector + `url` + `policy.csv` group→role, in `bootstrap/modules/argocd` | Creating the OAuth app in the provider (GitHub/GitLab/OIDC) |
| Break-glass local admin (kept enabled, SM-stored) | Supplying the client id/secret and admin-group values as TF vars |
| Delivery of the client secret into `argocd-secret` (`$dex.sso.clientSecret`) | Confirming the group value the provider emits |

Unlike the former SAML path (certificate-based, no client secret), **all three
providers issue an OAuth client secret.** It is delivered to Dex through the
`argocd-secret` key that the connector references as `$dex.sso.clientSecret`
(wired from `argocd_sso_client_secret` via `configs.secret.extra`), so it never
lands in the `argocd-cm` ConfigMap. Pass it as `TF_VAR_argocd_sso_client_secret`
so it never lands in version control.

## The TF variables (per cluster, in `eks/{prod,staging}`)

| Root var | Module var | Meaning |
|---|---|---|
| `argocd_sso_provider` | `sso_provider` | `none` (default) \| `github` \| `gitlab` \| `oidc` |
| `argocd_sso_client_id` | `sso_client_id` | OAuth app client id (public) |
| `argocd_sso_client_secret` | `sso_client_secret` | OAuth app client secret (secret; pass via `TF_VAR_…`) |
| `argocd_sso_github_org` | `sso_github_org` | GitHub org (github only; default `zeroroot-ai`) |
| `argocd_sso_base_url` | `sso_base_url` | GitLab base URL (gitlab) or OIDC issuer URL (oidc) |
| `argocd_sso_admin_group` | `sso_admin_group` | Group subject → ArgoCD `role:admin` |

`argocd_sso_admin_group` format is **provider-specific**:

- **github** → `"<org>:<team-slug>"`, e.g. `zeroroot-ai:platform-admins`
  (prod/staging default).
- **gitlab** → the group **path**, e.g. `platform/admins`.
- **oidc** → the **raw value of the group claim** your IdP emits.

`sso_provider=github` requires `sso_github_org`; `sso_provider=gitlab` and
`sso_provider=oidc` require `sso_base_url`. These are enforced by preconditions
on the `helm_release` — a missing value fails `terraform plan`, not silently at
runtime.

## Order of operations (two-phase, deliberate)

SSO cannot be proven before the OAuth app exists, and the local admin must NOT
be disabled until it is — so this is intentionally a two-apply flow.

### Phase 0 — bring ArgoCD up on break-glass admin

Apply `eks/{staging,prod}` normally with `argocd_sso_provider=none` (the
default). The Dex connector is omitted and ArgoCD comes up on **local admin
only**. Read the bootstrap admin password:

```
aws secretsmanager get-secret-value \
  --secret-id "$ARGOCD_ADMIN_SECRET_ID"   # the operator supplies it; not named here (hosted#108) --query SecretString --output text
```

Reach the UI over the internal ALB via port-forward:

```
kubectl -n argocd port-forward svc/argocd-server 8080:80   # then http://localhost:8080
```

### Phase 1 — create the OAuth app in the provider

#### GitHub (zeroroot ops)

Create a **GitHub OAuth App** in the **`zeroroot-ai` org**
(`https://github.com/organizations/zeroroot-ai/settings/applications` →
**New OAuth App**):

- **Application name:** `ArgoCD (staging)` / `ArgoCD (prod)` — one app per
  cluster, since each has a distinct callback host.
- **Homepage URL:** `https://argocd.<route53_zone_name>` (e.g.
  `https://argocd.zeroroot.ai`).
- **Authorization callback URL:**
  `https://argocd.<route53_zone_name>/api/dex/callback`.

Generate a **client secret**. Note the **Client ID** and **client secret**.

> The ALB is internal, so `argocd.<zone>` resolves only inside the VPC — the
> OAuth round-trip happens in the operator's VPC/port-forwarded browser session.

Create a **team** in the org (e.g. `platform-admins`) and put the operators who
should get ArgoCD admin in it. The Dex github connector reads team membership;
`teamNameField="slug"` means the admin-group subject is `<org>:<team-slug>`,
i.e. `zeroroot-ai:platform-admins`.

#### GitLab (on-prem variant)

GitLab → **Applications** (group- or instance-level) → new application:

- **Redirect URI:** `https://argocd.<zone>/api/dex/callback`.
- **Scopes:** `read_user`, `openid`, plus `read_api` if group claims are needed.

Set `argocd_sso_base_url` to the GitLab base URL (e.g. `https://gitlab.com` or
your self-managed host). Set `argocd_sso_admin_group` to the **group path**.

#### Generic OIDC (on-prem variant)

Register a confidential OIDC client in your IdP:

- **Redirect URI:** `https://argocd.<zone>/api/dex/callback`.
- Ensure the IdP emits a **`groups`** claim (the connector sets
  `insecureEnableGroups=true` and requests scope `groups`).

Set `argocd_sso_base_url` to the **issuer URL**, and `argocd_sso_admin_group`
to the raw group-claim value that should map to admin.

### Phase 2 — wire the connector

In `eks/{staging,prod}/terraform.tfvars` (GitHub example):

```hcl
argocd_sso_provider   = "github"
argocd_sso_client_id  = "<oauth app client id>"
argocd_sso_github_org = "zeroroot-ai"
argocd_sso_admin_group = "zeroroot-ai:platform-admins"
```

Apply with the secret out of version control:

```
TF_VAR_argocd_sso_client_secret='<oauth app client secret>' terraform apply
```

GitLab: set `argocd_sso_provider="gitlab"`, `argocd_sso_base_url="https://gitlab.com"`,
`argocd_sso_admin_group="<group/path>"`. OIDC: set `argocd_sso_provider="oidc"`,
`argocd_sso_base_url="<issuer url>"`, `argocd_sso_admin_group="<group claim>"`.

The Dex connector now renders and the ArgoCD login page shows a **LOG IN VIA
&lt;provider&gt;** button.

### Phase 3 — verify, then treat local admin as break-glass

1. Log in via SSO as a member of the admin group; confirm you land with admin
   rights (all apps visible, sync allowed).
2. If RBAC does not behave, confirm the emitted group value. Turn up Dex/argocd
   log verbosity, or inspect the ID token / userinfo the connector received, and
   set `argocd_sso_admin_group` to the exact value the provider emits (github:
   `<org>:<team-slug>`; gitlab: group path; oidc: the raw claim), then re-apply.
3. Local admin is now **break-glass**: keep it enabled, keep the SM password
   rotated. **Only after SSO is proven on BOTH clusters** is disabling it a
   separate follow-up PR (`configs.cm."admin.enabled" = false`) — do not disable
   it blind, there is no live ArgoCD to validate a login against yet.

## Reverting

- Set `argocd_sso_provider = "none"` and re-apply → the Dex connector and the
  `$dex.sso.clientSecret` key disappear, ArgoCD falls back to local admin. The
  OAuth app in the provider can remain.
- Full removal: delete the OAuth app in the provider.
