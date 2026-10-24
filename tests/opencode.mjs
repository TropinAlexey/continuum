// Drives adapters/opencode/continuum.js with a fake opencode client, against the mock
// provider. Called by tests/run.sh and tests/run.ps1; prints "ok <name>" / "FAIL <name>".
//   node tests/opencode.mjs <path to continuum.js>
import { pathToFileURL } from "node:url"

const { Continuum } = await import(pathToFileURL(process.argv[2]).href)

function fakeClient(parents = {}) {
  const prompts = []
  return {
    prompts,
    session: {
      get: async ({ path }) => ({ data: { id: path.id, parentID: parents[path.id] } }),
      prompt: async (req) => { prompts.push(req) },
    },
  }
}
const say = (good, name) => console.log(`${good ? "ok" : "FAIL"} ${name}`)
const idle = (id) => ({ event: { type: "session.idle", properties: { sessionID: id } } })

let c = fakeClient()
let p = await Continuum({ client: c })
await p.event(idle("s1"))
say(c.prompts.length === 1 && c.prompts[0].path.id === "s1" && c.prompts[0].body.parts[0].text.startsWith("[continuum]"), "idle prompts the session")
await p.event(idle("s1"))
say(c.prompts.length === 1, "idle fires once per tier")

c = fakeClient({ child: "s1" })
p = await Continuum({ client: c })
await p.event(idle("child"))
const childOut = { title: "", output: "done", metadata: {} }
await p["tool.execute.after"]({ tool: "bash", sessionID: "child", callID: "1", args: {} }, childOut)
say(c.prompts.length === 0 && childOut.output === "done", "child session is skipped")

const out = { title: "", output: "done", metadata: {} }
await p["tool.execute.after"]({ tool: "bash", sessionID: "s2", callID: "2", args: {} }, out)
say(out.output.startsWith("done\n\nMid-turn usage check.") && out.output.includes("[continuum]"), "mid-turn appends to tool output")

process.env.CONTINUUM_OFF = "1"
c = fakeClient()
p = await Continuum({ client: c })
await p.event(idle("s3"))
say(c.prompts.length === 0, "off is silent")
