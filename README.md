<p align="center">
  <img src="assets/logo.png" width="200" alt="continuum">
</p>

<h1 align="center">continuum</h1>

<p align="center">
  <b>🇬🇧 English</b> | <b><a href="README.ru.md">🇷🇺 Русский</a></b>
</p>

<p align="center">
  <b>See the limit coming. Decide what to do. Auto-resume after reset.</b>
</p>

<p align="center">
  <a href="https://github.com/TropinAlexey/continuum/releases"><img src="https://img.shields.io/badge/version-0.5.0-brightgreen.svg" alt="version: 0.5.0"></a>
  <a href="https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml"><img src="https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="license: MIT"></a>
</p>

---

AI coding agents have usage limits per time window. When a limit hits mid-task, the session dies and you wait. **continuum** watches the budget, warns before it runs out, and — if you choose — sleeps until reset and resumes automatically.

## Install

**CLI** (works with any agent):

```sh
# Mac / Linux / BSD
curl -fsSL https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.sh | sh

# Windows (PowerShell)
irm https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.ps1 | iex
```

**Claude Code plugin** (adds automatic warnings — Claude stops at threshold and asks what to do):

```
/plugin marketplace add TropinAlexey/continuum
/plugin install continuum
```

Install both for the full experience: CLI for the command, plugin for automation. They don't conflict.

> Scripts are short — read [install.sh](install.sh) / [install.ps1](install.ps1) before running if you prefer.

### ⚠️ Before you install

- **Undocumented endpoint.** The `anthropic` provider calls `https://api.anthropic.com/api/oauth/usage` — not a public API, may change. Token goes in one `curl` header to one host. A few hundred lines of shell — read it.
- **`continuum resume` runs Claude unattended** with `--permission-mode acceptEdits`. Keep prompts narrow. Don't point it at anything you wouldn't let a stranger merge.

## What happens

When utilization crosses a threshold, Claude stops and asks:

> *Window is 86% full, resets at 21:40. What do we do?*

Options include: wrap up, finish the current batch, save & auto-resume, frugal mode (blocks subagents), cheap tasks only, or ignore. Asks in your language. Tiered warnings — **80% → 90% → 95% → 99%** — each fires once. Weekly window tracked separately (**70% → 85% → 95%**). If usage drops back below the threshold (limit top-up or window rollover), tiers re-arm and fire again on the way up.

Choose "save and continue" → commits, schedules `claude --continue` for after reset, gives you the PID. Close your laptop. Session resumes without you.

## Usage

```sh
continuum status      # 5 hours   86.5%   resets at 21:40
                      # 7 days    41.0%   resets at 02:00
continuum reset       # 21:41   (reset +90s, ready for scheduling)
continuum estimate    # at this pace, ~2h 15m left
continuum watch       # poll in a spare pane; bell at threshold
continuum history     # last 20 usage snapshots
continuum cleanup     # remove stale flag/cache files (>24h old)
continuum providers   # anthropic, mock, spend
continuum statusline  # show status-line format config

continuum resume "$(continuum reset)" "$PWD" "finish the DocumentService tests"
```

**Other agents:** `continuum watch` and `continuum resume` work without the plugin:

```sh
CONTINUUM_RESUME_CMD='codex exec "{prompt}"'    continuum resume 21:41 "$PWD" "finish the tests"
CONTINUUM_RESUME_CMD='opencode run "{prompt}"'  continuum resume 21:41 "$PWD" "finish the tests"
```

See [docs/harnesses.md](docs/harnesses.md) for what's tested.

## How it works

Claude Code runs a `Stop` hook after every turn. A hook that prints `{"decision":"block","reason":"..."}` sends the reason back to the model instead of ending the turn. That's the whole trick.

Four pieces:

1. **Provider** (`providers/anthropic.sh`) — `curl` to the usage endpoint, prints `5h 86.5 1783000000` (window, percent, reset epoch). The entire provider contract is these three columns.
2. **Stop hook** (`hooks/continuum-check.sh`) — calls the provider through a 10-min cache (positive and negative), compares against tiers, prints the blocking JSON. Checks `stop_hook_active` first (otherwise infinite loop). Per-session flag means each tier fires once.
3. **PreToolUse hook** (`hooks/frugal-gate.sh`) — in frugal mode (`CONTINUUM_FRUGAL=1`), blocks `Agent` calls at hook level.
4. **Skill** (`skills/session-budget`) — what the reason tells Claude to run. Shows the situation, offers choices via `AskUserQuestion`. Never decides for you.
5. **`continuum resume`** — schedules `claude --continue -p "$PROMPT"` for after reset. Picks the best OS scheduler automatically, prevents sleep, notifies on completion.

## Resume

`continuum resume` picks the best scheduler and prevents system sleep automatically:

| OS | Scheduler | Survives reboot | Wakelock |
|---|---|---|---|
| macOS | `launchd` | yes | `caffeinate -i` |
| Linux | `systemd-run --user` | yes | `systemd-inhibit` |
| FreeBSD | `daemon(8)` | logout only | — |
| Windows | detached process | no | `SetThreadExecutionState` |
| Fallback | `nohup sleep` | no | best available |

Log: `~/.claude/continuum-resume.log` — markers `### resumed in DIR` / `### end (exit N)`. Desktop notification on completion (`osascript` / `notify-send`).

## Status line

Shows usage percentage in the Claude Code status bar: **green** (<80%), **yellow** (80–94%), **red** (≥95%). Updates every ~30s.

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh \"$HOME/.claude/hooks/statusline.sh\""
  }
}
```

Plugin install copies the script automatically (the CLI installer enables it in `settings.json` too, creating the file if missing).

Windows (PowerShell): use `hooks/statusline.ps1` as the `statusLine` command and `continuum.ps1 statusline` for the same config keys.

Customize the format — tokens `{d%}` daily %, `{w%}` weekly %, `{dr}` daily reset, `{wr}` weekly reset:

```sh
continuum statusline                    # show current config
continuum statusline format "{d%}% d {dr} | {w%}% w {wr}"
continuum statusline format-single "{d%}% d {dr}"   # shown when only one window exists
continuum statusline time "%H:%M"       # reset time format
continuum statusline date "%d.%m"       # reset date format (when not today)
continuum statusline today "today"      # word for same-day resets
continuum statusline reset              # back to defaults
```

## Providers

continuum is provider-agnostic — it asks "how much is used, when does it reset" and doesn't care about the source.

A provider is a script that prints: `5h 86.5 1783000000` — that's the entire interface. Write your own in 10 minutes: [docs/writing-a-provider.md](docs/writing-a-provider.md).

**Multiple providers:** `CONTINUUM_PROVIDER=anthropic,spend` — runs both, takes the highest utilization (spaces around the comma are fine).

## Platforms

macOS, Linux, FreeBSD/OpenBSD/NetBSD, Windows (Git Bash or PowerShell). POSIX `sh` + `curl`, no dependencies. CI tests both `.sh` and `.ps1` on all platforms.

Windows without Git Bash — override hooks in `settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/hooks/continuum-check.ps1\"",
      "shell": "powershell"
    }]}],
    "PreToolUse": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/hooks/frugal-gate.ps1\"",
      "shell": "powershell"
    }]}]
  }
}
```

## Configuration

| Variable | Default | What it does |
|---|---|---|
| `CONTINUUM_THRESHOLD` | `80` | Primary window threshold (%). |
| `CONTINUUM_TIERS` | `80 90 95 99` | Primary tiers. Each fires once. |
| `CONTINUUM_THRESHOLD_7D` | `70` | Weekly window threshold. |
| `CONTINUUM_TIERS_7D` | `70 85 95` | Weekly tiers. |
| `CONTINUUM_PROVIDER` | `anthropic` | Provider(s), comma-separated. |
| `CONTINUUM_RESUME_CMD` | `claude --continue …` | Agent command for `resume`. `{prompt}` = task. |
| `CONTINUUM_DRY_RUN` | — | `resume` prints instead of scheduling. |
| `CONTINUUM_OFF` | — | Disable the Stop hook. |
| `CONTINUUM_FRUGAL` | — | `1` = frugal mode: blocks Agent calls. |
| `CONTINUUM_CACHE_MIN` | `10` | Cache duration (minutes). `0` disables. |
| `CONTINUUM_SPEND_CAP` | `100` | Monthly budget ($) for the `spend` provider. Must be a positive number. |
| `ANTHROPIC_ADMIN_KEY` | — | Admin API key for the `spend` provider. |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth token for the `anthropic` provider. Fallback when Keychain / `~/.claude/.credentials.json` have nothing usable. |

## Troubleshooting

**Nothing at 80%.** Hook fires on `Stop` only. Run `sh tests/run.sh`. Passes → plugin not loaded, check `/plugin`.

**`usage endpoint unavailable`.** Offline, rate-limited (wait 10 min — negative cache), or token expired. Re-login to Claude Code.

**`no OAuth token found`.** Not logged in or credentials misplaced. Export `CLAUDE_CODE_OAUTH_TOKEN`.

**`continuum resume` didn't work.** Check `~/.claude/continuum-resume.log`. macOS: `launchctl list | grep continuum`. Linux: `systemctl --user list-timers | grep continuum`.

**Warning appears, Claude ignores it.** Lower `CONTINUUM_THRESHOLD`.

## Contributing

```
sh tests/run.sh          # 84 tests, mock provider, no network
pwsh tests/run.ps1       # same suite for PowerShell
```

What would help: a provider for another budget (OpenAI, Gemini — see [docs/writing-a-provider.md](docs/writing-a-provider.md)), and confirmation of `Stop` hook behavior in Codex CLI ([docs/harnesses.md](docs/harnesses.md)).

## Uninstall

```
/plugin uninstall continuum
rm -f /usr/local/bin/continuum
rm -f ~/.claude/.continuum-cache-* ~/.claude/.continuum-warned-* ~/.claude/.continuum-warned7d-* ~/.claude/.continuum-wakelock-* ~/.claude/.continuum-history.log
```

Or: `continuum cleanup` removes only stale files (>24h).

## License

MIT
