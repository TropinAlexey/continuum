## Spec

`docs/superpowers/specs/YYYY-MM-DD-<topic>.md` (or: no spec, because <typo / docs-only / one-line fix>)

## Review

- [ ] `/code-review <base>` run: Standards and Spec axes clean, or findings moved to the spec's "Later"
- [ ] Autofixes applied after the review (within the spec; security problems always fixed), listed below
- [ ] Spec updated if a decision changed; status set
- [ ] `sh tests/run.sh` and `pwsh tests/run.ps1` green (counts: sh __ / ps __)
- [ ] `.sh` and `.ps1` changed together
- [ ] README.md and README.ru.md in sync
