// continuum adapter for opencode: a plugin that calls `continuum check`.
//
// Install: copy or symlink this file into ~/.config/opencode/plugins/ (global) or
// .opencode/plugins/ (one project). All the logic (tiers, cache, flags, wording)
// lives in `continuum check`; this file only speaks opencode's plugin API.
//
//   session.idle        the turn ended: a new tier is sent to the session as a
//                       prompt, so the agent answers by asking the user
//   tool.execute.after  in the middle of a turn: the warning is appended to the
//                       tool output the model reads next
//
// Child sessions (subagents, parentID set) are skipped: there is nobody to ask, and
// firing there would use up the tier before the main session sees it.
// CONTINUUM_ROOT points at the code; the default is the CLI installer's ~/.continuum.

import { execFile } from "node:child_process"
import { homedir } from "node:os"
import { join } from "node:path"

const MIDTURN_PREFIX =
  "Mid-turn usage check. Finish the step you are on and leave the work in a consistent state (commit or a note), then act on this: "

// The warning text for this session, or "" - never throws, never rejects.
function check(sessionID) {
  if (process.env.CONTINUUM_OFF) return Promise.resolve("")
  const root = process.env.CONTINUUM_ROOT || join(homedir(), ".continuum")
  const args = ["check", "--session", sessionID || "unknown", "--agent", "opencode"]
  const [cmd, argv] =
    process.platform === "win32"
      ? ["pwsh", ["-NoProfile", "-File", join(root, "bin", "continuum.ps1"), ...args]]
      : ["sh", [join(root, "bin", "continuum"), ...args]]
  return new Promise((resolve) => {
    execFile(cmd, argv, { timeout: 20000 }, (err, stdout) => resolve(err ? "" : String(stdout).trim()))
  })
}

async function isChild(client, id) {
  try {
    const res = await client.session.get({ path: { id } })
    return Boolean(res?.data?.parentID)
  } catch {
    return false
  }
}

export const Continuum = async ({ client }) => ({
  event: async ({ event }) => {
    if (event?.type !== "session.idle") return
    const id = event.properties?.sessionID
    if (!id || (await isChild(client, id))) return
    const text = await check(id)
    if (!text) return
    try {
      await client.session.prompt({ path: { id }, body: { parts: [{ type: "text", text }] } })
    } catch {
      // A failed prompt must not break the session: stay silent.
    }
  },
  "tool.execute.after": async (input, output) => {
    const id = input?.sessionID
    if (!id || !output || typeof output.output !== "string") return
    if (await isChild(client, id)) return
    const text = await check(id)
    if (text) output.output += `\n\n${MIDTURN_PREFIX}${text}`
  },
})
