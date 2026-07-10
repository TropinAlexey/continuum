# token-budget

A Claude Code plugin that stops you from walking into the usage limit blind.

When your 5-hour window crosses a threshold (80% by default), Claude does not just end its
turn. It tells you where the work stopped and asks how you want to spend what is left:
wrap up, switch to a cheaper model, go frugal, or save state and schedule the session to
resume itself once the window resets.

Three pieces:

| Piece | What it is |
|---|---|
| `hooks/token-budget-check.sh` | `Stop` hook. Once per session, when the window crosses the threshold, it blocks the silent end-of-turn and hands Claude the numbers. |
| `skills/session-budget` | Skill Claude runs on that signal: state where we stopped, then ask you what to do. |
| `skills/auto-resume` + `bin/claude-auto-resume` | Schedules a detached `claude --continue` for after the reset. |
| `bin/claude-usage` | Prints real 5-hour and weekly utilisation. Works standalone. |

## Read this before installing

**1. It uses an undocumented endpoint with your OAuth token.**
`https://api.anthropic.com/api/oauth/usage` is what `/usage` calls. It is not a public API.
It can change or disappear without notice. To read it, `lib/usage.sh` looks for your token in
`$CLAUDE_CODE_OAUTH_TOKEN`, then the macOS Keychain (`Claude Code-credentials`), then
`~/.claude/.credentials.json` — the same places Claude Code itself keeps it. The token is
only ever passed to `curl` as an `Authorization` header, and only to `api.anthropic.com`.
Nothing is sent anywhere else. It is ~100 lines of POSIX shell; read them before you trust them.

Never call `cug_token` by hand — it prints the token on stdout.

**2. `claude-auto-resume` runs Claude unattended, with `--permission-mode acceptEdits`.**
It sleeps until the reset time, then runs `claude --continue -p "<your prompt>"` in your
project directory. That means it edits code with nobody watching. Keep the prompt narrow,
do not point it at anything you would not let a junior merge unsupervised, and remember it
cannot answer follow-up questions — a vague "continue" gets you vague work.

## Install

```
/plugin marketplace add TropinAlexey/claude-token-budget
/plugin install token-budget
```

The hook works immediately. To also get the CLIs on your `PATH` (the skills use them, and
they are useful on their own), symlink them once:

```
ln -s "$(find ~/.claude/plugins -path '*token-budget/bin/claude-usage' | head -1)" /usr/local/bin/claude-usage
ln -s "$(find ~/.claude/plugins -path '*token-budget/bin/claude-auto-resume' | head -1)" /usr/local/bin/claude-auto-resume
```

## Use

```
claude-usage                 # 5 hours   86.5%   resets at 21:40
                             # 7 days    41.0%   resets at 02:00
claude-usage --json          # raw response
claude-usage --reset         # 21:41  (reset time +90s, ready to schedule against)

claude-auto-resume "$(claude-usage --reset)" "$PWD" "finish the DocumentService tests"
```

The scheduled job is a `nohup`'d `sleep`. It survives closing the terminal; it does **not**
survive a reboot. Cancel it with the PID the command prints. Output goes to
`~/.claude/auto-resume.log`.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_USAGE_THRESHOLD` | `80` | Percent of the 5-hour window that triggers the warning. |
| `CLAUDE_USAGE_HOOK_OFF` | unset | Set to anything to disable the hook. |
| `CLAUDE_USAGE_CACHE_MIN` | `10` | Minutes to cache the usage response. The endpoint rate-limits hard. |

The hook fires once per session (flag: `~/.claude/.budget-warned-<session_id>`), caches
responses, and backs off after a failure. If it cannot reach the endpoint — offline, rate
limited, expired token — it exits silently. It never blocks your turn to tell you it failed.

## Platform support

POSIX `sh` and `curl` only. No python, no node, no `jq`. Date arithmetic handles both GNU
(`date -d`) and BSD (`date -r`) so macOS and Linux both work; the Keychain lookup is guarded
by `command -v security` and simply falls through to `.credentials.json` on Linux.

- **macOS** — works as shipped.
- **Linux** — works as shipped.
- **Windows** — needs WSL or Git Bash. Native `cmd`/PowerShell has no `sh` and no `nohup`.
  A PowerShell port would be welcome.

## How it works

Claude Code fires the `Stop` hook every time Claude finishes a turn. A `Stop` hook that
prints `{"decision":"block","reason":"..."}` sends `reason` back to Claude instead of letting
the turn end — that is the whole trick. The reason we send carries the utilisation numbers and
tells Claude to run the `session-budget` skill and ask you a question.

Everything else is damage control around that one idea:

- **The endpoint rate-limits hard**, and the hook runs after *every* turn. So responses are
  cached for 10 minutes, and a failure writes a `.usage-cache.fail` marker that suppresses
  retries for the same 10 minutes (a negative cache). Without this you get throttled fast.
- **`stop_hook_active`** is checked first. Claude Code sets it when it re-runs the hook while
  already handling a block. Ignoring it gives you an infinite loop.
- **A per-session flag file** means you get warned once, not after every turn for the rest of
  the window.
- **Every failure path exits 0 and silent.** A `Stop` hook that exits non-zero, or that talks
  when it has nothing to say, is worse than no hook.

## Troubleshooting

**Nothing happens at 80%.** The hook only fires on `Stop`, i.e. when Claude finishes a turn.
Check it in isolation with the `CUG_FIXTURE` recipe below. If that prints a `block` decision,
the hook is fine and the plugin is probably not loaded — check `/plugin`.

**`usage endpoint unavailable`.** One of: you are offline, the endpoint rate-limited you (wait
10 minutes — the negative cache is doing its job), or your token expired. Re-login to Claude
Code and try again.

**`no OAuth token found`.** You are not logged in, or your credentials live somewhere the
lookup does not check. Export `CLAUDE_CODE_OAUTH_TOKEN` to override the search entirely.

**The skills cannot find `claude-usage`.** They call it as a bare command. `${CLAUDE_PLUGIN_ROOT}`
is documented for hooks and slash commands, but not for skills, so the plugin does not rely on
it there — do the `PATH` symlink from the install section.

**`claude-auto-resume` never fired.** It is a `nohup`'d `sleep`, so a reboot or a killed
process tree ends it. Check `~/.claude/auto-resume.log`. If the reset is hours away, consider
a real scheduler (`launchd`, `systemd`, `cron`) instead.

**The warning fires but Claude ignores it.** The reason string asks Claude to run a skill; a
model can still decide otherwise. Lower `CLAUDE_USAGE_THRESHOLD` so you get the nudge earlier.

## Uninstall

```
/plugin uninstall token-budget
rm -f /usr/local/bin/claude-usage /usr/local/bin/claude-auto-resume
rm -f ~/.claude/.usage-cache.json ~/.claude/.usage-cache.fail ~/.claude/.budget-warned-*
```

## Contributing

Issues and PRs welcome. Things that would genuinely help:

- A PowerShell port so this works on native Windows.
- A `launchd`/`systemd` backend for `claude-auto-resume`, so scheduled resumes survive reboots.
- Better handling of the weekly window — right now it is reported but never acted on.

Keep it POSIX `sh`, keep it dependency-free, and keep every failure path silent.

## Testing without burning your rate limit

Set `CUG_FIXTURE` to a file of canned JSON and `cug_fetch` reads it instead of the network:

```
echo '{"five_hour":{"utilization":86.5,"resets_at":"2026-07-10T19:40:00.180+00:00"},
       "seven_day":{"utilization":41.0,"resets_at":"2026-07-14T00:00:00.000+00:00"}}' > /tmp/u.json

CUG_FIXTURE=/tmp/u.json bin/claude-usage
echo '{"session_id":"test"}' | CUG_FIXTURE=/tmp/u.json CLAUDE_PLUGIN_ROOT=. sh hooks/token-budget-check.sh
```

## License

MIT
