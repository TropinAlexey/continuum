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
  <a href="https://github.com/TropinAlexey/continuum/releases"><img src="https://img.shields.io/badge/version-0.8.0-brightgreen.svg" alt="version: 0.8.0"></a>
  <a href="https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml"><img src="https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml/badge.svg" alt="ci"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="license: MIT"></a>
</p>

---

AI coding agents have a usage limit per time window, for example 5 hours and a week. When the limit hits in the middle of a task, the session stops and you wait for the reset. **continuum** watches the budget, warns before it runs out and asks what to do with what is left. If you choose, it waits for the reset and resumes the work on its own.

- **Warnings at 80 / 90 / 95 / 99 %:** your agent stops and asks you what to do. It never decides for you.
- **Auto-resume:** schedules your agent for right after the reset, keeps the machine awake and notifies you when it is done.
- **Limit hit mid-turn:** a notification and a note for the next session, and, if you agreed in advance (`CONTINUUM_RESUME_ON_LIMIT=1`), a resume scheduled for the reset.
- **Status line:** current usage of both windows, in agents that have a status bar.
- **`continuum doctor`:** says why a warning did not fire (plugin off, old hooks, stale copies).

The core doesn't know which agent calls it or where the numbers come from: agents plug in through thin [adapters](#agents), budgets through [providers](#providers). POSIX `sh` and `curl`, no dependencies. macOS, Linux, BSD, Windows.

## Install

**1. The CLI** (the `continuum` command, works with any agent):

```sh
# Mac / Linux / BSD
curl -fsSL https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.sh | sh

# Windows (PowerShell)
irm https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.ps1 | iex
```

The install scripts are short, so read [install.sh](install.sh) / [install.ps1](install.ps1) first if you prefer.

**2. Your agent's adapter**, for warnings inside the session. See [Agents](#agents) for what exists; `continuum install --agent codex|gemini|cursor|opencode` wires one into the agent's config for you. An agent without an adapter can still call `continuum check` from its own hook, or you can run `continuum watch` in a spare pane.

## What it touches

What the core reads, sends, writes and runs. Each adapter adds its own list, in its section below.

- **Network.** Only the provider talks to the network. The default `anthropic` provider makes one `GET https://api.anthropic.com/api/oauth/usage` with an OAuth token in the `Authorization` header. This is an **undocumented endpoint**, not a public API, and it may change. The result is cached for 10 minutes. The optional `spend` provider calls `https://api.anthropic.com/v1/billing/usage` with `ANTHROPIC_ADMIN_KEY`, the optional `openrouter` provider `GET https://openrouter.ai/api/v1/key` with `OPENROUTER_API_KEY`. `watch --ide` talks only to the IDE on `127.0.0.1`. Nothing else leaves the machine.
- **Credentials.** The `anthropic` provider looks for the token in this order: `$CLAUDE_CODE_OAUTH_TOKEN`, the macOS Keychain entry `Claude Code-credentials`, then `~/.claude/.credentials.json`. It goes only to `api.anthropic.com` and is never written anywhere. The `openrouter` provider sends `OPENROUTER_API_KEY` only to `openrouter.ai` (`GET /api/v1/key`) and reads no other credential files. Tokens and keys reach `curl` on stdin (`-K -`), never on its command line, where any local process could read them.
- **Files.** Cache, flags, logs and config go to `~/.local/state/continuum` (see [Configuration](#configuration)). The CLI installer puts the code in `~/.continuum` and a symlink to it on your `PATH`. `continuum doctor` reads `~/.claude/settings.json`, the plugin cache and `~/.junie/extensions` to report; only `doctor --fix` writes, and only the status line copy in `~/.claude/hooks/` and the root pointer in the state directory.
- **Notifications.** A desktop notification (`osascript` / `notify-send`, or your `CONTINUUM_NOTIFY_CMD`) when a resume run ends and when the limit runs out mid-turn. The text goes to `osascript` as arguments, never as script.
- **Agent configs (only `continuum install --agent <x>`).** Writes the adapter's hooks into `~/.codex/hooks.json`, `~/.gemini/settings.json` or `~/.cursor/hooks.json` (a backup `<file>.continuum-bak` first, refuses files that already have `"hooks"`), or links the opencode plugin into `~/.config/opencode/plugins/`. `continuum uninstall --agent <x>` undoes it while the file is unchanged.
- **IDE (only `watch --ide`).** Finds the MCP server of a running JetBrains IDE on `127.0.0.1` (the ports its processes listen on, via `lsof`, or `CONTINUUM_IDE_MCP_URL`), writes the warning to `<project>/.git/continuum-warning.md` and asks the IDE to open that file. Nothing else is sent; nothing at all without `--ide`.
- **Unattended runs.** `continuum resume` starts your agent with nobody watching, using the agent's preset or `CONTINUUM_RESUME_CMD`; inside a bb thread it sends the task to that thread with `bb thread tell` instead. It runs only when you ask for it: by choosing "save and resume", by running the command, or by setting `CONTINUUM_RESUME_ON_LIMIT=1` in advance, which schedules a resume when the limit runs out in the middle of a turn. Keep the task narrow, and don't point it at anything you wouldn't let a stranger merge.

## What happens

When usage crosses a threshold, your agent stops and asks:

> *Window is 86% full, resets at 21:40. What do we do?*

The options are: wrap up, finish the current batch, save and auto-resume, frugal mode (no subagents), cheap tasks only, or ignore. The agent asks in your language.

Warnings come in tiers, **80% → 90% → 95% → 99%**, and each tier fires once. The weekly window is tracked separately (**70% → 85% → 95%**), and its warning names the day and time it resets ("resets Fri 18:28"). If usage drops back below a tier, because the window rolled over or the limit was topped up, that tier re-arms and fires again on the way up.

When the agent lets an adapter look in after every tool call, the check runs in the middle of a turn too, so a long turn of builds or parallel subagents can't cross the threshold unnoticed. The agent then finishes the step it is on, leaves the work in a consistent state, and asks.

Choose "save and resume": the agent commits its work, schedules itself for after the reset and gives you the PID. You can close the laptop, and the session continues without you.

## Usage

```sh
continuum status      # 5 hours   86.5%   resets at 21:40
                      # 7 days    41.0%   resets at 02:00
continuum reset       # 21:41   (reset +90s, ready for scheduling)
continuum estimate    # at this pace, ~2h 15m left
continuum watch       # poll in a spare pane; bell at threshold
continuum watch --ide # same, and show the warning in a JetBrains IDE (its AI chat runs no hooks)
continuum history     # last 20 snapshots taken by `continuum status`
continuum cleanup     # remove stale flag/cache files (>24h old)
continuum doctor      # why no warning: provider, plugin enabled, old hooks, stale copies (--fix: safe fixes)
continuum install --agent codex   # wire an adapter into the agent's config (codex|gemini|cursor|opencode; --dry-run)
continuum providers   # anthropic, mock, openrouter, spend
continuum check       # prints a warning when a new tier is crossed, else nothing
continuum statusline  # show status-line format config

continuum resume "$(continuum reset)" "$PWD" "finish the DocumentService tests"
```

Give `resume` a concrete task, not a generic "continue": the resumed session starts with only that prompt and the repository.

## Agents

The core (`bin/`, `lib/`, `providers/`) never asks which agent is calling. Each agent gets a thin adapter in `adapters/<agent>/` that turns its hook protocol into `continuum check` and back.

| Agent | In-session warning | Resume preset | Status |
|---|---|---|---|
| **Claude Code** | [adapter](#claude-code), plugin | `CONTINUUM_AGENT=claude` (default) | Supported, run live, tested in CI |
| **Codex CLI** | [adapter](#codex-cli), `hooks.json` | `CONTINUUM_AGENT=codex` | New: tested in CI, not yet run live |
| **Gemini CLI** | [adapter](#gemini-cli), `settings.json` | `CONTINUUM_AGENT=gemini` | New: tested in CI, not yet run live |
| **Cursor** | [adapter](#cursor), `hooks.json` | `CONTINUUM_AGENT=cursor` | New: tested in CI, not yet run live |
| **opencode** | [adapter](#opencode), JS plugin | `CONTINUUM_AGENT=opencode` | New: tested in CI, not yet run live |
| **Junie** (JetBrains: RustRover, IDEA, …) | the Claude Code plugin, installed as a Junie extension ([Junie](#junie-jetbrains)) | `CONTINUUM_AGENT=junie` | Run live (Junie CLI 26.10.20, batch); the IDE chat calls no hooks yet |
| **bb** (app) | the adapter of the agent in the thread ([bb](#bb)) | automatic: `bb thread tell` into the same thread | New: tested in CI, not yet run live |
| Anything else | `continuum check` from a hook, or `continuum watch` in a spare pane | set `CONTINUUM_RESUME_CMD` | Works today |

```sh
CONTINUUM_AGENT=codex continuum resume 21:41 "$PWD" "finish the tests"
CONTINUUM_RESUME_CMD='myagent run "{prompt}"' continuum resume 21:41 "$PWD" "finish the tests"
```

"Tested in CI" means each adapter's replies are checked against the agent's documented hook protocol. "Run live" means a real session of that agent received the warning; what was run, when and how is in [docs/live-checks.md](docs/live-checks.md). If you run one live, tell us how it went (an issue or a PR to [docs/harnesses.md](docs/harnesses.md)).

The agent and the provider are independent: a Codex session can watch the Anthropic window, and the other way round. See [docs/harnesses.md](docs/harnesses.md) for what is tested and how to write an adapter.

## How it works

Most agents can run a hook when a turn ends, and some after every tool call. If the hook's answer can send text back to the model instead of ending the turn, that text is where the warning goes. That is the whole trick.

```
agent event ──► adapters/<agent>/ ──► continuum check ──► provider
                (agent protocol)       (tiers, cache,      (usage, reset)
                                        flags, message)
```

1. **Provider** (`providers/anthropic.sh`): `curl` to the usage endpoint, prints `5h 86.5 1783000000` (window, percent, reset epoch). These three columns are the whole provider contract.
2. **`continuum check`**: the agent-neutral core of the warning. It calls the provider through a 10-minute cache (successes and failures alike), compares the result with the tiers and prints the warning text or nothing. A per-session flag makes each tier fire once, whichever hook sees it first.
3. **Adapter** (`adapters/<agent>/`): turns the agent's events into `continuum check --session … --agent <name>` and the text into whatever the agent's hook protocol expects.
4. **Skill** (`skills/session-budget`): what the warning tells the agent to run. It shows the situation and asks you with the agent's question tool, if it has one. It never decides for you.
5. **`continuum resume`**: schedules your agent's headless command for after the reset. It picks the best OS scheduler, keeps the machine awake and notifies you when the run ends.

## Resume

`continuum resume` picks the scheduler and keeps the system awake on its own:

| OS | Scheduler | Survives reboot | Wakelock |
|---|---|---|---|
| macOS | `launchd` | yes | `caffeinate -i` |
| Linux | `systemd-run --user` | yes | `systemd-inhibit` |
| FreeBSD | `daemon(8)` | logout only | — |
| Windows | detached process | no | `SetThreadExecutionState` |
| Fallback | `nohup sleep` | no | best available |

The log is `continuum-resume.log` in the state directory, with markers `### resumed in DIR` and `### end (exit N)`. A desktop notification (`osascript` / `notify-send`) comes when the run ends.

When the limit runs out in the middle of a turn (Claude Code and Junie report it as `StopFailure`), nothing can be asked any more: continuum notifies you and leaves a note for the next session start. With `CONTINUUM_RESUME_ON_LIMIT=1` it also schedules the resume for the reset, if that is within a day.

Inside a [bb](#bb) thread the resumed run is not a separate headless session: the task goes back into the same thread with `bb thread tell`.

## Providers

continuum doesn't care where the numbers come from. It only asks how much of the window is used and when it resets.

A provider is a script that prints `5h 86.5 1783000000`, and that is the entire interface. You can write your own in 10 minutes: [docs/writing-a-provider.md](docs/writing-a-provider.md).

Bundled: `anthropic` (the Claude subscription window, default), `spend` (Anthropic API spend against `CONTINUUM_SPEND_CAP`), `openrouter` (an OpenRouter key: its limit and reset schedule via the documented `GET /api/v1/key`, key from `OPENROUTER_API_KEY` only; a key without a limit needs `CONTINUUM_OPENROUTER_CAP` in dollars), `mock` (tests).

**Several providers:** `CONTINUUM_PROVIDER=anthropic,spend` runs both and takes the highest usage. Spaces around the comma are fine.

## Platforms

macOS, Linux, FreeBSD/OpenBSD/NetBSD, Windows (Git Bash or PowerShell). POSIX `sh` and `curl`, no dependencies. CI runs both the `.sh` and the `.ps1` suites on every platform.

## Configuration

| Variable | Default | What it does |
|---|---|---|
| `CONTINUUM_THRESHOLD` | `80` | Primary window threshold (%). |
| `CONTINUUM_TIERS` | `80 90 95 99` | Primary tiers. Each fires once. |
| `CONTINUUM_THRESHOLD_7D` | `70` | Weekly window threshold. |
| `CONTINUUM_TIERS_7D` | `70 85 95` | Weekly tiers. |
| `CONTINUUM_PROVIDER` | `anthropic` | Provider(s), comma-separated. |
| `CONTINUUM_AGENT` | `claude` | Agent: `claude`, `codex`, `gemini`, `cursor` or `opencode`. Picks the `resume` preset and the wording of `continuum check` (`generic` when unset there). |
| `CONTINUUM_RESUME_CMD` | preset for the agent | Agent command for `resume`. `{prompt}` is the task. Wins over the preset. |
| `CONTINUUM_RESUME_ON_LIMIT` | off | `1`: when the limit runs out mid-turn (`StopFailure`), schedule a resume for the reset with the agent's preset. Only for a reset within 24 h; one per directory per window. Consent given in advance. |
| `CONTINUUM_NOTIFY_CMD` | `osascript` / `notify-send` | Replace the desktop notifier; gets title and message as two arguments. |
| `CONTINUUM_IDE_MCP_URL` | found via `lsof` | The JetBrains IDE MCP endpoint for `watch --ide`, e.g. `http://127.0.0.1:64342/stream`. |
| `CONTINUUM_OPENROUTER_CAP` | — | Budget in dollars for the `openrouter` provider when the key has no limit. Key: `OPENROUTER_API_KEY`. |
| `CONTINUUM_DRY_RUN` | — | `resume` prints the plan instead of scheduling it. |
| `CONTINUUM_OFF` | — | Turns the warning off (`continuum check` and every adapter hook). |
| `CONTINUUM_FRUGAL` | — | `1` = frugal mode: adapters that can, block subagent calls. |
| `CONTINUUM_CACHE_MIN` | `10` | Cache lifetime in minutes. `0` turns it off. |
| `CONTINUUM_STATE_DIR` | `~/.local/state/continuum` | Where cache, flags, logs and config live (else `$XDG_STATE_HOME/continuum`). Setting it skips the one-time migration from `~/.claude`. |
| `CONTINUUM_ROOT` | the install dir | Where the code lives, when a script can't tell by itself. |
| `CONTINUUM_SPEND_CAP` | `100` | Monthly budget ($) for the `spend` provider. Must be a positive number. |
| `ANTHROPIC_ADMIN_KEY` | — | Admin API key for the `spend` provider. |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | OAuth token for the `anthropic` provider. Checked before the Keychain and `~/.claude/.credentials.json`. |

## Troubleshooting

**No warning at 80%.** Run `continuum doctor` first: it checks the provider, that the plugin is enabled, old hooks still wired, and stale copies of the plugin, the status line and the Junie extension, with the fix for each. Then `sh tests/run.sh`. If it passes, the code is fine and the problem is in how your agent's adapter is wired; see its section below.

**`usage endpoint unavailable`.** You are offline, rate-limited (failures are cached too, so wait 10 minutes), or the token has expired. Log in again to the agent the token belongs to.

**`no OAuth token found`.** You are not logged in, or the credentials are somewhere unexpected. Export `CLAUDE_CODE_OAUTH_TOKEN`.

**`continuum resume` didn't run.** Look at `~/.local/state/continuum/continuum-resume.log`. macOS: `launchctl list | grep continuum`. Linux: `systemctl --user list-timers | grep continuum`.

**The warning appears, but the agent ignores it.** Lower `CONTINUUM_THRESHOLD` so it comes earlier.

## Claude Code

The adapter lives in [`adapters/claude/`](adapters/claude/README.md) and ships as a Claude Code plugin.

**Install:**

```
/plugin install continuum --marketplace TropinAlexey/continuum
```

On Claude Code older than 2.1.275, use two steps instead: `/plugin marketplace add TropinAlexey/continuum`, then `/plugin install continuum`. Restart the session afterwards: hooks are loaded at startup. The plugin and the CLI don't conflict.

**What it adds:**

- **Hooks.** `Stop`: at the end of a turn, a warning becomes `{"decision":"block","reason":"..."}`, so Claude goes on and asks you instead of stopping. `PostToolUse`: after each tool call, the same warning as `additionalContext`, about 0.1 s per call, silent inside subagents. `PreToolUse`: blocks the `Agent` tool, only in frugal mode (`CONTINUUM_FRUGAL=1`). `StopFailure` (`rate_limit`): the limit ran out mid-turn, so nothing can be asked; a notification, a line in the resume log and a note at the next session start, plus a scheduled resume if you set `CONTINUUM_RESUME_ON_LIMIT=1`. `SessionStart`: the resume report (and that note) and status line upkeep.
- **Settings.** On session start, if `~/.claude/settings.json` has no `statusLine` at all, the plugin copies its status line script to `~/.claude/hooks/statusline.sh` and adds a `statusLine` entry pointing there. Later it keeps that copy up to date. An existing status line, yours or anyone's, is left alone. The CLI installer does the same.
- **Questions.** The warning asks Claude to use `AskUserQuestion`.
- **Resume preset.** `claude --continue -p "<task>" --permission-mode acceptEdits`.

**Status line.** It shows usage in the status bar: **green** below 80%, **yellow** 80–94%, **red** from 95%. It refreshes about every 30 seconds. A stale cache (older than 10 minutes, or from before the window reset) is refreshed before the first render, so a new session shows current numbers right away. If the provider is unreachable, the old numbers stay and the next attempt waits 2 minutes.

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh \"$HOME/.claude/hooks/statusline.sh\""
  }
}
```

Customize the format with tokens `{d%}` (5-hour %), `{w%}` (weekly %), `{dr}` (5-hour reset), `{wr}` (weekly reset):

```sh
continuum statusline                    # show current config
continuum statusline format "{d%} d {dr} | {w%} w {wr}"
continuum statusline format-single "{d%} d {dr}"   # shown when only one window exists
continuum statusline time "%H:%M"       # reset time format
continuum statusline date "%d.%m"       # reset date format (when not today)
continuum statusline today "today"      # word for same-day resets
continuum statusline reset              # back to defaults
```

**Windows without Git Bash.** Use `adapters/claude/statusline.ps1` as the `statusLine` command and `continuum.ps1 statusline` for the same settings, and override the hooks in `settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/adapters/claude/stop.ps1\"",
      "shell": "powershell"
    }]}],
    "PostToolUse": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/adapters/claude/tool-check.ps1\"",
      "shell": "powershell"
    }]}],
    "StopFailure": [{ "matcher": "rate_limit", "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/adapters/claude/stop-failure.ps1\"",
      "shell": "powershell"
    }]}],
    "PreToolUse": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/adapters/claude/frugal-gate.ps1\"",
      "shell": "powershell"
    }]}]
  }
}
```

**No warning at 80%.** Check that the plugin is enabled: `/plugin` should list `continuum`. Then check that no old copy is wired in instead: `settings.json` should have no `Stop` hook pointing at `token-budget-check.sh` (a leftover from before the plugin was called continuum).

**Uninstall:** `/plugin uninstall continuum`, then `rm -f ~/.claude/hooks/statusline.sh` and remove `"statusLine"` from `~/.claude/settings.json`.

## Codex CLI

The adapter lives in [`adapters/codex/`](adapters/codex/README.md): a `Stop` hook (`decision: block`, so Codex continues and asks you) and a `PostToolUse` hook (`additionalContext`, in the middle of a turn). It changes nothing in Codex's config by itself: add the two hooks to `~/.codex/hooks.json` as the adapter's README shows (or run `continuum install --agent codex`), then approve them in `/hooks`. Codex runs a hook only once you trust it, and again after each update. Resume preset: `codex exec resume --last -c sandbox_mode=workspace-write "<task>"`.

## Gemini CLI

The adapter lives in [`adapters/gemini/`](adapters/gemini/README.md): an `AfterAgent` hook (`decision: deny`, so Gemini sends the warning back as a new prompt) and an `AfterTool` hook (`additionalContext`). It changes nothing in Gemini's config by itself: add the two hooks to `~/.gemini/settings.json` as the adapter's README shows, or run `continuum install --agent gemini`. Resume preset: `gemini --resume latest --approval-mode auto_edit -p "<task>"`.

## Cursor

The adapter lives in [`adapters/cursor/`](adapters/cursor/README.md): a `stop` hook (`followup_message`, sent as the next user message) and a `postToolUse` hook (`additional_context`). It changes nothing in Cursor's config by itself: add the two hooks to `~/.cursor/hooks.json` as the adapter's README shows, or run `continuum install --agent cursor`. Resume preset: `agent -p --continue "<task>"`. Without `--force` the headless agent only proposes changes. To let it change files and run commands unattended, opt in yourself: `CONTINUUM_RESUME_CMD='agent -p --force --continue "{prompt}"'`, with the same care as any unattended run.

## opencode

The adapter is a plugin, [`adapters/opencode/continuum.js`](adapters/opencode/README.md). On `session.idle` it sends the warning to the session as a prompt; after each tool call it appends it to the tool output. Install it with a symlink into `~/.config/opencode/plugins/`, as the adapter's README shows, or with `continuum install --agent opencode`. It runs `continuum check` and nothing else. Resume preset: `opencode run --continue "<task>"`.

## Junie (JetBrains)

Junie CLI installs Claude Code plugins as extensions and runs their hooks, so continuum works in it as is: in Junie, `/extensions`, add the marketplace `https://github.com/TropinAlexey/continuum`, install `continuum`. The Claude Code adapter recognizes Junie by its events (`project_path`, no `transcript_path`): the warning asks Junie to end its final message with a question (it has no question tool), the mid-turn check runs on `PreToolUse` (Junie has no `PostToolUse`), and Claude Code's settings are left alone. Resume preset: `junie --skip-update-check --resume --task "<task>"`. In the IDE (RustRover, IntelliJ IDEA, Rider, …) you pick the chat's agent; Junie there runs through ACP, which does not call hooks yet, and other chat agents are not checked yet: use Junie CLI or Claude Code in the IDE's terminal, or `continuum watch --ide`, which shows the warning in the IDE through its MCP server (enable it in Settings | Tools | MCP Server). See [`adapters/junie/`](adapters/junie/README.md).

## bb

bb is a desktop app that runs agents in threads, so the warning comes from the agent's own adapter: Claude Code threads load the plugins enabled in `~/.claude/settings.json` (install the [Claude Code](#claude-code) plugin), Codex threads read `~/.codex/hooks.json` ([Codex CLI](#codex-cli)). bb sets `BB_THREAD_ID` for the agent; when it is set, `continuum resume` sends the task back into the same thread with `bb thread tell <id> "<task>"` instead of a separate headless run (bb must be running at the reset; `CONTINUUM_RESUME_CMD` still wins). See [`adapters/bb/`](adapters/bb/README.md).

## Contributing

```
sh tests/run.sh          # 254 tests, mock provider, no network (also passes under dash)
pwsh tests/run.ps1       # 196 tests, the same suite for PowerShell
```

Every `.sh` change has a matching `.ps1` change, with tests in both suites. Help is welcome with a provider for another budget (OpenAI, Gemini: see [docs/writing-a-provider.md](docs/writing-a-provider.md)) and an adapter for another agent ([docs/harnesses.md](docs/harnesses.md)).

## Uninstall

```sh
rm -f "$(command -v continuum)"            # the CLI symlink (~/.local/bin, /usr/local/bin or ~/bin)
rm -rf ~/.local/state/continuum ~/.continuum
rm -f ~/.claude/.continuum-* ~/.claude/continuum-resume.log   # leftovers from before v0.6
```

Remove your agent's adapter as its section says. To remove only stale files (older than 24 hours), use `continuum cleanup`.

## License

MIT
