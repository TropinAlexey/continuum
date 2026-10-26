# R4. Limit hit mid-turn: `StopFailure` (rate_limit)

Status: draft
Date: 2026-10-26
Roadmap: [2026-10-26-roadmap.md](2026-10-26-roadmap.md)

## Problem

When the limit is hit inside a turn, the agent stops with a 429 and the user may not be
watching. Claude Code and Junie both fire `StopFailure` with `error: "rate_limit"` and
`error_details`; it has no decision control, so nothing can be asked at that moment.

## Requirements

R4.1. A `StopFailure` hook (matcher `rate_limit`) in the Claude adapter, so Claude Code and
      Junie both get it: writes a line to the resume log and shows a desktop notification
      "continuum: limit hit in <project>, resets at HH:MM — `continuum resume HH:MM "<dir>" "<task>"`".
R4.2. Never schedules a resume by itself (the user decides; the principle of the
      session-budget skill).
R4.3. The next `SessionStart` (`resume-report.sh`) mentions the hit and the reset time, once.
R4.4. Silent and exit 0 on any failure; at most one notification per session per reset window.
R4.5. sh + ps1, tests in both suites; "What it touches" lists the notification.

## Out of scope

Codex / Gemini / Cursor / opencode equivalents (after R2).

## Design

`adapters/claude/stop-failure.sh|ps1`, wired in `hooks/hooks.json`. Reset time from the cached
provider line (no network call from a failing turn). Notification via the existing
`osascript` / `notify-send` helpers in core.

## Acceptance

Tests: rate_limit event → log line + notification command (stubbed); other `error` values →
nothing; second event in the same window → nothing.

## Later

—
