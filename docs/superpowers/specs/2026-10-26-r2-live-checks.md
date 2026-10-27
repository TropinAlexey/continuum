# R2. Live checks of every adapter

Status: draft
Date: 2026-10-26
Roadmap: [2026-10-26-roadmap.md](2026-10-26-roadmap.md)

## Problem

Only Claude Code and Junie CLI (batch) have been run live. bb, Junie TUI, Codex, Gemini,
Cursor and opencode are "tested in CI" only: replies match the documented protocol, but no
real session has received a warning.

## Requirements

R2.1. For each of: bb (Claude thread), Junie interactive TUI, Codex CLI, Gemini CLI, Cursor,
      opencode — one real session with `CONTINUUM_THRESHOLD=10 CONTINUUM_TIERS=10
      CONTINUUM_PROVIDER=mock`: the end-of-turn warning arrives and the agent asks the user.
R2.2. Mid-turn warning arrives where the adapter has one.
R2.3. `continuum resume` with `CONTINUUM_DRY_RUN=1` prints the agent's preset; one real
      scheduled resume per agent that is installed here (short delay).
R2.4. Agents table and each adapter README say "run live" with agent version and date, or
      the failure is fixed under this spec (autofix bounds) or gets its own spec.
R2.5. For each agent: does it have a question tool? If yes, a line in `cnt_ask_hint`.

## Out of scope

Agents not installed on this machine and not installable for free: mark "not run (needs X)".
Agents inside a JetBrains IDE's AI chat (owned by R1; same `docs/live-checks.md` file).

## Design

A checklist file `docs/live-checks.md` (agent, version, date, R2.1–R2.3 result, notes).
Leave state in a scratch `CONTINUUM_STATE_DIR` so real flags are untouched. Real resumes
(R2.3) run unattended: mock provider, a scratch git repo, a harmless task ("write the date
to note.txt"), never this repo.

## Acceptance

`docs/live-checks.md` filled; README tables updated; any fix has tests in both suites.

## Later

—
