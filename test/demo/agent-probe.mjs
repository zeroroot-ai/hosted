// agent-probe.mjs — the in-image half of the enrollment exit test
// (zerocool-plugins#10). test/demo/exit-test-enrollment.sh mounts this file
// into the zerocool-agent image at /app/probe.mjs and runs it in place of the
// agent loop, on the host key the first start persisted. It uses the same
// @zeroroot-ai/sdk the image ships, so the path it proves is the path the
// shipped agent takes: the capability-grant re-registration on the host key,
// the OpenAI-compatible shim over ComponentService.Complete, SubmitFinding,
// and GetFindings.
//
// Modes:
//   complete   start the shim, POST one chat completion to it, print the
//              answer. Env: PROBE_SLOT (the model slot, default "primary").
//   finding    submit one finding, read it back from the tenant graph, and
//              query the knowledge graph once. Env: PROBE_FINDING_TITLE.
//   gitlab     list the tools the GitLab connector exposes, call one read-only
//              tool against a project, print the result. Env:
//              PROBE_GITLAB_PROJECT (group/project). Exits non-zero and prints
//              ok:false when the call is refused, which step 11 expects.
//   mission-gitlab  start as the dispatched agent of a mission, wait for the
//              work item that the mission sends this agent, and call the same
//              read-only GitLab tool with the work id of that item, so the call
//              runs inside the mission (the audit trail then carries the mission
//              id). Prints "[probe] worker ready" on stderr when it polls. Env:
//              PROBE_GITLAB_PROJECT, PROBE_MISSION_WAIT_MS (default 300000).
//   --selftest offline. Proves the assertions here can fail. No SDK, no
//              network.
//
// Output: one JSON line on stdout, `{"ok":true,...}` or `{"ok":false,...}`.
// Everything else goes to stderr. Exit 0 only when ok is true.

import { randomUUID } from "node:crypto"
import process from "node:process"

// ---------------------------------------------------------------------------
// Pure assertions (selftested)
// ---------------------------------------------------------------------------

/**
 * The tool list of a discovery answer. The SDK returns {tools, unavailable};
 * an older SDK returned the array. Both give the array, and a daemon that has
 * no lister gives an error that names the reason, never an empty pass.
 */
export function toolsOf(discovery) {
  if (Array.isArray(discovery)) return discovery
  if (Array.isArray(discovery?.tools)) {
    if (discovery.tools.length === 0 && discovery.unavailable) {
      throw new Error(`tool discovery is unavailable: ${discovery.unavailable}`)
    }
    return discovery.tools
  }
  throw new Error(`the tool discovery answer has no tool list: ${JSON.stringify(discovery).slice(0, 200)}`)
}

/**
 * A dispatched work item runs a call inside a mission only when it carries a
 * work id: the harness scopes the call by it. No work id is a call outside any
 * mission, and the check refuses it.
 */
export function assertMissionWork(inv) {
  if (typeof inv?.workId !== "string" || inv.workId === "") {
    throw new Error("the dispatched work item has no work id, so a call would run outside any mission")
  }
  return inv.workId
}

/** The shim's answer carries one non-empty assistant message, or this throws. */
export function assertCompletion(body) {
  const content = body?.choices?.[0]?.message?.content
  if (typeof content !== "string" || content.trim() === "") {
    throw new Error(`the shim returned no assistant content: ${JSON.stringify(body).slice(0, 500)}`)
  }
  return content
}

/**
 * The finding list holds the id the daemon assigned, with the title that was
 * submitted, or this throws. The daemon assigns its own id on submit and
 * answers reads from the tenant graph a moment later, so the caller polls
 * with the returned id. A stub finding (the daemon could not parse the
 * submission, run 35653353928) keeps the id and loses the title, and is
 * refused here.
 */
export function assertReadBack(findings, id, title) {
  const hit = (findings ?? []).find((f) => f?.id === id)
  if (!hit) throw new Error(`finding ${id} is not in the tenant graph (${(findings ?? []).length} findings read)`)
  if (hit.title !== title) {
    throw new Error(`finding ${id} came back with title ${JSON.stringify(hit.title)}, not ${JSON.stringify(title)}: the daemon stored a stub`)
  }
  return hit
}

/**
 * Pick the read-only GitLab tool to call, from the tools the daemon listed
 * for this agent. Only tools the catalog tagged as the gitlab connector's
 * count. `get_project` first, then `list_work_items`, then `search`; the
 * input names the project the owner set. Nothing usable throws.
 */
export function pickGitlabTool(tools, project) {
  const mine = (tools ?? []).filter((t) => (t?.tags ?? []).includes("connector:gitlab"))
  if (mine.length === 0) throw new Error(`the daemon lists no tool tagged connector:gitlab (${(tools ?? []).length} tools listed)`)
  const byLeaf = (leaf) => mine.find((t) => t.name === leaf || t.name.endsWith(`:${leaf}`) || t.name.endsWith(`/${leaf}`))
  let t
  if ((t = byLeaf("get_project"))) return { name: t.name, input: { project_id: project } }
  if ((t = byLeaf("list_work_items"))) return { name: t.name, input: { project_id: project, first: 5 } }
  if ((t = byLeaf("search"))) return { name: t.name, input: { scope: "projects", search: project } }
  throw new Error(`no read-only project tool among the gitlab connector's ${mine.length} tools: ${mine.map((x) => x.name).join(", ")}`)
}

/** The tool's output names the project, or this throws. */
export function assertNamesProject(output, project) {
  const text = typeof output === "string" ? output : JSON.stringify(output ?? "")
  if (!text.includes(project)) {
    throw new Error(`the tool output does not name ${project}: ${text.slice(0, 300)}`)
  }
  return text
}

function selftest() {
  let failures = 0
  const check = (name, fn, wantThrow) => {
    let threw = null
    try {
      fn()
    } catch (e) {
      threw = e
    }
    const ok = wantThrow ? threw !== null : threw === null
    if (!ok) {
      failures += 1
      console.error(`SELFTEST FAIL: ${name} — ${wantThrow ? "should have thrown, did not" : `threw: ${threw}`}`)
    } else {
      console.error(`selftest ok: ${name}`)
    }
  }
  check("a completion with content is accepted", () => assertCompletion({ choices: [{ message: { content: "PONG" } }] }), false)
  check("a completion with no choices is refused", () => assertCompletion({ choices: [] }), true)
  check("a completion with empty content is refused", () => assertCompletion({ choices: [{ message: { content: "  " } }] }), true)
  check("the finding read back with its title is accepted", () => assertReadBack([{ id: "f-1", title: "Demo" }], "f-1", "Demo"), false)
  check("a missing finding is refused", () => assertReadBack([{ id: "f-2", title: "Demo" }], "f-1", "Demo"), true)
  check("a stub finding with another title is refused", () => assertReadBack([{ id: "f-1", title: "" }], "f-1", "Demo"), true)
  check("an empty graph read is refused", () => assertReadBack([], "f-1", "Demo"), true)
  const gl = [{ name: "mcp:gitlab:get_project", tags: ["source:mcp", "connector:gitlab"] }, { name: "native:echo", tags: ["source:native"] }]
  check("the gitlab get_project tool is picked", () => {
    const pick = pickGitlabTool(gl, "grp/proj")
    if (pick.name !== "mcp:gitlab:get_project" || pick.input.project_id !== "grp/proj") throw new Error(JSON.stringify(pick))
  }, false)
  check("a discovery answer object gives its tools", () => {
    if (toolsOf({ tools: [{ name: "a" }] }).length !== 1) throw new Error("not one tool")
  })
  check("an old array answer gives its tools", () => {
    if (toolsOf([{ name: "a" }]).length !== 1) throw new Error("not one tool")
  })
  check("an unavailable discovery is refused", () => toolsOf({ tools: [], unavailable: "no lister" }), true)
  check("a malformed discovery answer is refused", () => toolsOf({}), true)
  check("a work item with a work id runs in a mission", () => {
    if (assertMissionWork({ workId: "w-1" }) !== "w-1") throw new Error("wrong id")
  })
  check("a work item with no work id is refused", () => assertMissionWork({ workId: "" }), true)
  check("a list with no gitlab tool is refused", () => pickGitlabTool([{ name: "native:echo", tags: ["source:native"] }], "grp/proj"), true)
  check("a gitlab tool set with no project tool is refused", () => pickGitlabTool([{ name: "mcp:gitlab:create_issue", tags: ["connector:gitlab"] }], "grp/proj"), true)
  check("an output naming the project is accepted", () => assertNamesProject({ path_with_namespace: "grp/proj" }, "grp/proj"), false)
  check("an output naming another project is refused", () => assertNamesProject({ path_with_namespace: "other/thing" }, "grp/proj"), true)
  if (failures > 0) {
    console.error(`probe selftest: ${failures} assertion(s) cannot fail correctly`)
    process.exit(1)
  }
  console.error("probe selftest: every assertion can fail")
}

// ---------------------------------------------------------------------------
// Live modes
// ---------------------------------------------------------------------------

function requireEnv(name) {
  const v = process.env[name]
  if (!v) {
    console.log(JSON.stringify({ ok: false, error: `${name} is required` }))
    process.exit(1)
  }
  return v
}

async function connect(sdk) {
  const platformURL = requireEnv("GIBSON_PLATFORM_URL")
  const hostKeyPath = requireEnv("GIBSON_HOST_KEY_PATH")
  const agentName = requireEnv("ZEROCOOL_AGENT_NAME")
  // No bootstrap token here, on purpose: the probe is an unattended start on
  // the persisted host key, the same as every start after the first.
  const session = await sdk.connectGibson({
    platformURL,
    hostKeyPath,
    agentName,
    agentMode: "autonomous",
    agent: { name: agentName, version: "0.0.0", capabilities: ["code"] },
  })
  console.error(`[probe] re-registered ${agentName} on the host key (component_scope=${session.componentScope})`)
  return { session, agentName }
}

async function complete(sdk) {
  const { session } = await connect(sdk)
  const slot = process.env.PROBE_SLOT ?? "primary"
  const shim = await sdk.startCompletionsShim({ component: session.clients.component, port: 0 })
  console.error(`[probe] shim listening at ${shim.url}`)
  try {
    const res = await fetch(`${shim.url}/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer gibson" },
      body: JSON.stringify({
        model: slot,
        messages: [{ role: "user", content: "Reply with the single word PONG and nothing else." }],
      }),
    })
    const text = await res.text()
    let body
    try {
      body = JSON.parse(text)
    } catch {
      throw new Error(`the shim answered HTTP ${res.status} with a non-JSON body: ${text.slice(0, 500)}`)
    }
    if (!res.ok) throw new Error(`the shim answered HTTP ${res.status}: ${text.slice(0, 500)}`)
    const content = assertCompletion(body)
    return { ok: true, mode: "complete", slot, model: body.model ?? slot, content }
  } finally {
    await shim.close()
    session.stop()
  }
}

async function finding(sdk) {
  const { session, agentName } = await connect(sdk)
  const title = requireEnv("PROBE_FINDING_TITLE")
  // The daemon parses the id as a UUID and assigns its own on store. A
  // non-UUID id makes it store a stub with no title (run 35653353928).
  const id = randomUUID()
  try {
    const submitted = await sdk.submitFinding(session.clients.component, {
      id,
      mission_id: "",
      agent_name: agentName,
      title,
      description:
        "Emitted by the enrollment exit test (zerocool-plugins#10). It proves a finding from an enrolled agent lands in the tenant graph attributed to the agent and to the person who enrolled it.",
      category: "configuration",
      severity: "info",
      confidence: 1,
      risk_score: 0,
      tags: ["demo", "enrollment-exit-test"],
    })
    console.error(`[probe] submitted finding ${submitted} (client id ${id})`)
    // The store is written through the tenant graph asynchronously. Poll the
    // read side with the id the daemon returned.
    const deadline = Date.now() + Number(process.env.PROBE_READ_TIMEOUT_MS ?? 90_000)
    let findings = []
    let hit
    for (;;) {
      findings = await sdk.getFindings(session.clients.component, { search: title })
      hit = findings.find((f) => f?.id === submitted)
      if (hit || Date.now() >= deadline) break
      await new Promise((r) => setTimeout(r, 3000))
    }
    hit = assertReadBack(findings, submitted, title)
    // The knowledge query is the ambient path the opencode plugin takes on its
    // second turn. It needs an embedder the baseline profile may not have, so
    // its outcome is recorded here and asserted nowhere: the graph read this
    // step proves is the finding node above.
    let knowledge
    try {
      const hits = await sdk.queryKnowledge(session.clients.component, { text: title, topK: 3 })
      knowledge = { hits: hits.length }
    } catch (e) {
      knowledge = { error: String(e?.message ?? e) }
    }
    return {
      ok: true,
      mode: "finding",
      submitted,
      // agent_name is whatever the daemon stamped on the record. The drill
      // asserts it equals this agent; the daemon records no submitter on a
      // mission-less finding today, so that assertion names the gap.
      readBack: { id: hit.id, title: hit.title, severity: hit.severity, agent_name: hit.agent_name ?? null },
      agentName,
      readCount: findings.length,
      knowledge,
    }
  } finally {
    session.stop()
  }
}

async function gitlab(sdk) {
  const { session, agentName } = await connect(sdk)
  const project = requireEnv("PROBE_GITLAB_PROJECT")
  try {
    const tools = toolsOf(await sdk.listGibsonTools(session.clients.component))
    const mine = tools.filter((t) => (t.tags ?? []).includes("connector:gitlab"))
    console.error(`[probe] ${tools.length} tools listed, ${mine.length} from the gitlab connector`)
    const pick = pickGitlabTool(tools, project)
    console.error(`[probe] calling ${pick.name} with ${JSON.stringify(pick.input)}`)
    const result = await sdk.callGibsonTool(session.clients.component, { name: pick.name, input: pick.input })
    if (result.error) {
      return { ok: false, mode: "gitlab", tool: pick.name, agentName, refused: true, error: `${result.error.code}: ${result.error.message}` }
    }
    const text = assertNamesProject(result.output, project)
    return { ok: true, mode: "gitlab", tool: pick.name, agentName, toolsFromConnector: mine.length, output: text.slice(0, 400) }
  } finally {
    session.stop()
  }
}

// One call of the GitLab tool inside the mission that dispatched this work item.
// startAgentWorker polls (PollWork) and claims the item before the handler runs,
// so the work id below is one that this agent claimed. The daemon accepts a
// connector call only with such a work id, or with a task grant for the run.
async function callInMission(sdk, session, inv, project) {
  const workId = assertMissionWork(inv)
  const tools = toolsOf(await sdk.listGibsonTools(session.clients.component, workId))
  const pick = pickGitlabTool(tools, project)
  console.error(`[probe] work ${workId} (mission run ${inv.missionRunId}): calling ${pick.name} with ${JSON.stringify(pick.input)}`)
  const result = await sdk.callGibsonTool(session.clients.component, { workId, name: pick.name, input: pick.input })
  const base = { mode: "mission-gitlab", tool: pick.name, workId, missionRunId: inv.missionRunId }
  if (result.error) {
    return { ok: false, ...base, refused: true, error: `${result.error.code}: ${result.error.message}` }
  }
  const text = assertNamesProject(result.output, project)
  return { ok: true, ...base, output: text.slice(0, 400) }
}

async function missionGitlab(sdk) {
  const { session, agentName } = await connect(sdk)
  const project = requireEnv("PROBE_GITLAB_PROJECT")
  const waitMs = Number(process.env.PROBE_MISSION_WAIT_MS ?? 300_000)
  let stop = () => {}
  try {
    const outcome = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no work item was dispatched to ${agentName} within ${waitMs} ms`)), waitMs)
      stop = sdk.startAgentWorker(session.clients.component, session.instance, {
        onError: (e) => console.error(`[probe] worker error: ${e}`),
        handler: async (inv) => {
          let r
          try {
            r = await callInMission(sdk, session, inv, project)
          } catch (e) {
            clearTimeout(timer)
            reject(e)
            throw e
          }
          clearTimeout(timer)
          resolve({ ...r, agentName })
          return r.ok ? { success: true, output: { tool: r.tool } } : { success: false, output: { error: r.error } }
        },
      })
      console.error("[probe] worker ready")
    })
    return outcome
  } finally {
    stop()
    session.stop()
  }
}

async function main() {
  const mode = process.argv[2]
  if (mode === "--selftest") {
    selftest()
    return
  }
  const modes = { complete, finding, gitlab, "mission-gitlab": missionGitlab }
  if (!modes[mode]) {
    console.log(JSON.stringify({ ok: false, error: `unknown mode ${JSON.stringify(mode)}; want complete | finding | gitlab | mission-gitlab | --selftest` }))
    process.exit(2)
  }
  // Resolved from /app, where the image deploys the agent and its SDK.
  const sdk = await import("@zeroroot-ai/sdk")
  const out = await modes[mode](sdk)
  console.log(JSON.stringify(out))
  // The SDK's heartbeat and grant timers would keep the process alive.
  process.exit(out.ok ? 0 : 1)
}

main().catch((e) => {
  console.log(JSON.stringify({ ok: false, error: String(e?.message ?? e) }))
  process.exit(1)
})
