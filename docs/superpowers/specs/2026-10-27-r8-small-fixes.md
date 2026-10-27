# R8. Small things: honesty fixes, cleanup, deprecations

Status: draft
Date: 2026-10-27
Roadmap: [2026-10-26-roadmap.md](2026-10-26-roadmap.md)

## Problem

Items deferred from reviews of R1–R6 and from the v0.8.x releases. Each is small; together
they are the difference between "mostly true" and "true" in what continuum reports.

## Requirements

R8.1. **`resume` at a date, not only HH:MM.** `continuum resume` takes HH:MM within the next
      24 h, so a weekly window that resets in days cannot be scheduled: R4.6
      (`CONTINUUM_RESUME_ON_LIMIT=1`) skips it, and a user has to wait and run it by hand. Accept
      `YYYY-MM-DD HH:MM` and an epoch (`@1793491200`) as well; `continuum reset --weekly` prints the
      weekly reset in that form. Schedulers: launchd `StartCalendarInterval` with Day and Month,
      `systemd-run --on-calendar`, a long sleep elsewhere (Windows detached, nohup) with the reboot
      caveat printed. R4.6 then schedules weekly resets too.
R8.2. **`spend` never prints a fake zero.** `providers/spend.sh` (and `.ps1`) turns a missing or
      malformed `total_cost` into `0` and reports `month 0.0`: the provider contract says fail
      instead ("never print a fake zero"). Fail with a message when the field is absent.
R8.3. **"Sleep inhibited" only when it is.** On macOS `continuum resume` prints
      `Sleep inhibited (caffeinate).` unconditionally, even when the pre-emptive `caffeinate`
      could not start (v0.8.1 made `cnt_wakelock_start` honest; the message still is not). Print it
      only when a wakelock is held; otherwise say the run itself is wrapped in `caffeinate -i`.
R8.4. **Remove the `hooks/*.sh|ps1` forwarders** (`continuum-check`, `frugal-gate`,
      `resume-report`, `setup-statusline`, `statusline`; `hooks/hooks.json` stays: it is the plugin
      manifest). They exist so pre-v0.6 `settings.json` entries keep working. Before removing:
      `continuum doctor` already warns about `hooks/continuum-check.*`; extend it to every
      forwarder path, ship one release with that warning, then remove them in the next minor
      (v0.9) with a release note and the exact replacement paths.
R8.5. **`.DS_Store` never in git.** The plugin directory's requirements forbid it; `.gitignore`
      covers it, nothing checks it. A test (repo hygiene, like the executable-bit one) fails if
      any `.DS_Store` is tracked. The old idea "`continuum cleanup` removes `.DS_Store`" is dropped:
      the state dir is continuum's own and Finder litter there is harmless.
R8.6. **Analyzer warnings on purpose, said on purpose.** PSScriptAnalyzer reports ~60
      style warnings that are intentional (Write-Host in the CLI and tests, empty catch in hooks
      that must never throw, ShouldProcess on internal functions). Add a
      `PSScriptAnalyzerSettings.psd1` that excludes exactly those rules with a one-line reason each,
      so the warning list shows only new, real findings and CI could gate on warnings later.
R8.7. **Uninstall after the user edited the config.** `continuum uninstall --agent <x>` refuses
      when the file changed since install (R5). For the "inserted" mode, remove the exact block
      install added when it is still present verbatim, and keep the user's other edits; refuse only
      when the block itself was changed.

## Out of scope

New features. Anything that changes what a warning says or when it fires.

## Design

Each requirement is independent and can ship alone; order: R8.2, R8.3 (honesty, tiny), R8.5,
R8.6 (CI hygiene), R8.1 (largest), R8.7, R8.4 (two releases). sh and ps1 together, tests in both
suites for every behaviour change.

## Acceptance

- R8.1: dry-run tests for every scheduler form, a weekly limit-hit test that schedules.
- R8.2: test with a response lacking `total_cost` → non-zero exit, no output line.
- R8.3: test with `caffeinate` stubbed to fail → no "Sleep inhibited" line.
- R8.4: doctor warns on each forwarder path (release N); forwarders gone, doctor still points
  to the replacements (release N+1).
- R8.5, R8.6: CI steps/tests green; the analyzer prints no warnings on the current code.
- R8.7: tests: unchanged file → restored; other keys edited → block removed, edits kept; block
  edited → refused.

## Later

—
