# Any agent, any shell

continuum has two halves, and they have different amounts of universality. Being clear about
which is which matters more than claiming to support everything.

## The universal half

`continuum status`, `continuum reset`, `continuum check`, `continuum watch` and
`continuum resume` are plain commands. They know nothing about your editor, your agent, or your
model. Run them in any
terminal, on any operating system, against any provider.

**`continuum watch` is the answer for any harness that has no hooks at all.** Run it in a spare
pane. It polls, and the moment your budget crosses the threshold it rings the terminal bell and
tells you the reset time and the command to schedule a resume:

```
$ continuum watch          # checks every 5 minutes
continuum: 46% used, below 80%
continuum: 71% used, below 80%
continuum: 86% used, resets at 21:40
Wrap up, or: continuum resume 21:41 "$PWD" "<task>"
```

No plugin, no config, no hook. Works with Claude Code, Codex, OpenCode, Aider, Cursor, a plain
`curl` loop, or a person.

## Which agent gets resumed

`continuum resume` runs `CONTINUUM_RESUME_CMD` if set, otherwise the preset for
`CONTINUUM_AGENT` (default `claude`). An agent without a preset and without
`CONTINUUM_RESUME_CMD` is an error, never a silent fallback to Claude. `{prompt}` is replaced
with the task description; if you leave the placeholder out, the command runs as written.

```sh
# preset: CONTINUUM_AGENT=claude (the default)
CONTINUUM_RESUME_CMD='claude --continue -p "{prompt}" --permission-mode acceptEdits'

# others - presets arrive with each agent's adapter; until then, spell it out
CONTINUUM_RESUME_CMD='codex exec "{prompt}"'
CONTINUUM_RESUME_CMD='opencode run "{prompt}"'
CONTINUUM_RESUME_CMD='aider --message "{prompt}" --yes'
```

Check what will actually run before you trust it with your repository:

```sh
CONTINUUM_DRY_RUN=1 continuum resume 21:41 "$PWD" "finish the migration"
# would sleep 3600 then run in /repo: claude --continue -p "finish the migration" ...
```

## The half that depends on the harness

The good part — the agent *stopping mid-session to ask you what to do* — needs a hook that can
interrupt a turn and hand text back to the model. Not every agent has one.

```
agent event ──► adapters/<agent>/ ──► continuum check ──► provider
                (agent protocol)       (tiers, cache,
                                        flags, message)
```

All the logic lives in `continuum check`; an adapter only translates.

| Harness | Warning | Interactive question | Status |
|---|---|---|---|
| **Claude Code** | yes | yes | Supported: `adapters/claude/`. `Stop` hook returning `{"decision":"block","reason":...}`. Tested in CI on Linux, macOS, Windows. |
| **Codex CLI** | probably | unknown | Codex has lifecycle hooks including `Stop`, and its config accepts the same `hooks.json` schema. Whether it honours a `block` decision is undocumented. **Untested — try it and tell us.** |
| **Anything else** | yes, via `continuum watch` | no | The watcher tells *you*. You decide, and you tell the agent. |

If your harness supports blocking hooks and you get it working, send a PR with the config
snippet and we will add a row — with an honest note about what is verified and what is not.

## Codex CLI, experimental

Codex reads hooks from `hooks.json` or a `[hooks]` table in `config.toml`, with `Stop` among the
supported events. Until Codex has its own adapter, the Claude Code one speaks the same schema:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "sh /path/to/continuum/adapters/claude/stop.sh" } ] }
    ]
  }
}
```

If Codex ignores the `block` decision you will get no warning and no error — the hook will simply
print JSON into the void. In that case use `continuum watch` instead. Do not assume it worked
because nothing broke.

## Writing an adapter

An adapter is a few lines in `adapters/<agent>/` (plus a `.ps1` twin) that:

1. reads the agent's hook event and pulls out a session id;
2. bails out early if the agent says it is already handling a previous block (Claude:
   `stop_hook_active`) — otherwise you get an infinite loop;
3. runs `continuum check --session "$sid" --agent <agent>`:
   - empty stdout means stay silent;
   - otherwise stdout is one line of warning text;
   - the exit code is 0 either way — a provider failure is silence, not an error;
4. wraps that text in whatever the agent expects from a blocking hook.

Never exit non-zero from a hook, and escape the text for the agent's format — it contains
provider-controlled window labels. To tune the wording for your agent (its question tool, its
skill mechanism), add a line to `cnt_ask_hint` in `bin/continuum` and `Get-CntAskHint` in
`bin/continuum.ps1`. To add a resume preset, extend `cnt_resume_preset` / `Get-CntResumePreset`,
after checking the agent's real headless flags. Test both in `tests/run.sh` and `tests/run.ps1`.

## Why not a daemon

A background service that watches your budget and notifies you would work everywhere, and it is
the obvious design. It is also a process that outlives your session, holds your OAuth token in
memory, and has to be installed, supervised, and uninstalled.

`continuum watch` is a `while` loop you can read in ten seconds and kill with `Ctrl-C`. When it
stops being enough, that is the moment to build the daemon — not before.
