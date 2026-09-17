![continuum](assets/logo.png)

# continuum

> **🇬🇧 English** | **🇷🇺 [Русский](README.ru.md)**

**See the limit coming. Decide what to do with what's left. Auto pick up where you stopped.**

[![version: 0.5.0](https://img.shields.io/badge/version-0.5.0-brightgreen.svg)](https://github.com/TropinAlexey/continuum/releases) [![ci](https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml/badge.svg)](https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## What's new

**v0.5.0** — BSD support.

-   **FreeBSD / OpenBSD / NetBSD.** All hooks and providers work out of the box (POSIX sh). `continuum resume` uses `daemon(8)` on FreeBSD for clean detach; other BSDs use the `nohup` fallback.

v0.4.0 — Resume keeps the machine awake.

-   **Automatic wakelock.** `continuum resume` now prevents system sleep automatically for the entire wait + execution period. macOS — `caffeinate`, Linux — `systemd-inhibit`, Windows — `SetThreadExecutionState`. The wakelock releases automatically when the task finishes. No more manual `caffeinate`.
-   **Status line.** New `hooks/statusline.sh` hook shows the usage limit percentage directly in the Claude Code status bar — color-coded (green / yellow / red).

v0.3.1 — Resume finishes the job.

-   **Autonomous resume.** Every headless prompt now automatically gets an instruction to work independently: no questions, no waiting for confirmation, commit the result.
-   **Session start report.** A `SessionStart` hook checks `continuum-resume.log` and shows a summary of completed resumes from the last 24 hours.

---

## In short

AI coding agents have usage limits per time window. When a limit is hit mid-task, the session stops — and you wait for the reset yourself.

**continuum** tracks the remaining budget and warns you before it runs out, so you can wrap up cleanly. If you choose to wait — it sleeps until the limit resets and resumes the session automatically. No babysitting.

## Explain like I'm an engineer

Four parts glued together by one Claude Code mechanism. Nothing runs in the background.

1.  **Provider script** (`providers/anthropic.sh`) makes a `curl` to Anthropic's usage endpoint — token from `$CLAUDE_CODE_OAUTH_TOKEN`, macOS Keychain, or `~/.claude/.credentials.json` — and prints one line per window: `5h 86.5 1783000000` (name, percent, reset as Unix epoch). These three columns are the entire provider contract. Swap in a script that reports API spend or token limits — continuum won't notice.
    
2.  **`Stop` hook** (`hooks/continuum-check.sh`) runs after every turn. Calls the provider through a 10-minute cache (positive and negative — a failed call is also cached to avoid hammering a rate-limited endpoint every turn), compares utilization against tiers `CONTINUUM_TIERS` (80/90/95/99 by default) and — here's the whole trick — prints `{"decision":"block","reason":"..."}` to stdout. This is Claude Code's mechanism for preventing silent turn completion; the `reason` is fed back to the model as new input. `stop_hook_active` is checked first (otherwise infinite loop), and a per-session flag file means each tier fires exactly once.
    
3.  **`PreToolUse` hook** (`hooks/frugal-gate.sh`) — in frugal mode (`CONTINUUM_FRUGAL=1`) blocks `Agent` calls. Not a request — a hook-level ban.
    
4.  **Skill** (`skills/session-budget`) — what the injected `reason` asks Claude to run. Pure prompt engineering: honestly describe the situation, then `AskUserQuestion` with options. Never decides for you.
    
5.  **`continuum resume`** — schedules `claude --continue -p "$PROMPT"` for after the reset. Uses `launchd` (macOS), `systemd-run` (Linux), or `daemon(8)` (FreeBSD) by default. If none is available — `nohup sleep` (survives closing the terminal, not reboot). Log (`~/.claude/continuum-resume.log`) marks `### resumed in DIR` / `### end (exit N)` around each run. Desktop notification on completion.
    

Nothing touches the account, nothing spends a request without asking, nothing you can't read in a few hundred lines of POSIX `sh`.

## One-line install

Copy the line for your OS, paste into terminal, hit Enter.

**Mac or Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.sh | sh
```

**Windows** (PowerShell)

```powershell
irm https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.ps1 | iex
```

Then type `continuum status` to see how much battery is left.

> **Fair warning:** this command downloads a script from the internet and runs it. If you want to look first — good instinct — open [install.sh](install.sh) / [install.ps1](install.ps1), read it (it's short), and run it manually.

---

## What continuum does

Gives you what the limit screen never had: **a warning and a choice.**

When the usage window fills up, Claude doesn't silently end the turn and leave you guessing. It stops, says where you are, and asks:

```
Window is 86% full, resets at 21:40. What do we do?

  > Wrap up and land            get to a working state, run tests, show diff
    Finish the current task set  complete the planned batch, then stop — nothing new
    Save and continue            commit, then auto-resume after reset
    Frugal mode                  no subagents, no large files, short answers
    Cheap tasks only             docs and commit messages, defer heavy analysis
    Continue as-is               ignore the warning
```

Asks in whatever language you're working in. And doesn't nag: warnings are tiered — **80% → 90% → 95% → 99%**, each fires once. The weekly window is tracked separately — **70% → 85% → 95%**.

Choose *"save and continue"* — commits the work, schedules `claude --continue` for 21:41, gives you the PID. Close your laptop. At 21:41, without you, the session picks up where it left off. Desktop notification on completion.

### Frugal mode

Choose *"Frugal mode"* — sets `CONTINUUM_FRUGAL=1`, and the PreToolUse hook **forcefully blocks** subagent calls (`Agent`). Not a request — a hook-level ban.

## Two ways to install

**One-liner** gives you the `continuum` command in any terminal. Works with any AI agent.

**Claude Code plugin** adds *automatic* warnings — the part where Claude stops at the threshold and asks what to do:

```
/plugin marketplace add TropinAlexey/continuum
/plugin install continuum
```

Want both? Install both — one-liner for the command, plugin for automation. They don't conflict.

## Usage

```sh
continuum status      # 5 hours   86.5%   resets at 21:40
                      # 7 days    41.0%   resets at 02:00
continuum reset       # 21:41   (reset +90s, ready for scheduling)
continuum estimate    # At this pace, ~2h 15m left before 100%
continuum providers   # anthropic, mock, spend
continuum watch       # poll in a spare pane; bell at the threshold
continuum history     # last 20 usage snapshots
continuum cleanup     # remove stale flag/cache files (>24h old)

continuum resume "$(continuum reset)" "$PWD" "finish the DocumentService tests"
```

Not using Claude Code? `continuum watch` doesn't need hooks or the plugin — works in any terminal. `continuum resume` wakes any agent:

```sh
CONTINUUM_RESUME_CMD='codex exec "{prompt}"'    continuum resume 21:41 "$PWD" "finish the tests"
CONTINUUM_RESUME_CMD='opencode run "{prompt}"'  continuum resume 21:41 "$PWD" "finish the tests"
```

See **[docs/harnesses.md](docs/harnesses.md)** — what's tested, what's likely.

## Read before installing

**Uses an undocumented endpoint with an OAuth token.** `https://api.anthropic.com/api/oauth/usage` — what `/usage` calls. This is not a public API and may change without notice. The `anthropic` provider looks for a token in `$CLAUDE_CODE_OAUTH_TOKEN`, then macOS Keychain, then `~/.claude/.credentials.json`. The token goes in one `curl` header, to one host. A few hundred lines of shell — read it before trusting.

**`continuum resume` runs Claude unattended, with `--permission-mode acceptEdits`.** Sleeps until reset, then runs `claude --continue -p "<prompt>"` in the project. Edits code with no one watching. Keep the prompt narrow. Don't point it at anything you wouldn't let a stranger merge.

## Resume survives reboot

`continuum resume` automatically picks the best OS scheduler:

| OS | Scheduler | Survives reboot | Wakelock |
|---|---|---|---|
| macOS | `launchd` (one-shot plist) | yes | `caffeinate -i` |
| Linux | `systemd-run --user` (transient timer) | yes | `systemd-inhibit` |
| FreeBSD | `daemon(8)` | logout only | — |
| Windows | detached process | no | `SetThreadExecutionState` |
| Fallback | `nohup sleep` | no | `caffeinate` / `systemd-inhibit` |
**Wakelock** prevents system sleep automatically — during the wait until reset and during task execution. Releases on completion, on cancel (`kill PID`), or via `continuum cleanup`. No more manual `caffeinate`.

On completion — **desktop notification** (`osascript` on Mac, `notify-send` on Linux). Log (`~/.claude/continuum-resume.log`) marks `### resumed in DIR` / `### end (exit N)` — shared across projects, `grep` by directory to find yours.

## Providers

continuum doesn't know what Anthropic is. It asks a **provider** — "how much is used, when does it reset" — and everything else is provider-agnostic.

### Multiple providers at once

```sh
CONTINUUM_PROVIDER=anthropic,spend continuum status
```

Runs both, takes the highest utilization as the primary line. Catches the situation where "the 5-hour window is fine, but $40 has been burned today."

## All platforms

| | Shell | Status |
|---|---|---|
| macOS | `sh` | works out of the box |
| Linux | `sh` | works out of the box |
| FreeBSD / OpenBSD / NetBSD | `sh` | works out of the box |
| Windows + Git Bash | `sh` | works out of the box |
| Windows without Git Bash | PowerShell | `.ps1`, configure below |

Claude Code runs hooks through Git Bash on Windows, falls back to PowerShell if Git Bash isn't available. Two implementations, `.sh` and `.ps1`, are tested by the same test suite on all platforms in CI. No python, no node, no `jq` — POSIX `sh` + `curl`, or PowerShell 5.1+.

Without Git Bash — override hooks in `settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/hooks/continuum-check.ps1"",
      "shell": "powershell"
    }]}],
    "PreToolUse": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/hooks/frugal-gate.ps1"",
      "shell": "powershell"
    }]}]
  }
}
```

## Status line

Shows the current usage percentage in the Claude Code status bar, color-coded: **green** (<80%), **yellow** (80–94%), **red** (≥95%). Updates every ~30 seconds via background cache refresh.

Add to your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh "$HOME/.claude/hooks/statusline.sh""
  }
}
```

The plugin install copies the script automatically. If you installed via the one-liner, the script is already at `~/.claude/hooks/statusline.sh`.

## Configuration
| Variable | Default | What it does |
|---|---|---|
| `CONTINUUM_THRESHOLD` | `80` | Primary window threshold (%). Tiers below it are ignored. |
| `CONTINUUM_TIERS` | `80 90 95 99` | Primary window tiers. Each fires once. |
| `CONTINUUM_THRESHOLD_7D` | `70` | Weekly window threshold (%). |
| `CONTINUUM_TIERS_7D` | `70 85 95` | Weekly window tiers. |
| `CONTINUUM_PROVIDER` | `anthropic` | Which provider to query. Comma-separated for multiple. |
| `CONTINUUM_RESUME_CMD` | `claude --continue -p "{prompt}" …` | Which agent `resume` wakes. `{prompt}` is the task. |
| `CONTINUUM_DRY_RUN` | unset | `resume` prints the command instead of scheduling. |
| `CONTINUUM_OFF` | unset | Disable the Stop hook. |
| `CONTINUUM_FRUGAL` | unset | `1` — frugal mode: PreToolUse hook blocks Agent. |
| `CONTINUUM_CACHE_MIN` | `10` | Minutes to cache the provider response. `0` disables cache. |
| `CONTINUUM_SPEND_CAP` | `100` | Monthly budget in $ for the `spend` provider. |
| `ANTHROPIC_ADMIN_KEY` | — | Admin API key for the `spend` provider. |

## How it works

Claude Code calls the `Stop` hook every time Claude finishes a turn. A hook that prints `{"decision":"block","reason":"..."}` sends the `reason` back to Claude instead of letting the turn end. That's the whole trick. Our reason carries numbers and tells Claude to run the `session-budget` skill.

Everything else is edge-case defense around that idea:

-   **The endpoint is heavily rate-limited**, and the hook runs after *every* turn. Responses are cached for 10 minutes; a failure also sets a marker for 10 — negative cache.
-   **`stop_hook_active` is checked first.** Claude Code sets it on hook re-entry. Without this check — infinite loop.
-   **Per-session flag** — each tier fires once, not after every turn.
-   **Every error path exits 0 and stays silent.** A Stop hook that errors or chatters without cause is worse than no hook at all.

## Troubleshooting

**Nothing happens at 80%.** The hook only fires on `Stop`. Check: `sh tests/run.sh`. If it passes — the plugin isn't loaded, check `/plugin`.

**`usage endpoint unavailable`.** Offline, rate-limited (wait 10 minutes — negative cache handles it), or token expired. Re-login to Claude Code.

**`no OAuth token found`.** Not logged in, or credentials are in the wrong place. Export `CLAUDE_CODE_OAUTH_TOKEN`.

**`continuum resume` didn't work.** Check `~/.claude/continuum-resume.log` — look for `### resumed in DIR` / `### end (exit N)` markers. The log is shared across projects, `grep` by directory. On macOS — `launchctl list | grep continuum`. On Linux — `systemctl --user list-timers | grep continuum`. On FreeBSD — `ps aux | grep continuum`. Desktop notification also fires on completion; if neither `osascript` nor `notify-send` is available — log only.

**Warning appears, Claude ignores it.** The reason asks Claude to run the skill; the model may decide otherwise. Lower `CONTINUUM_THRESHOLD`.

## Contributing

```
sh tests/run.sh          # 55 tests, mock provider, no network
pwsh tests/run.ps1       # same suite for PowerShell
```

CI runs both on Linux, macOS, and Windows. What would actually help:

-   A provider for another budget: OpenAI spend, Gemini quota. See **[docs/writing-a-provider.md](docs/writing-a-provider.md)**.
-   Confirmation of whether the blocking `Stop` hook works in Codex CLI. [docs/harnesses.md](docs/harnesses.md) honestly says we don't know.

No dependencies. Every error path — silent.

## Uninstall

```
/plugin uninstall continuum
rm -f /usr/local/bin/continuum
rm -f ~/.claude/.continuum-cache-* ~/.claude/.continuum-warned-* ~/.claude/.continuum-warned7d-* ~/.claude/.continuum-wakelock-* ~/.claude/.continuum-history.log
```

Or: `continuum cleanup` removes only stale files (>24h).

## License

MIT