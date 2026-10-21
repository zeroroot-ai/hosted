# Demo: opencode enrolls against the baseline install

This is the enrollment half of the demo (zerocool-plugins#10). A person logs
in once and enrolls a coding agent once. The agent then runs with no person,
and what it does shows up in the platform under its own name and the name of
the person who enrolled it.

The script below is derived from the automated run, not from the design. The
workflow `exit-test-demo-enrollment.yml` runs `test/demo/exit-test-enrollment.sh`
on the baseline install on main and on dispatch. Each step is a hard assertion. The
"Run record" section names the run this page was derived from and lists the
steps that failed in it.

The workflow has two jobs, each on its own cluster. `enrollment` always
runs steps 1 to 5 and 7 (a finding needs no model). `completion` runs
steps 1 to 3 and 6, and only when a person has set the repository variable
`EXIT_TEST_DEMO_COMPLETION_ENABLED=true` and the secret
`EXIT_TEST_ANTHROPIC_API_KEY`. Until then that job is skipped, the run says
so, and the run never reads red for a key nobody has added (hosted#123).

## The venue

The baseline install is what the charts `exit-test-baseline-install.yml` proves:
`make recreate ENV=kind` with the CI rung, charts main, one seeded tenant, and
a first admin created with no password (ADR-0093): the first-admin Job sends
a one-time setup link, offline in this profile, to the Secret
`gibson-first-tenant-owner-setup`. The workflow brings that install up the
same way, with no overlay, and completes the setup link itself (sets a
password, enrolls TOTP) through the same driver
`test/platform-owner/driver.mjs` uses.

## The steps

1. Log in as the seeded first admin.

   ```bash
   export GIBSON_CA_CERT=edge-ca.crt   # the self-signed edge CA of the install
   gibson login --gibson-url https://api.<domain> --no-browser
   ```

   The CLI prints a URL and a device code. A person opens the URL and signs
   in with the password and authenticator app they set up through the
   one-time setup link (no password ever crosses the platform's own storage;
   ADR-0093). The automated run completes that same setup link first (see
   "The venue" above), then approves the device request with no browser: it
   opens a Zitadel session with the password it just set, through the
   cluster's own `login-client` credential, and approves the request through
   the Zitadel device authorization API. That is the API the login page
   calls.

2. Mint a one-time token for the agent.

   ```bash
   gibson agent enroll --name zerocool --kind agent
   ```

   The command prints `bootstrap_token:`. The token is shown once.

3. Start the agent once with the token.

   ```bash
   docker run -d --name zerocool \
     -e GIBSON_PLATFORM_URL=https://api.<domain> \
     -e GIBSON_BOOTSTRAP_TOKEN=<token> \
     -e GIBSON_HOST_KEY_PATH=/tmp/zerocool/host.key \
     -e NODE_EXTRA_CA_CERTS=/tmp/zerocool/edge-ca.crt \
     -e ZEROCOOL_AGENT_NAME=zerocool \
     -v "$PWD/state:/tmp/zerocool" \
     ghcr.io/zeroroot-ai/zerocool-agent@sha256:e48e2e79ad8b084c09f15ecb0b995e80276d1931fceecc849295a7f30f3c8ce7
   ```

   The first start completes the capability-grant handshake and writes
   `state/host.key`. The token is spent.

4. Start the agent again with no token. The same command without
   `GIBSON_BOOTSTRAP_TOKEN` registers on the host key. No person is involved.

5. The daemon lists the agent. `DaemonService.ListAgents`, the RPC the
   dashboard component list reads, shows the agent as `healthy` with a
   heartbeat in the last two minutes.

6. A completion goes through the shim. The baseline profile ships no model
   slot. A tenant admin registers a provider first
   (`ProviderService.CreateProvider`, the dashboard provider settings), then
   the shim on `http://127.0.0.1:8787/v1/chat/completions` answers a chat
   request on slot `primary`, and the daemon log records
   `complete: LLM completion succeeded` for that slot.

7. The agent submits a finding and reads the tenant graph. The finding is
   read back through `ComponentService.GetFindings` under the agent's own
   `agent_name`. The person's view, `GraphService.GetFindings`, lists it. The
   agent identity, `AgentIdentityService.ListAgentIdentities`, carries
   `created_by_subject` equal to the person who ran `gibson agent enroll`.

## The GitLab half (gibson#21)

No workflow runs steps 8 to 13. GitLab refuses a personal access token on
its MCP endpoint `https://gitlab.com/api/v4/mcp` (HTTP 403, run
37355956639). The connector manifest says `auth: oauth`, and an OAuth grant
needs a person at the GitLab consent page. A person runs the GitLab half in
the final session against the rebuilt install:

```bash
DEMO_GITLAB_PROJECT=group/project GIBSON_SRC=../gibson \
  bash test/demo/exit-test-enrollment.sh --phase gitlab
```

8. The first admin enables the connector and authorizes it with OAuth.

   `ConnectorService.EnableConnector {catalog_id: gitlab}`, then
   `ConnectorAuthService.StartConnectorAuthorization` with the instance URL
   (`GITLAB_INSTANCE_URL`, default `https://gitlab.com`). The daemon runs
   the RFC 8414 discovery, the RFC 7591 client registration and PKCE, and
   returns the authorize URL. The script prints it. The person opens it,
   signs in to GitLab and grants access. GitLab redirects to the daemon
   callback, which stores the grant and proves that it refreshes.
   `GetConnectorAuthStatus` must report `AUTHORIZED`, with `authorized_by`
   equal to the admin's subject and the `mcp` scope. The script waits up to
   `AUTH_WAIT_SECONDS` (default 900). The daemon publishes the access token
   to the proxy on its refresh pass (every 5 minutes), and the connector
   reaches `Ready` with discovered tools. The wait is bounded at 12 minutes.

9. A mission sends the agent to the connector. The first admin creates a
   target for the GitLab project (`gibson target create`) and submits a
   mission with one agent node that names the enrolled agent
   (`gibson mission submit --detach`, which prints the mission id). The agent,
   on its host key, claims the dispatch and lists the tools through
   `ComponentService.ListTools`. It keeps the ones tagged `connector:gitlab`
   and calls `get_project` (or `list_work_items`, or `search`) through
   `ComponentService.CallTool` against `DEMO_GITLAB_PROJECT`, with the work id
   of the dispatch. That work id puts the call inside the mission. The output
   must name the project. A call with no work id is outside any mission, and
   the probe refuses to make it.

10. `TenantService.ListAuditEvents` must hold an event with `actor_source`
    `agent`, `actor_id` equal to the agent principal, a `target_object` on the
    connector, and the mission id of step 9 in `details`. The agent identity
    must name the enrolling person, so the trail shows agent, mission and
    person. A call outside a mission has no mission id, and the run fails.

12. The test deletes the OpenBao pod (`gibson-openbao-0`), as a crash would.
    This is the one change the test makes to the cluster. The pod must come
    back as a new pod and report initialized and unsealed within
    `BAO_RETURN_WAIT` seconds (default 300). No step unseals, restarts or
    patches it: the static seal opens the new pod from the keyring.

13. The next connector call works. A new mission sends the agent to the
    connector again, and the call must answer and name the project. The run
    tries up to three times, 30 seconds apart, and records the number of
    tries.

11. `RevokeConnectorGrant` must report a grant, `GetConnectorAuthStatus`
    must report `UNAUTHORIZED`, and the agent's next call, in a new mission,
    must be refused. The proxy's credential is withdrawn on the daemon's next
    refresh pass and the operator rechecks every 2 minutes, so the refusal is
    polled for up to 7.5 minutes and the time it took is part of the record.

The gitlab phase runs the steps in this order: 8, 9, 10, 12, 13, 11. Step 12
needs a live connector grant, so it runs in the same session as steps 8 to 11,
with a person at the GitLab consent page. No workflow runs it, and nothing
runs it on a schedule. This is the check for gibson#21: "Killing the OpenBao
pod mid-demo does not break the platform, it returns unsealed on its own."

Steps 8 to 13 have not run yet: no run on main has held the token. The
assertions above are the design read against the code on main, not a
record. The first gated run rewrites this section from what happened.

## Known gaps, written down

- **No model slot ships with the baseline profile.** Step 6 needs a real
  provider key. The workflow reads it from the repository secret
  `EXIT_TEST_ANTHROPIC_API_KEY` (the same name gibson's `exit-test-bank`
  uses). When the secret is empty, step 6 fails and says so. It never skips.
- **Per-agent usage is not wired.** `UsageService.ListUsage` with the agent
  scope returns no rows (`server_usage.go`, `listUsageByAgent`). The trace
  evidence for step 6 is the daemon's completion record, not a usage row.
- **The knowledge query needs an embedder.** The opencode plugin's ambient
  knowledge block queries the graph with `QueryNodes`, which scores by
  vector. The probe records the outcome of one such query and asserts
  nothing on it. The graph read step 7 asserts is the finding node.
- **A mission-less finding records no submitter.** The daemon assigns the
  finding id and stores the record with no agent name or principal
  (gibson#208). The agent reads its finding back and the person's view
  lists it, but neither view says which agent raised it. Step 7 asserts the
  name and fails until gibson stamps the verified caller.
- **The finding id must be a UUID.** The daemon parses the client id as a
  UUID before it assigns its own. A non-UUID id makes it store a stub with
  no title (run 35653353928). The probe generates a UUID.
- **The completion in step 6 is the shim, not a model-driven opencode turn.**
  The probe starts the same `startCompletionsShim` the plugin starts and
  posts the same request opencode's `gibson` provider posts. A full
  `opencode run` turn needs the model above and is the next slice.

## Run record

Derived from run 35653353928 (2026-09-21, charts main with gibson v0.138.0,
the merge push of hosted#154).

| Step | Result | What happened |
|---|---|---|
| 1 | PASS | `gibson login` completed with no browser and pinned tenant `primary`. |
| 2 | PASS | `gibson agent enroll` minted the token for `agent_principal:391796924350464045`. |
| 3 | PASS | The first start completed the handshake, registered (`instance=0188815e-...`), and persisted the host key (sha256 `17a8b6363e1e`). gibson#201 closed the wall behind gibson#203. |
| 4 | PASS | The second start, with no token, registered on the same key (`instance=69dc4944-...`). |
| 5 | PASS | `DaemonService.ListAgents` listed the agent `healthy` with `lastSeen` in the last two minutes. |
| 6 | FAIL | `EXIT_TEST_ANTHROPIC_API_KEY` is empty in the hosted repository. |
| 7 | FAIL | The submit succeeded, but the id the probe sent was not a UUID, so the daemon stored a stub under its own id and the read-back found nothing. Fixed in the probe. The stored finding also carries no submitter (gibson#208). |

The earlier record, kept for the sequence of walls:

Derived from run 35638725251 (2026-09-21, charts main with charts#149,
gibson v0.137.0, zitadel v4.18.0), dispatched after charts#148 closed.

| Step | Result | What happened |
|---|---|---|
| 1 | PASS | `gibson login` completed with no browser. The CLI pinned the active tenant `primary`. |
| 2 | PASS | `gibson agent enroll` minted a one-time token for `agent_principal:391782727520616491`. |
| 3 | FAIL | The first start completed the capability-grant handshake (`capabilitygrant: agent registered`, capabilities 0). The next call, `ComponentService.RegisterComponent`, was denied by ext-authz for that principal. The image exited `[permission_denied]`. The gate needs `tenant_enabled component:_system` for the tenant, and nothing on the install writes it. Filed as gibson#203. |
| 4 to 7 | NOT RUN | Depend on step 3. |

The earlier record, kept for the sequence of walls:

Derived from run 35634482919 (2026-09-21, charts main, gibson v0.137.0,
zitadel v4.18.0). Two earlier runs, 35625719878 and 35629604244, died in
the drill's own preconditions: the drill moved `HOME` and lost the
kubeconfig with it. hosted#149 fixed that.

| Step | Result | What happened |
|---|---|---|
| 1 | FAIL | The device flow completed with no browser. The cluster's `login-client` credential opened a password session for `admin@localhost.zeroroot.ai` and approved the device request through the Zitadel API. The CLI received a JWT and the edge accepted it. ext-authz then denied `ListMyMemberships`: `identity-class not in allowed_identities caller_class=SERVICE allowed=USER`. The chart names only the dashboard client as a human sign-in client (charts#118), so the native-login client's token is classed as a machine credential since gibson#138. The CLI pinned no tenant. Fix: the charts issue filed from this run. |
| 2 to 7 | NOT RUN | Depend on step 1. |

What the run proved anyway: the seeded first admin's password signs in
through the Zitadel session API, the device grant is enabled on the
native-login client, and a person needs no browser to approve the CLI on
this install.
