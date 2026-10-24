# Cursor adapter

Translates Cursor agent hook events into `continuum check` and back. Every script has a
PowerShell twin (`.ps1`); on Windows, Cursor runs hook commands through PowerShell.
Shared helpers: [`../lib.sh`](../lib.sh). The session is Cursor's `conversation_id`.

| Event | Script | Reply |
|---|---|---|
| `stop` | `stop.sh` | `{"followup_message":"..."}`: Cursor submits it as the next user message. Only after a `completed` turn, and never when `loop_count` is above 0. |
| `postToolUse` | `tool-check.sh` | `{"additional_context":"..."}`, injected after the tool result. |

Add to `~/.cursor/hooks.json` (or `<repo>/.cursor/hooks.json`), with the path of your
install (`~/.continuum` for the CLI installer):

```json
{
  "version": 1,
  "hooks": {
    "stop": [{ "command": "sh \"$HOME/.continuum/adapters/cursor/stop.sh\"" }],
    "postToolUse": [{ "command": "sh \"$HOME/.continuum/adapters/cursor/tool-check.sh\"" }]
  }
}
```

On Windows: `"command": "pwsh -NoProfile -File <path>\\stop.ps1"` (and `tool-check.ps1`).

Resume preset (`CONTINUUM_AGENT=cursor`): `agent -p --continue "<task>"`. Without
`--force` the headless agent only proposes changes. `--force` would also let it run any
command unattended, so it is not the default: opt in with
`CONTINUUM_RESUME_CMD='agent -p --force --continue "{prompt}"'` if you want that.

Status: the reply shapes follow the Cursor hooks docs and are tested in CI; not yet run
live inside Cursor. Forum reports say some Cursor versions on Windows ignore hook output.
