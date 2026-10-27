# Live checks

What "run live" means in the agents table: a real session of that agent, on this code,
received the continuum warning. Setup unless noted: `CONTINUUM_PROVIDER=mock
CONTINUUM_THRESHOLD=10 CONTINUUM_TIERS=10`, a scratch `CONTINUUM_STATE_DIR`, the notifier
replaced (`CONTINUUM_NOTIFY_CMD=true`). Specs: R2 (agents in a terminal) and R1 (agents in a
JetBrains IDE's AI chat).

| Agent | Version | Date | End-of-turn warning | Mid-turn warning | Asks the user | Resume | Notes |
|---|---|---|---|---|---|---|---|
| Claude Code | 2.1.x | 2026-10-23 | yes (`Stop`) | yes (`PostToolUse`) | yes, AskUserQuestion | `claude --continue -p` | `claude -p --plugin-dir .` with mock |
| Junie CLI, batch | 26.10.20 | 2026-10-27 | yes | yes (`PreToolUse`, nested `hookSpecificOutput.additionalContext` accepted) | yes, a question with options at the end of the final message (no question tool) | `junie --resume --task` continued the same session headless (2026-10-26) | full `hooks/hooks.json` via `--config-location`, installed extensions off (`--extensions-default-location` = empty dir) |
| Junie CLI, interactive TUI | 26.10.20 | — | not run | not run | — | — | needs an interactive terminal; same hooks as batch per Junie docs |
| Junie in a JetBrains IDE chat (ACP) | — | — | no hooks | no hooks | — | — | Junie's ACP host calls no hooks (Junie docs, "Hooks → Limitations"); R1 |
| bb (Claude thread) | 0.47.1 | — | not run | not run | — | — | a bb thread runs Claude Code; postponed until the Claude usage window resets |
| opencode | 2.1.4 | — | not run | not run | — | — | only paid OpenRouter / xAI models configured here |
| Codex CLI | — | — | not run | not run | — | — | not installed here |
| Gemini CLI | — | — | not run | not run | — | — | not installed here |
| Cursor (`agent`) | — | — | not run | not run | — | — | not installed here |

## Question tools (R2.5)

- Claude Code: AskUserQuestion (in `cnt_ask_hint`).
- Junie: none; the hint asks for the question at the end of the final message, and Junie does it.
- Others: unknown until run live.
