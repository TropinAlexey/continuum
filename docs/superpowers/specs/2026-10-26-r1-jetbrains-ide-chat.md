# R1. Warning in a JetBrains IDE's AI chat

Status: in progress (research done; R1.1 matrix needs RustRover running and a Claude window with room)
Date: 2026-10-26
Roadmap: [2026-10-26-roadmap.md](2026-10-26-roadmap.md)

## Problem

In RustRover / Rider / IDEA the AI chat runs the agent you pick through ACP. With Junie the
warning never arrives: Junie's ACP host calls no hooks (Junie docs, "Hooks → Limitations").
Claude Agent and Codex in the chat are unchecked. Junie CLI and Claude Code in the IDE's
terminal already work.

## Requirements

R1.1. A matrix in `docs/live-checks.md` (linked from `adapters/junie/README.md` and the agents
      table): for each chat agent
      (Junie, Claude Agent, Codex) in RustRover 2026.2 — does the Stop warning arrive, does the
      mid-turn one, does `continuum resume` reach the same chat. Every cell from a live run.
R1.2. If Claude Agent / Codex in the chat already run their own hooks (ACP bridge loads user
      settings, as Agent SDK does in bb), document it; no code.
R1.3. For chat agents that get no warning: show it in the IDE through the IDE's MCP server
      (`http://127.0.0.1:<port>/stream`, same API in Rider and RustRover), from `sh` + `curl`
      only. Only if an MCP tool can put a visible message in front of the user; otherwise
      R1.3 is dropped with the reason written here.
R1.4. Discovery of the MCP endpoint without hard-coded ports (the port changes on restart),
      opt-in via a setting; nothing is sent to the IDE unless the user turned it on.

## Out of scope

Writing a JetBrains plugin. Changing ACP bridges. Agents in the IDE's terminal (they are
covered by their own adapters and by R2). R1.3 may be prototyped in sh first, but it ships
only with its `.ps1` twin (project convention).

## Design

Research first (R1.1, R1.2): run each chat agent with `CONTINUUM_THRESHOLD=10
CONTINUUM_TIERS=10`, mock provider. MCP: `initialize` → `notifications/initialized` →
`tools/list` (the server is stateful: `tools/list` before `initialize` answers "Server not
initialized"). Known tools so far: editor, terminal, files, run configs, tool windows; no
notification tool seen yet. R1.3 lives in `adapters/jetbrains/` if it goes ahead; the port
lookup must not scan all ports blindly (R1.4).

Research (2026-10-27):
- The IDE MCP server is stateful (`initialize` → `Mcp-Session-Id` → `tools/list`) and its
  port changes when the IDE restarts (Rider moved off 64482), so R1.4 discovery is required.
- No notification tool among the IDE's MCP tools. Visible options: `open_file_in_editor`
  (open a file with the warning text) and `execute_terminal_command` (too intrusive: runs a
  command in the user's IDE terminal; rejected).
- In the IDE chat (ACP) no hooks fire for Junie, so nothing inside the agent can call the
  MCP server. R1.3 therefore means an outside poller: `continuum watch --ide` that, on a new
  tier, writes the warning to `$CNT_STATE/WARNING.md` and opens it via `open_file_in_editor`.
  It only shows; it cannot make the chat agent ask (the "decide" part stays with the user).
- Next: with RustRover open, fill R1.1 for Claude Agent / Codex in the chat; if their ACP
  bridges run the user's hooks (likely for Claude Agent: Agent SDK with user settings, as in
  bb), R1.3 is needed only for Junie.

## Acceptance

- R1.1 matrix filled from live runs.
- R1.3 (if kept): the transport is swappable (`CONTINUUM_IDE_MCP_CMD`, default `curl`), so
  tests replace it with a stub that records the request; no network, both suites. "What it
  touches" lists the IDE endpoint and what is sent there.

## Later

—
