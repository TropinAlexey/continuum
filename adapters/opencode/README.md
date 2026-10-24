# opencode adapter

A plugin ([`continuum.js`](continuum.js)) that calls `continuum check`. opencode has no
command hooks; plugins are JavaScript modules it loads at startup.

| Plugin hook | What it does |
|---|---|
| `event` → `session.idle` | The turn ended: a new tier is sent to the session with `client.session.prompt`, so the agent answers by asking the user. |
| `tool.execute.after` | In the middle of a turn: the warning is appended to the tool output the model reads next. |

Child sessions (subagents, `parentID` set) are skipped. Install globally:

```sh
mkdir -p ~/.config/opencode/plugins
ln -s ~/.continuum/adapters/opencode/continuum.js ~/.config/opencode/plugins/continuum.js
```

or into `.opencode/plugins/` for one project. The plugin finds the code in
`$CONTINUUM_ROOT`, else `~/.continuum`. On Windows it runs `continuum.ps1` with `pwsh`.

Resume preset (`CONTINUUM_AGENT=opencode`): `opencode run --continue "<task>"`.

Status: tested in CI against a fake opencode client (`tests/opencode.mjs`); not yet run
live inside opencode.
