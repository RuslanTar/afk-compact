## What this changes

<!-- One or two sentences: what changes for a user or a maintainer, and why. Link the issue it fixes (Fixes #123). -->

## How it was checked

<!-- Tick what you ran. Say what you could not run and why. -->

- [ ] `tools/build --check` (and `tools/build` first, if you changed `src/`)
- [ ] `tools/fixtures-gen --check`, `tools/helper-replies-gen --check`, `tools/assemble --check`
- [ ] `claude plugin validate plugin --strict` and `claude plugin test plugin`
- [ ] `perl tests/helper/run.pl` on the cases this touches, and the new or changed case if there is one
- [ ] `tools/typecheck` (or: needs the Claude Code type declarations, I could not run it)
- [ ] `tools/gates plugin README.md docs --names <file> --no-git-log`

## Checklist

- [ ] One focused change; generated files were rebuilt, not edited by hand
- [ ] A test case for new or changed behaviour
- [ ] Text updated in `src/landing.md` or `src/docs/` (never in `README.md` or `docs/`) when what a user sees changes
- [ ] A line under `Unreleased` in `CHANGELOG.md` for a change a user could notice
- [ ] No network call, no telemetry, no conversation text or secret in a log row
- [ ] I read CONTRIBUTING.md and agree to the Code of Conduct

## Notes for the reviewer

<!-- Anything that is risky, surprising or undecided. Delete this section if there is nothing. -->
