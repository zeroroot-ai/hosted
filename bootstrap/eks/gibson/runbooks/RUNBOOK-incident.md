# RUNBOOK — incident response

> **Audience:** the engineer declaring an incident.
>
> **Spec linkage:** R11.4.
>
> **Template usage:** copy this file to `enterprise/deploy/docs/incident-<date>-<id>.md`,
> fill in.

---

## Incident metadata

| Field | Value |
|---|---|
| Incident ID | inc-<YYYY-MM-DD>-<short-slug> |
| Severity | SEV-1 / SEV-2 / SEV-3 |
| Declared at | <ISO timestamp> |
| Declared by | <name> |
| Commander | <name> |
| Status | Investigating / Identified / Mitigated / Resolved |
| First detected via | <alert / human report / etc.> |

---

## Timeline

> Append timestamped entries in newest-last order. Round to the minute.
> Use 24h UTC. Be terse — descriptive headers, factual events. Speculation
> goes to a separate "Hypotheses" section, not the timeline.

```
2026-MM-DD HH:MM UTC  Incident declared. <observation>.
2026-MM-DD HH:MM UTC  Commander: <name>.
2026-MM-DD HH:MM UTC  <event>.
...
```

---

## Blast radius

| Question | Answer |
|---|---|
| Customers affected | <count or "tenant=*"> |
| Customer-facing impact | <auth fail / wrong data / latency / ...> |
| Started at | <ISO timestamp> |
| Confirmed contained at | <ISO or "ongoing"> |
| PHI exposure suspected? | yes / no — JUSTIFY in plain English |

> **HIPAA note (R13.7):** if PHI exposure is suspected, do NOT delete
> any logs. Preserve and capture evidence. Notify legal within 24h per
> the company's HIPAA policy. Breach notification requirements may
> apply.

---

## Customer comms draft

> No status-page vendor (R8.2 — explicit rejection of paid pager /
> status-page). Customer comms are manual broadcasts via:
> - Email to all affected tenants from `alerts@zeroroot.ai`.
> - Slack message in the customer-facing community channel.

```text
Subject: gibson — service issue (status: <Investigating / Identified / Mitigated / Resolved>)

We are <investigating | mitigating | have resolved> a service issue
affecting <scope> as of <timestamp UTC>. Symptoms: <terse>.

<If mitigated>: workaround: <steps>.
<If resolved>: full restoration confirmed at <timestamp UTC>.

We will publish a follow-up post-mortem within 5 business days.
For urgent questions, reply to this email.

— gibson ops
```

---

## Hypotheses (separate from timeline)

- **H1: <hypothesis>.** Evidence for: <list>. Evidence against: <list>.
- **H2: ...**

---

## Mitigation

| Step | Owner | At (UTC) | Outcome |
|---|---|---|---|
| <action> | <name> | HH:MM | <success/no-effect/regression> |

---

## Follow-ups

- [ ] Linear / Jira ticket: <link>. <description>
- [ ] Runbook update if the troubleshooting path was missing or wrong.
- [ ] Detection improvement (alert that should have fired earlier).
- [ ] Compliance review if PHI exposure was confirmed (R13.7).

---

## Known limitation: no upstream-IdP federation on Identity Center

If this incident involves Zitadel being down, **operators can still get
into AWS** because Identity Center is intentionally NOT federated to
Zitadel (design decision per design.md). This is a HARD design choice
to avoid the circular-dependency "we cannot get into AWS to fix
Zitadel". Document any awkwardness it caused but do not raise this as
an action item — the trade-off is intentional.

---

## Post-mortem (filed within 5 business days)

After resolution, copy the timeline + blast radius + mitigation +
follow-ups sections into `enterprise/deploy/docs/postmortem-<incident-id>.md`
with these additional sections:

- **What happened** (prose, 3-5 paragraphs).
- **What went well.**
- **What went wrong.**
- **Root cause (5-whys).**
- **Action items with owners and dates.**

---

## References

- `RUNBOOK-troubleshooting.md`
- `RUNBOOK-rollback.md`
- `RUNBOOK-cost-cutoff.md` (if cost-related)
- Spec: `requirements.md` R11.4, R13.7
