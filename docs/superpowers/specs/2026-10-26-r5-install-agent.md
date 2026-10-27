# R5. `continuum install --agent <x>`

Status: draft
Date: 2026-10-26
Roadmap: [2026-10-26-roadmap.md](2026-10-26-roadmap.md)

## Problem

Each adapter README says "add these hooks to your config"; users copy JSON by hand. The
marketplace install from zero has not been re-tested since v0.6.

## Requirements

R5.1. `continuum install --agent codex|gemini|cursor` writes the adapter's hooks into that
      agent's hooks file (`~/.codex/hooks.json`, `~/.gemini/settings.json`,
      `~/.cursor/hooks.json`), merging with existing hooks, with a backup
      `<file>.continuum-bak` first; `opencode` gets the plugin symlink in
      `~/.config/opencode/plugins/`. `--dry-run` prints the change only.
R5.2. Idempotent: running twice changes nothing; `continuum uninstall --agent <x>` removes
      exactly what install added.
R5.3. `claude` and `junie` print the marketplace steps instead (they install as plugins).
R5.4. sh + ps1; tests on fake config files for every agent, both suites.
R5.5. "What it touches" lists every config file install/uninstall may change.
R5.6. A clean-HOME test of the marketplace install for Claude Code (`claude plugin` CLI) and
      Junie (`/extensions`), recorded in `docs/live-checks.md`.

## Out of scope

Configs we cannot merge safely without a JSON parser (unexpected shape): print the manual
steps and change nothing.

## Design

Merge by marker: each inserted hook command contains `continuum`; uninstall removes entries
whose command points into the continuum root. JSON edits with awk on known shapes; anything
unexpected → refuse with the manual steps (never half-write a config).

## Acceptance

Tests per agent: empty config, config with other hooks, already installed, uninstall.

## Later

—
