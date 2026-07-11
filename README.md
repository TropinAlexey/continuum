# continuum

**See the limit coming. Decide what to do with what's left. Pick up where you stopped.**

[![ci](https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml/badge.svg)](https://github.com/TropinAlexey/continuum/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## Explain it like I'm five

Your AI helper runs on a battery. When the battery runs out, it stops in the middle of what
it's doing — and forgets what you were both working on.

**continuum is a battery light.** It watches the battery, and when it's getting low it taps the
helper on the shoulder and says: *"Almost empty. Should we finish up, or take a nap and start
again when it's charged?"*

If you say *"take a nap,"* continuum remembers exactly where you were, waits for the battery to
fill back up, and quietly starts the helper again — right where you left off. You don't have to
watch. You don't have to remember anything.

That's the whole thing. A light, a question, and a nap that ends by itself.

## Install in one line

Copy the line for your computer, paste it into your terminal, press Enter.

**Mac or Linux**
```sh
curl -fsSL https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.sh | sh
```

**Windows** (PowerShell)
```powershell
irm https://raw.githubusercontent.com/TropinAlexey/continuum/main/install.ps1 | iex
```

Then type `continuum status` to see how much battery is left.

> **A fair warning, in plain words:** that command downloads a script from the internet and runs
> it. That is convenient but you are trusting it. If you'd rather look first — good instinct —
> open the [install.sh](install.sh) / [install.ps1](install.ps1) file, read it (it's short), and
> run it yourself. It only copies files into a folder and adds one command to your PATH.

---

It always happens at the worst moment.

You are four files into a refactor. The tests are almost green. You and Claude have built up an
hour of shared context — which functions are landmines, what the last migration broke, why that
one `if` has to stay. Then the turn ends and there it is:

> `5-hour limit reached · resets at 21:40`

The context is gone. The plan lived in the conversation and the conversation is over. Tomorrow
morning you will spend your first twenty minutes reconstructing what you already knew.

The limit was never the problem. **Walking into it blind was.**

## What continuum does

It gives you the one thing that limit screen never does: *warning, and a choice.*

When your usage window crosses a threshold — 80% by default — Claude doesn't quietly finish its
turn and leave you to find out the hard way. It stops, tells you exactly where the work stands,
and asks:

```
The window is 86% used, resets at 21:40. What do we do?

  > Finish and wrap up          bring it to a working state, run the tests, show the diff
    Save state and resume       commit, then schedule the session to continue itself at 21:40
    Frugal mode                 no subagents, no big files, short answers
    Cheap tasks only            docs and commit messages, postpone the heavy analysis
    Carry on                    ignore this, I know what I'm doing
```

Pick *"save state and resume"* and it commits your work, schedules `claude --continue` for
21:41 with a description of the task you were on, and hands you the PID. You close the laptop.

At 21:41, without you, the session picks the thread back up.

Three moving parts, and you can read all of them in an afternoon:

| | |
|---|---|
| **A hook** | Fires when Claude ends a turn. Once per session, at the threshold, it refuses to let the turn end silently. |
| **A skill** | Teaches Claude what to do with that moment: summarize honestly, then ask you — never decide for you. |
| **A scheduler** | Sleeps until the reset, then resumes the session where it stopped. |

No daemon. No telemetry. No account. Nothing runs that you did not start.

## Two ways to install, pick one

**The one-liner above** gives you the `continuum` command in any terminal. It works with any AI
agent, and it's all you need for `continuum status`, `continuum watch`, and `continuum resume`.

**The Claude Code plugin** additionally gives you the *automatic* tap-on-the-shoulder — the part
where Claude stops by itself at the threshold and asks you what to do. Run this inside Claude
Code:

```
/plugin marketplace add TropinAlexey/continuum
/plugin install continuum
```

Want both? Do both — the one-liner for the command, the plugin for the automatic warning. They
don't conflict.

## Use

```sh
continuum status      # 5 hours   86.5%   resets at 21:40
                      # 7 days    41.0%   resets at 02:00
continuum reset       # 21:41   (reset +90s, ready to schedule against)
continuum providers   # anthropic, mock
continuum watch       # poll in a spare pane; ring the bell at the threshold

continuum resume "$(continuum reset)" "$PWD" "finish the DocumentService tests"
```

Not using Claude Code? `continuum watch` needs no hooks and no plugin — it works in any
terminal, and `continuum resume` drives whatever agent you point it at:

```sh
CONTINUUM_RESUME_CMD='codex exec "{prompt}"'    continuum resume 21:41 "$PWD" "finish the tests"
CONTINUUM_RESUME_CMD='opencode run "{prompt}"'  continuum resume 21:41 "$PWD" "finish the tests"
```

See **[docs/harnesses.md](docs/harnesses.md)** for what is verified and what is merely likely —
we keep that line sharp.

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
| `CONTINUUM_RESUME_CMD` | `claude --continue -p "{prompt}" …` | Which agent `resume` wakes up. `{prompt}` is the task. |
| `CONTINUUM_DRY_RUN` | unset | `resume` prints the command instead of scheduling it. |
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
sh tests/run.sh          # 24 tests, mock provider, no network
pwsh tests/run.ps1       # the same suite against the PowerShell implementation
```

CI runs both on Linux, macOS, and Windows. Things that would genuinely help:

- A provider for another budget: OpenAI spend, Gemini quota, your team's shared cap.
  See **[docs/writing-a-provider.md](docs/writing-a-provider.md)** — it takes about ten minutes.
- Confirmation of whether Codex CLI honours a blocking `Stop` hook. We do not know yet, and
  [docs/harnesses.md](docs/harnesses.md) says so.
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
