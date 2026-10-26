# continuum in bb

bb (`bb.app`, CLI `bb`) is a desktop app that runs coding agents (Claude Code, Codex, pi, …) in
threads. It is a harness around agents, not an agent itself, so this adapter has no hook
scripts of its own: the warning comes from the adapter of the agent running in the thread.

## Warning in a thread

- **Claude Code** threads start through the Claude Agent SDK with
  `settingSources: ["user", "project", "local"]`, so the plugins enabled in your
  `~/.claude/settings.json` load, continuum included. Install the Claude Code plugin as
  usual ([README](../../README.md#claude-code)); nothing to add in bb.
- **Codex** threads run the Codex CLI, which reads `~/.codex/hooks.json`: set up
  [`adapters/codex/`](../codex/README.md).
- Other providers (pi, ACP agents): no adapter yet. Use `continuum watch` in a terminal pane.

The status line is a Claude Code terminal feature; bb does not show it.

## Resume into the same thread

bb sets `BB_THREAD_ID` for the agent it runs. When it is set, `continuum resume` sends the
task back into that thread instead of starting a separate headless session:

```sh
bb thread tell <BB_THREAD_ID> "<task>"
```

The id is captured when the resume is scheduled. `bb` is written as an absolute path (from `PATH`, otherwise
`~/.bb/bin/bb`), since launchd runs the job with a short `PATH`. bb must be running at the reset time, since `bb thread tell` talks to its
local server. `CONTINUUM_RESUME_CMD` still wins over this; to resume outside bb, set it,
e.g. `CONTINUUM_RESUME_CMD='claude --continue -p "{prompt}"'`.

Check before trusting it:

```sh
CONTINUUM_DRY_RUN=1 continuum resume 21:41 "$PWD" "finish the migration"
# would sleep 3600 then run in /repo: bb thread tell th_… "finish the migration. Work autonomously: …"
```

## Status

Tested in CI (the resume command). Not yet run live in bb.
