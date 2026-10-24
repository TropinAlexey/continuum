# Gemini CLI adapter

Translates Gemini CLI hook events into `continuum check` and back. Every script has a
PowerShell twin (`.ps1`). Shared helpers: [`../lib.sh`](../lib.sh).

| Event | Script | Reply |
|---|---|---|
| `AfterAgent` | `after-agent.sh` | `{"decision":"deny","reason":"..."}`: Gemini rejects the final response and sends the reason back as a new prompt. Skips when `stop_hook_active` is set. |
| `AfterTool` | `after-tool.sh` | `hookSpecificOutput.additionalContext`, appended to the tool result. Never hides it. |

Add to `~/.gemini/settings.json` (or `<repo>/.gemini/settings.json`), with the path of
your install (`~/.continuum` for the CLI installer):

```json
{
  "hooks": {
    "AfterAgent": [{ "hooks": [{ "type": "command", "command": "sh \"$HOME/.continuum/adapters/gemini/after-agent.sh\"" }] }],
    "AfterTool": [{ "matcher": ".*", "hooks": [{ "type": "command", "command": "sh \"$HOME/.continuum/adapters/gemini/after-tool.sh\"" }] }]
  }
}
```

On Windows without a POSIX shell, use `pwsh -NoProfile -File <path>\\after-agent.ps1`
and `...\\after-tool.ps1` as the commands.

Resume preset (`CONTINUUM_AGENT=gemini`): `gemini --resume latest --approval-mode auto_edit -p "<task>"`.

Status: the reply shapes follow the Gemini CLI hooks reference and are tested in CI; not
yet run live inside Gemini CLI.
