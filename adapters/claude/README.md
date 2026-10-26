# Claude Code adapter

Translates Claude Code's hook events into `continuum check` and back. All the logic
(tiers, cache, flags, wording) lives in the core; these scripts only speak Claude's
protocol. Install and settings: [README → Claude Code](../../README.md#claude-code).

Every script has a PowerShell twin (`.ps1`) with the same behavior.

| Event | Script | What it does |
|---|---|---|
| `Stop` | `stop.sh` | A new tier becomes `{"decision":"block","reason":"..."}`: Claude goes on and asks the user instead of ending the turn. Skips when `stop_hook_active` is set (loop guard). |
| `PostToolUse` | `tool-check.sh` | The same warning after each tool call, as `hookSpecificOutput.additionalContext`. Never blocks. Silent when the event carries `agent_id` (a subagent). |
| `PreToolUse` | `frugal-gate.sh` | Blocks the `Agent` tool when `CONTINUUM_FRUGAL=1`. |
| `PreToolUse` | `tool-check.sh` | Exits at once in Claude Code. Junie, which has no `PostToolUse`, gets its mid-turn warning here. |
| `SessionStart` | `resume-report.sh` | Summarizes `continuum resume` runs finished in the last 24 hours, so the user sees the results on session start. |
| `SessionStart` | `setup-statusline.sh` | Records where the code lives, adds `statusLine` to `settings.json` if there is none, and keeps the copy in `~/.claude/hooks/` current. |
| status line | `statusline.sh` | Renders usage in the status bar from the cache, refreshing it when stale. |

The events are wired in [`hooks/hooks.json`](../../hooks/hooks.json). `stop.sh` and
`tool-check.sh` share tiers and per-session flags through `continuum check`, so each
tier fires once, whichever sees it first. Every hook exits 0 on any failure: a hook
error would show up in the user's transcript.

Junie CLI runs these same hooks when continuum is installed as a Junie extension; the
scripts tell it apart by `project_path` in the event. See [adapters/junie/](../junie/README.md).

Writing an adapter for another agent: [docs/harnesses.md](../../docs/harnesses.md).
