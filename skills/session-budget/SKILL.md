---
name: session-budget
description: Agree a plan for the rest of the usage limit window with the user. Use when the [continuum] Stop hook reports the window crossed the threshold, or when the user asks "how much budget is left", "what do we do about the limit", "we're about to run out".
---

# Plan for the rest of the limit window

## 1. Get the facts

The hook that woke you already put the numbers in its message. Use those; do not spend a
tool call re-fetching. If the user asked cold, without a hook firing:

```
continuum status
```

Prints utilization and reset time for every window the provider reports. The exact reset
time for the scheduler is `continuum reset` (format `HH:MM`).

If `continuum` is not on `PATH`, it ships with this plugin under `bin/` — see the README's
install section. Do not go hunting for the path.

## 2. State where we stopped

One or two sentences: what is done, what remains, whether there are uncommitted changes.
A resumed session — or the user tomorrow — has none of your context. Write for them.

## 3. Ask the user via AskUserQuestion

Ask in the language the user has been speaking, not necessarily English — translate the
question and every option label accordingly.

Question: "The window is N% used, resets at HH:MM. What do we do?"
Offer 3-4 options that fit the moment, recommended one first:

| Option | What I do |
|---|---|
| **Finish and wrap up** | Bring the current task to a working state, run the tests, show the diff. No new work. |
| **Finish the task set, then stop** | Complete the remaining planned tasks (the current TODO batch), then stop — no new scope. Offer this only when what's left is a bounded, known set that plausibly fits the remaining window; skip it if the work is open-ended. |
| **Save state and schedule a resume** | Commit or stash, then `continuum resume "$(continuum reset)" "$PWD" "<specific task>"` so the session continues itself after the reset. |
| **Frugal mode** | Keep going, but: no subagents, no large files into context, short answers. Suggest `/compact`. |
| **Cheap tasks only** | Spend the rest on docs, commit messages, README; postpone heavy code analysis. |
| **Switch model** | Move to a cheaper model (`/model`) for routine work. |
| **Carry on as usual** | Ignore the warning; if the limit hits, the user runs `continuum resume` themselves. |

## 4. Execute the choice

For "save state and schedule a resume": save state first (commit only with the user's
explicit permission if the project requires it), then call `continuum resume` with a
**specific** task description, never a generic "continue" — the resumed session runs headless
and cannot ask follow-up questions.

## Settings

- Threshold floor: `CONTINUUM_THRESHOLD` (default 80).
- Tiers: `CONTINUUM_TIERS` (default `80 90 95 99`).
- Provider: `CONTINUUM_PROVIDER` (default `anthropic`).
- Disable the hook: `CONTINUUM_OFF=1`.
- Fires once per tier crossed, not once per session: after 80% it stays quiet until usage
  reaches 90%, then 95%, then 99% (flag `~/.claude/.continuum-warned-<session_id>` holds the
  highest tier already warned).
