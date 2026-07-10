---
name: auto-resume
description: Schedule the session to resume automatically after the usage limit resets. Use when the user says the limit is about to run out, names a reset time, or asks to continue the work later automatically.
---

# Auto-resume after the limit resets

Schedules a detached `claude --continue -p "<prompt>"` in the current project, so the session
picks up where it stopped once the window resets.

## Steps

1. Find the reset time (`HH:MM`):
   - run `continuum reset`, or
   - take the time the user gave you, or the one in the limit message they pasted.

   `continuum` ships with this plugin under `bin/`. If it is not on `PATH`, point the user at
   the README's install section rather than guessing paths.

2. Run, as a single line:
   `continuum resume "$(continuum reset)" "$PWD" "<specific task>"`

   Replace `<specific task>` with a concrete description of what to finish — "finish the
   DocumentService tests and run the suite" — not a generic "continue".

3. Tell the user: the scheduled time, the PID to cancel with, that output lands in
   `~/.claude/continuum-resume.log`, and that they can rejoin later with `claude --continue`.

## Important

- The resumed run is headless (`-p`) with `acceptEdits`: it edits code with nobody watching.
  Warn the user for risky tasks and keep the prompt narrow.
- This only works while tokens remain. Once the limit is hit, the user runs the command
  themselves from a normal terminal: `continuum resume 19:40`.
- A reboot kills the scheduled process (`nohup` on Unix, a hidden process on Windows — not
  `launchd`/`systemd`/Task Scheduler). Warn if the reset is hours away.
