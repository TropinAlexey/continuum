# continuum

*See the limit coming. Decide what to do with what's left. Pick up where you stopped.*

You are deep in a refactor. Claude goes quiet. `5-hour limit reached`. The context is gone,
the plan was never written down, and tomorrow you start by reconstructing what you were doing.

continuum makes that not happen. When your usage window crosses a threshold — 80% by default —
Claude does not just end its turn. It tells you where the work stopped and asks how you want to
spend what remains:

```
The window is 86% used, resets at 21:40. What do we do?

  > Finish and wrap up          bring it to a working state, run the tests, show the diff
    Save state and resume       commit, then schedule the session to continue itself at 21:40
    Frugal mode                 no subagents, no big files, short answers
    Cheap tasks only            docs and commit messages, postpone the heavy analysis
    Carry on                    ignore this, I know what I'm doing
```

Pick "save state and resume" and it commits, schedules `claude --continue` for 21:41, and
tells you the PID. You close the laptop.

## Install

```
/plugin marketplace add TropinAlexey/continuum
/plugin install continuum
```

The hook works immediately. To also get the CLI on your `PATH` — the skills use it, and it is
useful on its own:

```sh
ln -s "$(find ~/.claude/plugins -path '*continuum/bin/continuum' | head -1)" /usr/local/bin/continuum
```

## Use

```sh
continuum status      # 5 hours   86.5%   resets at 21:40
                      # 7 days    41.0%   resets at 02:00
continuum reset       # 21:41   (reset +90s, ready to schedule against)
continuum providers   # anthropic, mock

continuum resume "$(continuum reset)" "$PWD" "finish the DocumentService tests"
```

## Read this before installing

**It uses an undocumented endpoint with your OAuth token.**
`https://api.anthropic.com/api/oauth/usage` is what `/usage` calls. It is not a public API and
can change without notice. To read it, the `anthropic` provider looks for your token in
`$CLAUDE_CODE_OAUTH_TOKEN`, then the macOS Keychain, then `~/.claude/.credentials.json` — the
same places Claude Code keeps it. The token goes into one `curl` header, to one host, and
nowhere else. It is a few hundred lines of shell. Read them before you trust them.

**`continuum resume` runs Claude unattended, with `--permission-mode acceptEdits`.**
It sleeps until the reset, then runs `claude --continue -p "<your prompt>"` in your project.
It edits code with nobody watching. Keep the prompt narrow. Do not point it at anything you
would not let a stranger merge.

## Any model, any budget

continuum does not know what Anthropic is. It asks a **provider** for two numbers — how much is
used, when it resets — and everything else is provider-agnostic. A provider is a script that
prints:

```
5h 86.5 1783000000
7d 41.0 1783300000
```

That is the entire interface. `providers/anthropic.sh` is 60 lines. Writing one for your own
budget — a spend cap, a token quota, your team's shared limit — takes about ten minutes:
**[docs/writing-a-provider.md](docs/writing-a-provider.md)**. Drop it in `~/.claude/providers/`
and select it with `CONTINUUM_PROVIDER=yours`. No PR needed, though PRs are welcome.

There is no OpenAI or Gemini provider yet, and that is an honest gap rather than an oversight:
neither exposes a rolling subscription window like Anthropic's, so a provider for them would
measure something different — spend, or tokens, or requests per minute. Define the window,
document what the number means, send it in.

## Every operating system

| | Shell | Status |
|---|---|---|
| macOS | `sh` | works as shipped |
| Linux | `sh` | works as shipped |
| Windows + Git Bash | `sh` | works as shipped — this is Claude Code's default on Windows |
| Windows, no Git Bash | PowerShell | ships as `.ps1`, wire it up below |

Claude Code runs hooks under Git Bash on Windows, falling back to PowerShell when Git Bash is
absent. So there are two implementations, `.sh` and `.ps1`, tested by the same suite on all
three operating systems in CI. No python, no node, no `jq` — POSIX `sh` + `curl`, or PowerShell
5.1+.

Without Git Bash, override the hook in your `settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{
      "type": "command",
      "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/hooks/continuum-check.ps1\"",
      "shell": "powershell"
    }]}]
  }
}
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `CONTINUUM_THRESHOLD` | `80` | Percent of the primary window that triggers the warning. |
| `CONTINUUM_PROVIDER` | `anthropic` | Which provider to ask. |
| `CONTINUUM_OFF` | unset | Set to anything to disable the hook. |
| `CONTINUUM_CACHE_MIN` | `10` | Minutes to cache a provider response. |

## How it works

Claude Code fires the `Stop` hook every time Claude finishes a turn. A `Stop` hook that prints
`{"decision":"block","reason":"..."}` sends `reason` back to Claude instead of letting the turn
end. That is the whole trick. Our reason carries the numbers and tells Claude to run the
`session-budget` skill and ask you a question.

Everything else is damage control around that one idea:

- **The endpoint rate-limits hard**, and the hook runs after *every* turn. Responses are cached
  for 10 minutes, and a failure writes a marker that suppresses retries for another 10 — a
  negative cache. Without it you get throttled fast.
- **`stop_hook_active` is checked first.** Claude Code sets it when re-running the hook while
  already handling a block. Ignore it and you get an infinite loop.
- **A per-session flag** means you are warned once, not after every turn for the rest of the window.
- **Every failure path exits 0 and silent.** A `Stop` hook that errors, or chatters when it has
  nothing to say, is worse than no hook at all.

## Troubleshooting

**Nothing happens at 80%.** The hook only fires on `Stop`, when Claude finishes a turn. Test it
in isolation: `sh tests/run.sh`. If that passes, the plugin is probably not loaded — check `/plugin`.

**`usage endpoint unavailable`.** You are offline, rate-limited (wait 10 minutes — the negative
cache is doing its job), or your token expired. Re-login to Claude Code.

**`no OAuth token found`.** Not logged in, or your credentials live somewhere the lookup does not
check. Export `CLAUDE_CODE_OAUTH_TOKEN` to skip the search entirely.

**The skills cannot find `continuum`.** They call it as a bare command. `${CLAUDE_PLUGIN_ROOT}`
is documented for hooks and slash commands but not for skills, so the plugin does not rely on it
there. Do the `PATH` symlink from the install section.

**`continuum resume` never fired.** It is a detached `sleep`, so a reboot ends it. Check
`~/.claude/continuum-resume.log`. If the reset is hours away, use a real scheduler
(`launchd`, `systemd`, Task Scheduler).

**The warning fires but Claude ignores it.** The reason string asks Claude to run a skill; a model
can still decide otherwise. Lower `CONTINUUM_THRESHOLD` to get the nudge earlier.

## Contributing

```
sh tests/run.sh          # 18 tests, mock provider, no network
pwsh tests/run.ps1       # the same suite against the PowerShell implementation
```

CI runs both on Linux, macOS, and Windows. Things that would genuinely help:

- A provider for another budget: OpenAI spend, Gemini quota, your team's shared cap.
- A `launchd`/`systemd`/Task Scheduler backend for `continuum resume`, so scheduled resumes
  survive reboots.
- Acting on the weekly window, not just reporting it.

Keep it dependency-free. Keep every failure path silent.

## Uninstall

```
/plugin uninstall continuum
rm -f /usr/local/bin/continuum
rm -f ~/.claude/.continuum-cache-* ~/.claude/.continuum-warned-*
```

## License

MIT
