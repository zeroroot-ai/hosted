# pending — Applications the staging app-of-apps does not load yet

The app-of-apps reads `envs/staging/*.yaml` without recursing (bootstrap
`bootstrap/modules/argocd/main.tf`), so a file in this directory is not an
Application until it moves back up one level.

## arc-controller.yaml, arc-runners.yaml

The GitHub Actions runner scale set for the demo estate. Moved here on
2026-09-10, the first staging recreate from fresh: `arc-runners-zeroroot`
sat Degraded and held the recreate's stage 2 wait open, because its
`ExternalSecret arc-github-app` reads `gibson/staging/arc-github-app`
(property `github_token`) from a ClusterSecretStore named
`aws-secretsmanager` that nothing in the estate creates, and nothing seeds
that secret. The platform's one store is `gibson-secrets` (OpenBao).

To bring ARC back:

1. Create a second org GitHub App for the runners with the permissions ARC
   needs to register a scale set (Actions and Administration on the org),
   distinct from `zeroroot-argocd`, which is read-only.
2. Decide where its credential lives. Either an AWS Secrets Manager
   ClusterSecretStore with `gibson/staging/arc-github-app`, or an OpenBao
   key seeded through the keyring contract, and point the ExternalSecret at
   that store.
3. `git mv` both files back to `envs/staging/` in one PR, then
   `make recreate ENV=staging`.
