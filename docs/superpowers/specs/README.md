# Specs

Development here is spec-first. Every feature or non-trivial fix starts as a spec in this
folder, and code review checks the change against it.

## Pipeline

1. **Spec.** Write `docs/superpowers/specs/YYYY-MM-DD-<topic>.md` from the template below
   (the `brainstorming` skill writes here too). Commit it on its own:
   `docs(spec): <topic>`. No code before the spec is agreed with the user.
2. **Code.** Implement against the numbered requirements. `.sh` and `.ps1` change together,
   tests in both suites. Every commit of the work carries a trailer:
   `Spec: docs/superpowers/specs/YYYY-MM-DD-<topic>.md`.
3. **Review.** Run `/code-review <base>` (base = the commit before the work, or `main` for a
   branch). It reviews two axes: **Standards** (`AGENTS.md`, `README.md` conventions) and
   **Spec** (this file: missing requirements, scope creep, wrong implementations).
4. **Autofix.** Right after the review, without asking, the agent applies the fixes it judges
   worth making, including findings below the review's reporting bar (hardening, small bugs,
   comment drift). Limits: every fix stays within the spec and keeps meeting it (no new
   behaviour, no scope change), `.sh` and `.ps1` together, tests in both suites green. A fix
   that would change what the spec says is not an autofix: ask, or put it under "Later".
   Security problems (secrets in code or logs, injection, unsafe paths or permissions, data
   sent or stored beyond what "What it touches" discloses) are always within the autofix
   bounds, at any severity, even when the fix narrows behaviour; update "What it touches"
   in the same commit if it changes.
   Report what was fixed, in one line each.
5. **Fix.** Fix every remaining finding on both axes, then run the review again until it is clean.
   A finding that is right but out of scope goes to the spec's "Later" list, not silently
   dropped. If the work changed a decision, update the spec in the same commit; the spec
   stays the description of what the code does.
6. **Ship.** Tests green in both suites, `claude plugin validate .`, push, green CI, then the
   release (tag, GitHub Release, both READMEs rewritten). Set the spec's status to `done`
   with the version.

Small things (typo, one-line fix, docs-only) skip the spec; say so in the commit message.

## Template

```markdown
# <Topic>

Status: draft | agreed | in progress | done (vX.Y.Z)
Date: YYYY-MM-DD

## Problem
What is wrong or missing, for whom. Link feedback files or issues.

## Requirements
R1. <one testable statement>
R2. ...

## Out of scope
What this deliberately does not do.

## Design
How: files touched, protocol details, sh/ps1 parity, what the user sees.

## Acceptance
- Tests (sh + ps1) that prove R1..Rn.
- Live checks, if any (and what "run live" means here).

## Later
Findings and ideas deferred from review.
```
