# Issue tracker

This repo tracks work as **spec files**, not tracker issues: `docs/superpowers/specs/YYYY-MM-DD-<topic>.md`
(process and template: [specs/README.md](../superpowers/specs/README.md)).

To find the spec for a change:

1. A `Spec: <path>` trailer in the commit messages of the range — read that file.
2. Otherwise the newest spec whose topic matches the branch name or the commit subjects.
3. GitHub issues (`#123` in commits) exist for user reports; fetch with
   `gh issue view 123 --repo TropinAlexey/continuum`. They are input to a spec, not a spec.

If no spec is found for a feature or non-trivial fix, report that as a Spec-axis finding:
the pipeline requires one.
