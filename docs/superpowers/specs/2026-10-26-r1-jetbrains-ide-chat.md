# R1. Warning in a JetBrains IDE's AI chat

Status: draft
Date: 2026-10-26
Roadmap: [2026-10-26-roadmap.md](2026-10-26-roadmap.md)

## Problem

In RustRover / Rider / IDEA the AI chat runs the agent you pick through ACP. With Junie the
warning never arrives: Junie's ACP host calls no hooks (Junie docs, "Hooks → Limitations").
Claude Agent and Codex in the chat are unchecked. Junie CLI and Claude Code in the IDE's
terminal already work.

## Requirements

R1.1. A matrix in `adapters/junie/README.md` (and the agents table): for each chat agent
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

Writing a JetBrains plugin. Changing ACP bridges. Windows (`.ps1`) for R1.3 until R1.3 is
confirmed feasible on sh.

## Design

Research first (R1.1, R1.2): run each chat agent with `CONTINUUM_THRESHOLD=10
CONTINUUM_TIERS=10`, mock provider. MCP: `initialize` → `notifications/initialized` →
`tools/list` (the server is stateful: `tools/list` before `initialize` answers "Server not
initialized"). Known tools so far: editor, terminal, files, run configs, tool windows; no
notification tool seen yet. R1.3 lives in `adapters/jetbrains/` if it goes ahead; the port
lookup must not scan all ports blindly (R1.4).

## Acceptance

- R1.1 matrix filled from live runs.
- R1.3 (if kept): tests with a fake MCP server (sh, `nc` not allowed → a tiny file-based stub
  through `CONTINUUM_IDE_MCP_URL`), both suites; "What it touches" lists the IDE endpoint.

## Later

—
