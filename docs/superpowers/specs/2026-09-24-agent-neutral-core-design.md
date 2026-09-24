# Agent-neutral core — design (subproject 1 of 5)

Date: 2026-09-24 · Status: draft, awaiting review

## Goal

Make continuum agent-agnostic: Claude Code becomes one adapter among several instead of the
thing the core is built around. This spec covers only the foundation — the agent-neutral core
and moving the existing Claude Code integration onto it as the first adapter.

### Decisions already made

- **Target agents** (full integration, eventually): Claude Code, Codex CLI, opencode, Cursor,
  Gemini CLI.
- **Agent and provider are independent axes.** This work is about integrating with agents only.
  The provider is still chosen via `CONTINUUM_PROVIDER` (default `anthropic`); new providers
  (OpenAI, Gemini) remain a separate backlog item.
- **State lives in continuum's own directory**, with a one-time migration from `~/.claude`.
- **Architecture: decision engine + thin adapters** (option A). Rejected: a `CONTINUUM_AGENT`
  switch inside the existing hooks (B) — the agents × hooks × sh/ps1 matrix explodes, and
  opencode's JS plugins do not fit at all.

### Decomposition

| # | Subproject | Depends on |
|---|---|---|
| 1 | **Agent-neutral core + Claude Code adapter** (this spec) | — |
| 2 | Codex CLI adapter (hooks, resume preset, verify whether `block` is honoured) | 1 |
| 3 | opencode adapter (JS plugin calling the sh core) | 1 |
| 4 | Cursor and Gemini CLI adapters | 1 |
| 5 | `continuum install --agent <x>` + docs | 1–4 |

Subprojects 2–4 each get their own spec, written against the agent's **current** documentation,
not from memory.

### Success criteria for subproject 1

1. With no new configuration, Claude Code users see exactly the same behaviour as today: the
   same warnings (text included), frugal gate, statusline, resume, and SessionStart report.
2. No file under `lib/`, `bin/` or `providers/` reads `CLAUDE_CONFIG_DIR` or `~/.claude`, except
   the migration code and the Claude adapter. `CLAUDE_PLUGIN_ROOT` is accepted only as a
   compatibility fallback for locating the root.
3. `continuum check` is usable from any agent with no adapter (from a shell or from an
   instruction in `AGENTS.md`).
4. Both suites are green: the existing 84 assertions (updated only mechanically for the new env
   vars) plus new tests, with sh/ps1 parity.

## Architecture

```
agent event ──► adapters/<agent>/<shim> ──► continuum check ──► lib/core.sh
                 (parse agent input,          (tiers, cache,      (providers,
                  format agent output)         flags, message)     paths, JSON)
```

- **Core** (`lib/`, `bin/`, `providers/`): does not know which agent is calling.
- **Adapter** (`adapters/<agent>/`): only translates the protocol. It has no logic for tiers,
  caching or messages.

## Components

### 1. Paths (`lib/core.sh`, `lib/core.ps1`)

New variables, replacing `CNT_CFG`:

| Variable | Resolution order |
|---|---|
| `CNT_STATE` (state) | `$CONTINUUM_STATE_DIR` → `$XDG_STATE_HOME/continuum` → `$HOME/.local/state/continuum` |
| `CNT_ROOT` (code) | `$CONTINUUM_ROOT` → `$CLAUDE_PLUGIN_ROOT` (compat) → caller-supplied `CNT_ROOT` → script directory |

- **Not `~/.continuum` and not `CONTINUUM_HOME`:** the installer already uses them for the *code*
  (a git clone that may be `rm -rf`'d on reinstall). State must not live there, and the variables
  must not mean two different things.
- `CNT_CFG` remains as a deprecated alias of `CNT_STATE` for third-party providers.
- The same order is used on every OS, sh and ps1 alike. That way Git Bash and PowerShell on one
  Windows machine share their state, as they do today through `~/.claude`.
- File names inside `CNT_STATE` stay as they are (`.continuum-cache-*`, `.continuum-warned-*`,
  `continuum-resume.log`, …). Renaming them is out of scope; it would enlarge the diff and touch
  the ps1 dotfile workarounds.
- User providers are looked up in `$CNT_ROOT/providers`, then `$CNT_STATE/providers`.
- **Root pointer:** `install.sh`, `install.ps1` and the adapter setup write the absolute root to
  `$CNT_STATE/root`. Scripts called without the environment (for example a statusline copied into
  `~/.claude/hooks/`) find the core through this file. This fixes today's fragile
  `CLAUDE_PLUGIN_ROOT`-or-`~/.claude/lib` lookup.

### 2. Migration (`cnt_migrate` in core, sh + ps1)

- Called on core load. It is idempotent and cheap: it returns immediately if
  `$CNT_STATE/.migrated` exists.
- Source: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.
- It **copies** (the originals are not deleted) `.continuum-statusline.conf`,
  `.continuum-history.log`, `continuum-resume.log` and `providers/*.{sh,ps1}`, but only files
  that are not already in `CNT_STATE`.
- It does not copy caches, flags or pid files. They are ephemeral and are recreated on their own.
- It never fails the caller: on any error it stays silent and does not write the marker, so the
  next run retries.
- It is skipped when `CONTINUUM_STATE_DIR` is set explicitly (tests, and users with a custom home).

### 3. `continuum check` (new CLI command)

```
continuum check [--session ID] [--agent NAME]
```

- All the logic of today's `hooks/continuum-check.sh` moves here: the `CONTINUUM_OFF` check,
  the cache and negative cache, primary and weekly tiers, flags, re-arming when usage drops, and
  sanitising the session id and cache key.
- **Output:** empty stdout means stay silent. Non-empty stdout is the warning text, one line in
  plain text rather than JSON.
- **Exit code:** 0 in both cases, including when the provider fails (as today: never break the
  agent's turn). Non-zero only for invalid arguments.
- `--session` defaults to `default`.
- `--agent` (default `$CONTINUUM_AGENT`, otherwise `generic`) affects only the closing sentence
  of the text, `cnt_ask_hint <agent>`:
  - `claude`: *"…run the session-budget skill - … then use AskUserQuestion to ask the user…"*
    (character-for-character today's text).
  - `generic`: *"…stop and briefly state where we stopped, then ask the user how to spend the rest
    of the window (wrap up / finish batch / save + resume after reset / frugal / ignore)."*
  - Subprojects 2–4 add their own lines to this table.
- ps1: `continuum.ps1 check` with the same contract.

### 4. Claude Code adapter (`adapters/claude/`)

| File | Role |
|---|---|
| `stop.sh` / `.ps1` | Reads the stdin event, exits immediately on `stop_hook_active:true`, extracts `session_id` and calls `continuum check --session "$sid" --agent claude`. If there is text, prints `{"decision":"block","reason":"<escaped>"}`. |
| `frugal-gate.sh` / `.ps1` | The same gate. The list of expensive tools (`Agent`) lives here, because it is a Claude tool name. |
| `statusline.sh` / `.ps1`, `setup-statusline.sh` | Moved from `hooks/`. They find the core via `CONTINUUM_ROOT` / `CLAUDE_PLUGIN_ROOT` / `$CNT_STATE/root`. Setup keeps patching `~/.claude/settings.json`: that part really does belong to Claude. |
| `resume-report.sh` | Moved from `hooks/`, reads `$CNT_STATE/continuum-resume.log`. |

- `hooks/hooks.json` stays at the standard plugin location (no need for an unverified custom
  `hooks` path in `plugin.json`). Its commands point at `${CLAUDE_PLUGIN_ROOT}/adapters/claude/...`.
- **Compatibility for one release (until v0.7):** the old `hooks/continuum-check.sh`,
  `hooks/frugal-gate.sh` and `hooks/statusline.sh` (and their `.ps1` versions) become 2-line
  forwarders into `adapters/claude/`. Existing `settings.json` files and the Codex snippet from
  `docs/harnesses.md` keep working.

### 5. Resume presets (`bin/continuum`, `bin/continuum.ps1`)

- Command resolution: `CONTINUUM_RESUME_CMD` (explicit) → preset for `CONTINUUM_AGENT` → preset
  `claude`.
- In this subproject the preset table contains only `claude` (today's command). Presets for
  codex, opencode, cursor and gemini arrive with their adapters, after checking the real CLI
  flags.
- An unknown `CONTINUUM_AGENT` with no `CONTINUUM_RESUME_CMD` is an error with a hint to set
  `CONTINUUM_RESUME_CMD`. It must not silently fall back to claude.

### 6. Skills (`skills/session-budget`, `skills/auto-resume`)

- The text becomes neutral: "ask the user using your agent's question tool (in Claude Code:
  AskUserQuestion)". Paths become `~/.local/state/continuum/...` (or `continuum` commands instead of paths), and `claude --continue` becomes "the
  resume command (`CONTINUUM_RESUME_CMD`)".
- Content and options do not change.

## Error handling

The existing guarantees are preserved:

- A hook never exits non-zero and never spams the agent.
- A provider failure means silence plus a negative cache.
- The session id and cache key are allowlisted.
- The JSON reason is escaped. This moves into the Claude shim, because the core now returns
  plain text.

Migration and the root pointer are best-effort and never fail the caller.

## Testing

- **`tests/run.sh` / `run.ps1`:** the `hook()` helper uses `CONTINUUM_STATE_DIR` instead of
  `CLAUDE_CONFIG_DIR` and calls `adapters/claude/stop.sh`. The assertions do not change.
- **New tests (in both suites):**
  1. `continuum check`: silent below threshold; text at a tier crossing; the same tier does not
     fire twice; `--agent claude` gives today's text and `--agent generic` the neutral one.
  2. Paths: the resolution order for `CONTINUUM_STATE_DIR` → `XDG_STATE_HOME` → `~/.local/state/continuum` (with a
     temporary `HOME`).
  3. Migration: copies the conf, logs and providers; does not overwrite existing files; does not
     copy the cache; creates the marker; is a no-op on a second run.
  4. Root pointer: a statusline copied into a separate directory with no environment still
     finds the core.
  5. Old `hooks/*.sh` forwarders give the same output as the adapter.
  6. Resume: `CONTINUUM_AGENT=claude` plus dry run gives today's command; an unknown agent
     without `CONTINUUM_RESUME_CMD` fails; an explicit `CONTINUUM_RESUME_CMD` beats the preset.
- CI (`.github/workflows/ci.yml`) is unchanged.

## Documentation

- README.md and README.ru.md (kept in sync): the "State directory" section, the agent/provider
  axes, and `continuum check`.
- `docs/harnesses.md`: the architecture diagram and a "Writing an adapter" section (the
  `continuum check` contract).
- `AGENTS.md`: the repo map (`adapters/`), the "How it works" section, and the backlog
  (subprojects 2–5).
- Version: this is a breaking change to the state path (softened by migration), so it ships as
  v0.6.0. The v0.5.1 release from the backlog should go out before this work starts.

## Out of scope

- Adapters for Codex, opencode, Cursor and Gemini; the `install --agent` command.
- New providers.
- Renaming files inside `CNT_STATE`.
- Deleting old files from `~/.claude`.
