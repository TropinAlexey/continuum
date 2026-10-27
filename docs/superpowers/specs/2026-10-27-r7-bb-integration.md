# R7. Deeper bb integration (get-bb/bb)

Status: draft
Date: 2026-10-27
Roadmap: [2026-10-26-roadmap.md](2026-10-26-roadmap.md)

## Problem

bb (https://github.com/get-bb/bb, desktop 0.47.1, "the agent IDE that builds itself") runs
Claude Code, Codex, pi and ACP agents in threads. Since v0.7.1 continuum works inside it
indirectly: Claude threads load the continuum plugin (Agent SDK with user settings), and
`continuum resume` with `BB_THREAD_ID` sends the task back with `bb thread tell`. Gaps:
- Codex / pi / ACP threads get no warning unless their own CLI hooks are set up.
- bb already knows usage: its provider plugins expose `provider-usage.v1.listResources` /
  `getResource` (claude-code, codex, acp) with per-account usage and `observedAt`. continuum
  asks Anthropic's undocumented endpoint instead, and has no Codex window at all.
- bb's built-in `provider-retry` queues an automatic retry after subscription-window limits.
  With `CONTINUUM_RESUME_ON_LIMIT=1` a bb thread could get two resumes for one limit hit.
- Not run live in bb yet (R2).

## Requirements

R7.1. **`bb` provider** (`providers/bb.sh|ps1`): read usage through bb's plugin RPC
      (`provider-usage.v1`) for the thread's provider (`claude-code` / `codex` / `acp`) and print
      the standard lines. Local only (bb server on 127.0.0.1, its token from `bb plugin token` or
      the documented RPC auth), no provider credentials touched by continuum. Gives a Codex
      window for the first time. Selected automatically inside a bb thread only if the user
      opts in (`CONTINUUM_PROVIDER=bb`); "What it touches" lists the bb endpoint.
R7.2. **No double resume.** Inside a bb thread (`BB_THREAD_ID` set), `continuum limit-hit` does
      not schedule its own resume when bb's `provider-retry` is enabled for that thread; the
      note says so and names `bb provider-retry status`. Without provider-retry, R4.6 applies as is.
R7.3. **Warnings in non-Claude bb threads.** Find out whether bb exposes a turn-end or
      message hook to plugins; if yes, a small bb plugin (`adapters/bb/plugin/`, built with
      `bb plugin new`/`build`) runs `continuum check` and posts the warning into the thread. If no
      such hook exists, document `continuum watch` per host instead and drop R7.3 with the reason.
R7.4. **Live check** (moves R2's bb row): a Claude thread gets the warning; `continuum resume`
      lands in the same thread; with R7.1 the Codex window shows in `continuum status`.

## Out of scope

A bb UI panel or badge (a later spec if R7.3 shows a plugin is worth it). Changing bb itself.

## Design

R7.1 first: `bb plugin rpc inspect` gives the input/output JSON Schemas; call the RPC over the
bb server URL from `~/.bb/bb-app-runtime.json` with `curl` (secret via `cnt_curl_secret`).
Map `usage` windows to `<window> <util> <reset_epoch>`; `observedAt` older than the cache TTL
counts as stale. R7.2 needs only `bb provider-retry status` (read-only). R7.3 starts with the
`bb-plugin-authoring` skill (manifest, server API, events).

## Acceptance

- R7.1: tests with recorded RPC responses (both suites); live `CONTINUUM_PROVIDER=bb continuum
  status` in a bb thread shows the same numbers as bb's UI.
- R7.2: test with a stubbed `bb` CLI (provider-retry on/off).
- R7.3: decision recorded here; plugin tests if built.
- R7.4: `docs/live-checks.md` row filled.

## Later

—
