# RUNBOOK — rollback

> **Audience:** stressed operator. One screen of context per scenario.
>
> **Spec linkage:** R11.2.

> **Environment.** Since deploy#1397 one Terraform root (`eks/gibson`) serves
> both environments, so this runbook does too. Export the env first —
> `export ENV=staging` or `export ENV=prod` — and every command below is
> copy-pasteable. In prose, `<env>` means the same thing.

---

## DNS cutover (Namecheap NS revert)

```text
Symptom: app.zeroroot.ai returns wrong content / NXDOMAIN globally.
Detect:  dig NS zeroroot.ai → not Route53 nameservers.
Root cause: a bad NS-record swap (Namecheap mistake or premature DNS update).
```

1. Sign in to Namecheap.
2. **Domain List → zeroroot.ai → Manage → Nameservers → BasicDNS**.
3. Save. Wait 5-30 min for propagation.
4. Confirm: `dig +short NS zeroroot.ai` shows Namecheap (`dns1.registrar-servers.com`).
5. Re-attempt cutover phase 3 once root cause is fixed.

> Once Namecheap is reverted, public traffic stops resolving to zeroroot-ai-<env>
> entirely. This is **only** a rollback for a bad cutover — not a fix for an
> in-cluster issue.

---

## ESO secret rotation rollback (SM previous-version restore)

```text
Symptom: a workload reads garbled / wrong creds after a secret rotation.
Detect:  pod logs show auth failures on previously-working SM secret.
Root cause: bad secret value seeded.
```

1. Identify the secret:
   ```bash
   SECRET_ID="gibson/${ENV}/<name>"
   aws secretsmanager describe-secret --secret-id "${SECRET_ID}"
   ```
2. List versions:
   ```bash
   aws secretsmanager list-secret-version-ids --secret-id "${SECRET_ID}" \
     --include-deprecated
   ```
3. Capture the previous version ID (the one BEFORE `AWSCURRENT`).
4. Move the staging label back:
   ```bash
   aws secretsmanager update-secret-version-stage \
     --secret-id "${SECRET_ID}" \
     --version-stage AWSCURRENT \
     --move-to-version-id <prev-version-id> \
     --remove-from-version-id <bad-version-id>
   ```
5. Confirm:
   ```bash
   aws secretsmanager get-secret-value --secret-id "${SECRET_ID}"
   ```
6. Restart consumer:
   ```bash
   kubectl rollout restart deployment/<consumer> -n gibson
   ```

---

## ArgoCD gitops-overlay re-pin

```text
Symptom: a bad gitops PR reconciled and broke a chart-side resource.
Detect:  Argo Application `gibson` shows Healthy=False or OutOfSync.
Root cause: bad commit on gitops main.
```

The `gibson` Application is multi-source (ADR-0071/ADR-0072):
`sources[0]` is the versioned OCI umbrella chart, `sources[1]` is the
gitops repo supplying the `envs/<env>/values.yaml` overlay at
`targetRevision: main`. A bad gitops commit arrives via `sources[1]`.

1. Find the last-good commit:
   ```bash
   cd <gitops repo>
   git log --oneline -20
   ```
2. Pin the overlay source temporarily via `kubectl patch` (this is one
   of the rare exceptions to NFR-O1 because it IS the rollback path):
   ```bash
   kubectl patch app -n argocd gibson --type json -p \
     '[{"op":"replace","path":"/spec/sources/1/targetRevision","value":"<last-good-sha>"}]'
   ```
3. Open a revert PR against gitops main:
   ```bash
   git revert <bad-commit>
   gh pr create --base main --title "revert: <message>"
   ```
4. After revert merges, unpin:
   ```bash
   kubectl patch app -n argocd gibson --type json -p \
     '[{"op":"replace","path":"/spec/sources/1/targetRevision","value":"main"}]'
   ```

---

## Chart version rollback (promotion regression)

```text
Symptom: a chart-version promotion introduced a regression.
Detect:  pods crash-looping right after envs/<env>/gibson.yaml bumped
         spec.sources[0].targetRevision.
Root cause: bad umbrella-chart version.
```

There is no operator-side helm release — ArgoCD installs the chart from
the OCI registry, so `helm history` / `helm rollback` do not apply.
Rollback is re-pinning the chart version, the same one-line lever as
promotion.

1. Find the previous chart version:
   ```bash
   cd <gitops repo>
   git log --oneline -5 -- envs/${ENV}/gibson.yaml
   ```
2. Open a gitops PR reverting `spec.sources[0].targetRevision` in
   `envs/<env>/gibson.yaml` to the previous version, and merge it. This
   is the normal path — the fix reconciles within one sync interval.
3. Break-glass only (customer-down and the PR cycle is too slow):
   ```bash
   kubectl patch app -n argocd gibson --type json -p \
     '[{"op":"replace","path":"/spec/sources/0/targetRevision","value":"<prev-chart-version>"}]'
   ```
   then land the gitops PR anyway so the pinned state is declared.
4. Confirm pods Ready:
   ```bash
   kubectl get pods -n gibson
   ```

---

## References

- `RUNBOOK-incident.md` for customer-facing communication during a
  rollback.
