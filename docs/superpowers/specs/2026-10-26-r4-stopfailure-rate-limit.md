# R4. Limit hit mid-turn: `StopFailure` (rate_limit)

Status: done (v0.7.3)
Date: 2026-10-26
Roadmap: [2026-10-26-roadmap.md](2026-10-26-roadmap.md)

## Problem

When the limit is hit inside a turn, the agent stops with a 429 and the user may not be
watching. Claude Code and Junie both fire `StopFailure` with `error: "rate_limit"` and
`error_details`; it has no decision control, so nothing can be asked at that moment.

## Requirements

R4.1. A `StopFailure` hook (matcher `rate_limit`) in the Claude adapter, so Claude Code and
      Junie both get it: writes a line to the resume log and shows a desktop notification
      "continuum: limit hit in <project>, resets at <when> — run `continuum resume` with your task".
      <when> is the reset of the window that is exhausted (primary or weekly; weekly shown as
      day + time), not simply the first provider line.
R4.2. By default never schedules a resume (the user decides; the principle of the
      session-budget skill).
R4.6. Consent given in advance: with `CONTINUUM_RESUME_ON_LIMIT=1` the hook also schedules
      `continuum resume` for the reset time of the exhausted window, in the session's
      directory, with the agent's preset (bb thread / `claude --continue` / `junie --resume` …)
      and the task "The previous turn stopped on the usage limit. Continue the interrupted
      work from where it stopped." At most one scheduled resume per directory per window;
      the notification says it was scheduled and how to cancel it. Off unless the user sets
      it; documented in Configuration and "What it touches" (unattended runs).
R4.3. The next `SessionStart` (`resume-report.sh`) mentions the hit and the reset time, once.
R4.4. Silent and exit 0 on any failure; at most one notification per session per reset window.
R4.5. sh + ps1, tests in both suites; "What it touches" lists the notification.

## Out of scope

Codex / Gemini / Cursor / opencode equivalents (after R2).

## Design

`adapters/claude/stop-failure.sh|ps1`, wired in `hooks/hooks.json`. Reset time from the cached
provider line (no network call from a failing turn). Notification via the existing
`osascript` / `notify-send` helpers in core.

Implemented as an agent-neutral core command, like `check`: `continuum limit-hit
[session] [agent] [dir]` (sh + ps1); `adapters/claude/stop-failure.sh|ps1` only parse the
event (Junie: directory from `project_path`, its `cwd` is `~/.junie`). The note for R4.3 is
`$CNT_STATE/.continuum-limit-notes`, shown and removed by `resume-report.sh`.
Decision (R4.6): `continuum resume` takes HH:MM within the next 24 h, so a resume is
scheduled only when the exhausted window resets within a day; for a weekly reset days away
the notification says so and nothing is scheduled. `CONTINUUM_NOTIFY_CMD` swaps the notifier
(tests). Security autofix found on the way: notification text went into the AppleScript
source (`osascript -e "display notification \"$msg\""`), so a directory name with a quote
could run AppleScript; all three call sites now pass the text as argv.

## Acceptance

Tests: rate_limit event → log line + notification command (stubbed); other `error` values →
nothing; second event in the same window → nothing.

## Later

- Weekly reset days away: schedule by epoch instead of HH:MM (needs `continuum resume` to
  accept a date; separate spec).
