---
name: auto-resume
description: Schedule the session to resume automatically after the usage limit resets. Use when the user says the limit is about to run out, names a reset time, or asks to continue the work later automatically.
---

# Auto-resume after the limit resets

Schedules a detached headless run of your agent in the current project, so the session picks up
where it stopped once the window resets. The command comes from `CONTINUUM_RESUME_CMD`, or from
the preset for `CONTINUUM_AGENT` (default: Claude Code, `claude --continue -p "<prompt>"`).

## Steps

1. Find the reset time (`HH:MM`):
   - run `continuum reset`, or
   - take the time the user gave you, or the one in the limit message they pasted.

   `continuum` ships with continuum under `bin/`. If it is not on `PATH`, point the user at
   the README's install section rather than guessing paths.

2. Run, as a single line:
   `continuum resume "$(continuum reset)" "$PWD" "<specific task>"`

   Replace `<specific task>` with a concrete description of what to finish — "finish the
   DocumentService tests and run the suite" — not a generic "continue".

3. Tell the user: the scheduled time, the PID to cancel with, that output lands in
   `continuum-resume.log` in the continuum state dir (`~/.local/state/continuum` by default), and
   how to rejoin the session later in their agent (Claude Code: `claude --continue`).

## Important

- The resumed run is headless (with the Claude Code preset: `-p` with `acceptEdits`): it edits
  code with nobody watching.
  Warn the user for risky tasks and keep the prompt narrow.
- The prompt MUST be a complete, self-contained instruction — not "continue" or a question.
  The resumed session has no human to answer questions. continuum appends an autonomy
  directive automatically, but the task itself must be concrete: "finish X, run tests,
  commit" — not "should we do X?".
- On macOS/Linux the resume survives reboots (launchd/systemd). On FreeBSD, daemon(8) is
  used (survives logout, not reboot). On other systems the fallback is `nohup` which does
  NOT survive reboot — warn if the reset is hours away.
- System sleep is prevented automatically (caffeinate on macOS, systemd-inhibit on Linux).
  BSD and other systems have no wakelock — warn the user to disable sleep manually.
