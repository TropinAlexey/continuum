# Any agent, any shell

continuum has two halves, and they have different amounts of universality. Being clear about
which is which matters more than claiming to support everything.

## The universal half

`continuum status`, `continuum reset`, `continuum watch` and `continuum resume` are plain
commands. They know nothing about your editor, your agent, or your model. Run them in any
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

`continuum resume` runs whatever `CONTINUUM_RESUME_CMD` says. `{prompt}` is replaced with the
task description; if you leave the placeholder out, the command runs as written.

```sh
# default
CONTINUUM_RESUME_CMD='claude --continue -p "{prompt}" --permission-mode acceptEdits'

# others
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

The good part — Claude *stopping mid-session to ask you what to do* — needs a hook that can
interrupt a turn and hand text back to the model. Not every agent has one.

| Harness | Warning | Interactive question | Status |
|---|---|---|---|
| **Claude Code** | yes | yes | Supported. `Stop` hook returning `{"decision":"block","reason":...}`. Tested in CI on Linux, macOS, Windows. |
| **Codex CLI** | probably | unknown | Codex has lifecycle hooks including `Stop`, and its config accepts the same `hooks.json` schema. Whether it honours a `block` decision is undocumented. **Untested — try it and tell us.** |
| **Anything else** | yes, via `continuum watch` | no | The watcher tells *you*. You decide, and you tell the agent. |

If your harness supports blocking hooks and you get it working, send a PR with the config
snippet and we will add a row — with an honest note about what is verified and what is not.

## Codex CLI, experimental

Codex reads hooks from `hooks.json` or a `[hooks]` table in `config.toml`, with `Stop` among the
supported events. The hook script is the same one Claude Code uses:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "sh /path/to/continuum/hooks/continuum-check.sh" } ] }
    ]
  }
}
```

If Codex ignores the `block` decision you will get no warning and no error — the hook will simply
print JSON into the void. In that case use `continuum watch` instead. Do not assume it worked
because nothing broke.

## Why not a daemon

A background service that watches your budget and notifies you would work everywhere, and it is
the obvious design. It is also a process that outlives your session, holds your OAuth token in
memory, and has to be installed, supervised, and uninstalled.

`continuum watch` is a `while` loop you can read in ten seconds and kill with `Ctrl-C`. When it
stops being enough, that is the moment to build the daemon — not before.
