---
name: session-budget
description: Agree a plan for the rest of the token limit window with the user. Use when the [usage] Stop hook reports the 5-hour window crossed the threshold, or when the user asks "how much budget is left", "what do we do about the limit", "we're about to run out".
---

# Plan for the rest of the limit window

## 1. Get the facts

```
claude-usage
```

Prints utilization of the 5-hour and weekly windows plus reset times.
Exact reset time for the scheduler: `claude-usage --reset` (format `HH:MM`).

If `claude-usage` is not on `PATH`, it ships with this plugin under `bin/` — see the README's
install section. When the hook triggered you, its message already carries the numbers, so do
not block on this step: report what the hook told you and move on.

## 2. State where we stopped

One or two sentences: what is done, what remains, whether there are uncommitted changes.
A resumed session (or the user tomorrow) needs this context.

## 3. Ask the user via AskUserQuestion

Question: "The 5-hour window is N% used, resets at HH:MM. What do we do?"
Offer 3-4 options that fit the moment, recommended one first:

| Option | What I do |
|---|---|
| **Finish and wrap up** | Bring the current task to a working state, run the tests, show the diff. No new work. |
| **Save state and schedule a resume** | Commit or stash, then `claude-auto-resume "$(claude-usage --reset)" "$PWD" "<specific task>"` so the session continues itself after the reset. |
| **Frugal mode** | Keep going, but: no subagents, no large files into context, short answers. Suggest `/compact`. |
| **Cheap tasks only** | Spend the rest on docs, commit messages, README; postpone heavy code analysis. |
| **Switch model** | Move to a cheaper model (`/model`) for routine work. |
| **Carry on as usual** | Ignore the warning; if the limit hits, the user runs `claude-auto-resume` themselves. |

## 4. Execute the choice

For "save state and schedule a resume": save state first (commit only with the user's
explicit permission if the project requires it), then call `claude-auto-resume` with a
**specific** task description, never a generic "continue" - the headless session cannot ask
follow-up questions.

## Settings

- Threshold: `CLAUDE_USAGE_THRESHOLD` (default 80).
- Disable the hook: `CLAUDE_USAGE_HOOK_OFF=1`.
- The warning fires once per session (flag `~/.claude/.budget-warned-<session_id>`).
