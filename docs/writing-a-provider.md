# Writing a provider

A provider answers one question: **how much of my budget is gone, and when does it come back?**

Everything else — caching, thresholds, the once-per-session flag, asking the user what to do,
scheduling the resume — is already handled. You only write the lookup.

## The contract

A provider is an executable script. It prints one line per usage window on stdout:

```
<window> <utilization> <reset_epoch>
```

| Field | Meaning | Example |
|---|---|---|
| `window` | short label, no spaces | `5h`, `7d`, `daily`, `month` |
| `utilization` | percent used, `0`–`100` | `86.5` |
| `reset_epoch` | unix seconds, or `-` if unknown | `1783000000` |

The **first line is the primary window** — the one the Stop hook watches against the threshold.
Extra lines are shown to the user and mentioned to Claude as context.

On failure: write a human-readable message to **stderr**, print **nothing** to stdout, and exit
non-zero. Never guess. Never print a fake zero — a provider that invents `0%` tells the user
they have budget they do not have.

That is the whole interface. Two numbers and a label.

## Write one

Copy `providers/mock.sh` (or `providers/mock.ps1`) and replace the two `printf` lines with a
real lookup. Name the file after your provider; `CONTINUUM_PROVIDER=<name>` selects it.

```sh
#!/bin/sh
set -eu
. "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}/lib/core.sh"

used=$(your_lookup_here)                 # e.g. 86.5
reset=$(cnt_iso_epoch "2026-07-10T19:40:00Z")

printf 'daily %s %s\n' "$used" "$reset"
```

Helpers available from `lib/core.sh` (and `lib/core.ps1`):

| Helper | Does |
|---|---|
| `cnt_json_str KEY` / `cnt_json_num KEY` / `cnt_json_block KEY` | pull a flat value out of JSON on stdin |
| `cnt_iso_epoch "<iso8601>"` | ISO timestamp → unix epoch, GNU and BSD `date` |
| `cnt_epoch_hhmm <epoch> [margin]` | epoch → local `HH:MM` |

## Test it

The suite runs against `mock`, so it never touches the network. Point it at yours:

```
CONTINUUM_PROVIDER=yours continuum status
CONTINUUM_PROVIDER=yours continuum reset
```

Then check the failure path actually fails — this is the one people get wrong:

```
CONTINUUM_PROVIDER=yours continuum status; echo "exit=$?"     # must be non-zero when the source is down
```

## Where providers live

`continuum providers` lists what it can see. It looks in two places:

1. `providers/` inside the plugin — ship it in a PR, everyone gets it.
2. `~/.claude/providers/` — your own, private, no PR needed.

## What is hard about this

Rate limits. The Stop hook runs after **every** turn, so a naive provider will get you
throttled within an hour. The core caches responses for 10 minutes and, after a failure,
refuses to retry for another 10 (a negative cache). Your provider does not need to implement
any of that — but it does need to be honest about failing, so the negative cache can do its job.

## Ports welcome

There is no provider for OpenAI or Gemini yet, because neither exposes a subscription window
the way Anthropic's does — you would be measuring something different (spend, tokens, RPM).
That is a legitimate provider. Define the window, document what the number means, send a PR.
