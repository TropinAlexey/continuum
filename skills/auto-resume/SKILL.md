---
name: auto-resume
description: Schedule the session to resume automatically after the token limit resets. Use when the user says the limit is about to run out, names a reset time, or asks to continue the work later automatically.
---

# Auto-resume after the limit resets

Schedules a detached `claude --continue -p "<prompt>"` in the current project, so the session
picks up where it stopped once the limit window resets.

## Steps

1. Find the reset time (`HH:MM`):
   - run `claude-usage --reset`, or
   - take the time the user gave you / the one in the limit message they pasted.

   `claude-usage` and `claude-auto-resume` ship with this plugin under `bin/`. If they are not
   on `PATH`, tell the user to do the symlink step from the README rather than guessing paths.
2. Run, as a single line:
   `claude-auto-resume "$(claude-usage --reset)" "$PWD" "<specific task>"`
   Replace `<specific task>` with a concrete description of what to finish
   ("finish the DocumentService tests and run the suite"), not a generic "continue".
3. Tell the user: the scheduled time, the PID to cancel with, that output lands in
   `~/.claude/auto-resume.log`, and that they can rejoin later with `claude --continue`.

## Important

- The resumed run is headless (`-p`) with `acceptEdits`: it edits code with nobody watching.
  Warn the user for risky tasks and keep the prompt narrow.
- This skill only works while tokens remain. Once the limit is hit, the user runs the script
  themselves from a normal terminal: `claude-auto-resume 19:40`.
- A reboot kills the scheduled process (`nohup`, not `launchd`/`systemd`) - warn if the reset
  is hours away.
