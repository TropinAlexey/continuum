# R5. `continuum install --agent <x>`

Status: done (v0.8.0)
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

Implemented: `continuum install|uninstall --agent <x> [--dry-run]` (sh + ps1). Modes: no file
→ created; file without `"hooks"` → block inserted after the first `{` (backup first); file
with `"hooks"` or not starting with `{` → refused with the snippet. Uninstall restores the
backup (or removes a created file) only while the file's checksum matches the one recorded
at install; otherwise it prints the manual step (R5.2 holds for unchanged files). The code
path must be plain (`[A-Za-z0-9/._+@~-]`), since it lands in a shell command. ps1 on Windows
writes `pwsh -NoProfile -File …ps1` commands. R5.6: marketplace install of v0.7.4 from a
clean HOME with the `claude plugin` CLI works, `continuum doctor` all ok there (2026-10-27);
Junie `/extensions` is interactive, not run.

## Acceptance

Tests per agent: empty config, config with other hooks, already installed, uninstall.

## Later

—
