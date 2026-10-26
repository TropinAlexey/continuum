# continuum in Junie (JetBrains: RustRover, IntelliJ IDEA, Rider, …)

Junie CLI installs Claude Code plugins from their marketplaces as Junie extensions and runs
their `hooks/hooks.json`, with `${CLAUDE_PLUGIN_ROOT}` pointing at the extension. So there
are no Junie-specific scripts: Junie runs the [Claude Code adapter](../claude/README.md), and
the adapter notices Junie by the `project_path` field, which Junie's events carry and Claude
Code's do not.

## Install

In Junie CLI, run `/extensions` (or `/plugin`), add the marketplace
`https://github.com/TropinAlexey/continuum` and install `continuum` (user scope for every
project). Nothing else to configure.

## What runs

| Junie event | Script | What it does in Junie |
|---|---|---|
| `Stop` | `stop.sh` | A new tier becomes `{"decision":"block","reason":"..."}`: Junie goes back to the task with the warning before it submits. The hint asks Junie to end its final message with a question to you (it has no question tool). Skips on `stop_hook_active`. |
| `PreToolUse` | `tool-check.sh` | The same warning in the middle of a task, as `additionalContext`. Junie has no `PostToolUse`; in Claude Code this `PreToolUse` call exits at once and the `PostToolUse` one does the work. |
| `PreToolUse` | `frugal-gate.sh` | Blocks the `Agent` tool when `CONTINUUM_FRUGAL=1`. |
| `SessionStart` | `resume-report.sh` | Summarizes `continuum resume` runs finished in the last 24 hours. |
| `SessionStart` | `setup-statusline.sh` | Does nothing in Junie: Claude Code's settings are not touched. |

Tiers and flags are per Junie session (`session_id`), shared by `Stop` and `PreToolUse`.

## Resume

```sh
CONTINUUM_AGENT=junie continuum resume "$(continuum reset)" "$PWD" "<task>"
# runs: junie --skip-update-check --resume --task "<task>"
```

`--resume` continues the last Junie session in that directory, headless.

## In the IDE (RustRover and others)

In the IDE's AI chat you pick the agent; each runs through ACP. When the agent is Junie,
there is no warning: Junie's ACP host does not call hooks yet (Junie docs, "Hooks →
Limitations"). Other agents in the chat (Claude Agent, Codex, …) depend on whether their
ACP bridge loads the agent's own hooks; not checked yet. What works for sure:

- Junie CLI in the IDE's terminal: everything above.
- Claude Code in the IDE's terminal (with the Claude Code JetBrains plugin or without):
  the regular [Claude Code](../../README.md#claude-code) setup.
- `continuum watch` in a terminal tab, for any agent.

## Status

Run live with Junie CLI 26.10.20 in batch mode: the `Stop` warning arrived and Junie put
it in its final message; `junie --resume --task` continued the same session headless.
The `PreToolUse` warning and the interactive TUI are tested in CI only.
