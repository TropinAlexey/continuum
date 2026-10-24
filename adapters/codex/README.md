# Codex CLI adapter

Translates Codex CLI hook events into `continuum check` and back. Every script has a
PowerShell twin (`.ps1`). Shared helpers: [`../lib.sh`](../lib.sh).

| Event | Script | Reply |
|---|---|---|
| `Stop` | `stop.sh` | `{"decision":"block","reason":"..."}`: Codex takes the reason as a continuation prompt. Skips when `stop_hook_active` is set. |
| `PostToolUse` | `tool-check.sh` | `hookSpecificOutput.additionalContext`, in the middle of a turn. Never blocks. |

Add to `~/.codex/hooks.json` (or `<repo>/.codex/hooks.json`), with the path of your
install (`~/.continuum` for the CLI installer):

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.continuum/adapters/codex/stop.sh\"" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.continuum/adapters/codex/tool-check.sh\"" }] }]
  }
}
```

Codex runs a hook only after you trust it: open `/hooks` in Codex and approve both.
Trust is tied to the script's hash, so approve again after updating continuum. On
Windows, add `"commandWindows": "pwsh -NoProfile -File <path>\\stop.ps1"` (and the same
for `tool-check.ps1`).

Resume preset (`CONTINUUM_AGENT=codex`): `codex exec resume --last -c sandbox_mode=workspace-write "<task>"`.

Status: the reply shapes follow the Codex hooks reference and are tested in CI; not yet
run live inside Codex.
