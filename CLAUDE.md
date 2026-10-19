# hosted — CLAUDE.md

> **Workflow rules:** see [`zeroroot-ai/.github` → `AGENTS.md`](https://github.com/zeroroot-ai/.github/blob/main/AGENTS.md) — canonical for branching / commits / PRs / releases / merging. Conventional Commits MANDATORY. Never push to main. Never force-push.

This file is the per-repo addendum. Workspace-wide concerns live in the workspace `CLAUDE.md` and in [`AGENTS.md`](https://github.com/zeroroot-ai/.github/blob/main/AGENTS.md).

## TL;DR

ZeroRoot's own estate: the Terraform, the bringup verbs, the Argo tree and the SaaS overlay. It **consumes** the chart, it never holds chart source. Start with `make check`, the static gates. A change is done when its PR merges with a green merge gate and `Closes #N`.

## Architecture

This repo installs a published, signed OCI chart at a pinned version — the same artifact a customer installs. It holds no `helm/**/templates/`, and a guard fails the build on any such path. Chart source lives in [`zeroroot-ai/charts`](https://github.com/zeroroot-ai/charts).

Three directories, because there are three lifecycles (ADR-0083):

| Directory | Stage | A teardown |
|---|---|---|
| `substrate/` | 0 — durable bucket, DNS sub-zone, SMTP relay, bringup keyring | **leaves it alone, in both modes** |
| `bootstrap/` | 1 — VPC, cluster, node groups, Argo CD | destroys it |
| `gitops/` | 2 — the platform, synced by Argo, plus the SaaS overlay | goes with stage 1 |

Stage 0 and stage 1 have **opposite lifecycles and different state storage**: stage 0 keeps Terraform state local under `/bulk/substrate/<env>`, stage 1 uses the durable bucket as its backend. They are separate directories because sharing one is how a `terraform destroy` reaches the bucket it must never touch.

## The verbs

`ENV` is always explicit. There is no default, on purpose.

```sh
make substrate ENV=kind                    # stage 0, once per workstation
make preflight ENV=kind                    # prove every line of substrate.env live
make recreate  ENV=kind                    # preflight -> stage 1 -> stage 2
make teardown  ENV=kind MODE=wipe|preserve # MODE has no default, on purpose
make check                                 # the static gates
make restart-<svc>                         # daemon | dashboard | ext-authz | tenant-operator | platform-operator
```

`make restart-<svc>` is the only inner-loop primitive. No Tilt.

## Gotchas

- **Never mutate a live cluster.** No `kubectl patch`, no hand-edited ConfigMap or Secret, not even in kind. Change flows through the chart in `charts` and the Argo tree in `gitops/`. The same goes for a database: fix the producer, never the row.
- **`MODE` on teardown has no default.** `wipe` and `preserve` differ in what survives, and guessing is how an estate disappears.
- **A healthy-looking cluster can be serving stale secrets.** Nothing deletes a Secret when its source stops answering, so every pod stays Running while every ExternalSecret fails. Only Argo dissents, with one word. Check the ExternalSecrets, not the pods.
- **The gitops branch is `main` only.** There is no branch per environment; promotion is a per-env overlay on one branch.
- **Exit tests never run on a PR.** They run on `main` and on a schedule (ADR-0080). The merge gate is the merge criterion. A green exit test is not, and no manual cluster run is.
- **ArgoCD ops uses its own IdP, not Zitadel.** They are different trust paths; do not wire one to the other.

## Links

- Org-level workflow: [`AGENTS.md`](https://github.com/zeroroot-ai/.github/blob/main/AGENTS.md)
- The chart this installs: [`zeroroot-ai/charts`](https://github.com/zeroroot-ai/charts)
- Glossary and settled decisions: [`CONTEXT.md`](CONTEXT.md)
- Workspace map: workspace `CLAUDE.md`
