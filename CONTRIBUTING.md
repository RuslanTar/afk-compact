# Contributing to afk-compact

Thank you for looking at afk-compact. Bug reports, test cases, documentation fixes and code are all welcome. This page covers how the repository is laid out, how to run its checks, and what a good report or pull request contains.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). To report a security problem, read [SECURITY.md](SECURITY.md) first and do not open a public issue.

## Ways to help

- **Report a bug.** Open an issue with the bug report form. The most useful thing you can attach is the zip that `/afk-compact:report` writes (see [Filing a good bug report](#filing-a-good-bug-report)).
- **Suggest a change.** Open an issue with the feature request form and describe the problem first, then the change you have in mind. For anything that changes a default or adds a setting, please talk it over in an issue before you write code.
- **Improve the docs.** The README and the pages under `docs/` are the user's only view of the plugin. A step that confused you is a bug. Edit the source in `src/` (see [How the repository is laid out](#how-the-repository-is-laid-out)), not the page on GitHub: the pages under `docs/` are generated, so an edit made there is overwritten.
- **Add a test case.** A failing case that shows a real problem is a good contribution on its own.
- **Send a pull request.** See [Pull requests](#pull-requests).

## What you need

| Tool | Why |
|---|---|
| macOS 13 or newer, or Linux with glibc | The two supported platforms. Native Windows is not supported yet; on Windows, work inside WSL 2. |
| `git` | Used by the plugin and by the test fixtures. |
| `perl` 5.28 or newer | The plugin's helper is Perl, using only modules that ship with Perl. The helper test suite is Perl too. |
| `python3` at `/usr/bin/python3` | The scripts in `tools/` start with `#!/usr/bin/python3` and use only the standard library. |
| `node` and `npm` | Only for `tools/typecheck` (TypeScript 5.6.3, a dev dependency), which the maintainer can run for you. Nothing under `plugin/` uses npm. |
| Claude Code on your `PATH` | `claude plugin test` and `claude plugin validate` run the plugin's tests and manifest checks. Neither needs you to be logged in. |
| Docker (optional) | Only for the Linux launcher cases in `tests/launcher/docker.sh`. |

Get the code and the one dev dependency:

```
git clone https://github.com/RuslanTar/afk-compact.git
cd afk-compact
npm install
```

## How the repository is laid out

```
src/        the source: the landing page, the docs pages, skills, assets, manifest and launcher templates
plugin/     what Claude Code installs; mostly built from src/ and committed
docs/       the documentation pages, built from src/docs/ and committed
tests/      helper cases, launcher cases and fixtures
tools/      build, check and generator scripts
brand.json  the plugin name, marketplace name, version and description
```

The important rule: **`src/` is the source, and `plugin/`, `docs/` and the root `README.md` are built from it.** The landing page is `src/landing.md`. Each documentation page is one file in `src/docs/`, and `src/docs/ORDER` lists which pages are joined into the `plugin/README.md` that ships with the plugin. `tools/build` renders `src/landing.md` into `README.md`, each page into `docs/<page>`, and the shipped pages into `plugin/README.md`. It fills `{{plugin}}`, `{{repo}}` and `{{cc_min}}`, fills `{{version}}` in the manifests only, and strips HTML comments. It also checks every link between pages. Do not edit a built file by hand: `tools/build --check` reports the drift and a later build overwrites your edit. To change a page, edit `src/docs/<page>.md`, then run `tools/build`.

| You are changing | Edit here | Then run |
|---|---|---|
| The landing page, a docs page, a skill, an asset, the manifest or the launcher template | `src/landing.md`, `src/docs/<page>.md` or the other files under `src/` (use `{{plugin}}`, never the literal name) | `tools/build`, and `tools/assemble --goldens` when you touched `src/assets/` |
| Hook code (TypeScript) | `plugin/hooks/*.ts` | `tools/typecheck`, `claude plugin test plugin` |
| Helper commands (Perl) | `plugin/helper/` | `perl tests/helper/run.pl` on the cases you touch |
| Test fixtures | `tests/fixtures/` | `tools/fixtures-gen` |
| Unit tests (TypeScript) | `plugin/tests/unit/*.test.ts` | `claude plugin test plugin` |

Files that only a tool writes (do not edit): `README.md`, `docs/`, `plugin/README.md`, `plugin/skills/`, `plugin/assets/`, `plugin/scripts/`, `plugin/.claude-plugin/`, `plugin/hooks/lib/*.gen.ts` and `plugin/tests/unit/_gen/`. `tools/build --check` also reports any stray file in those places.

## Running the checks

Run only what your change touches while you work, and everything in the first block before you open a pull request. Run each command from the repository root. CI runs the checks that need no Claude Code login and no private list on Ubuntu and macOS for every push to `main` and every pull request; see [What CI runs](#what-ci-runs).

**Generated files are current** (no Claude Code login needed, a few seconds to half a minute each):

```
tools/build --check
tools/fixtures-gen --check
tools/helper-replies-gen --check
tools/assemble --check
```

**The plugin's tests and manifest** (no login needed; the unit tests take about two minutes):

```
claude plugin validate plugin --strict
claude plugin test plugin
```

**The helper cases** (Perl; the runner prints TAP lines and a `# passed N, failed M` summary):

```
perl tests/helper/run.pl tests/helper/cases                      # every case, slow
perl tests/helper/run.pl --filter 'AT-PK|AD-0' tests/helper/cases # cases whose id matches
perl tests/helper/cases/watch/_driver/run-watch.pl                # the watcher cases, about a minute
```

Each case is a folder with a `case.json` (or, for the watcher, a `case.pl`). Every case runs with its own temporary `HOME` and a fixed clock, and the runner refuses to start when `TMPDIR` or `HOME` points into a real Claude Code config or state folder. Copy a neighbouring case to start a new one. `tests/helper/run.pl` documents the case format at the top of the file, and `tests/fixtures/README.md` documents the fixtures and their placeholders.

**The restart launcher's cases** (shell; a few minutes):

```
sh tests/launcher/run.sh --quick
sh tests/launcher/docker.sh        # Linux cases; needs Docker and two local images
```

**Type check** (needs Claude Code's type declarations; see the note below):

```
CC_TYPES_DIR=/folder/that/holds/claude-code.d.ts tools/typecheck
```

`claude-code.d.ts` is written by Claude Code's built-in `plugin-authoring` skill when it loads, so you need a Claude Code session to obtain it. If you cannot get it, say so in your pull request and a maintainer will run the type check.

**Text gates** over the built output:

```
tools/gates plugin README.md docs --names <file> --no-git-log
```

The gates also run over `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CHANGELOG.md`, `.github` and `bench`; run `tools/gates CONTRIBUTING.md --names <file> --no-git-log --only attribution` and the same call with `--only names`, `--only user-path` and `--only stale-name` for the files you touched.

The gates reject things such as absolute paths into a home folder, your account name and git email, leftover template markers, stale plugin names, co-author trailers and generator footers in files and commit messages, and wording rules for the skills and assets. `--names` takes a list of plugin and tool names that the README, the docs and the shipped files must not mention. The maintainer keeps that list outside the repository; for your own runs, any file with one name per line works, such as `printf 'placeholder-name\n' > /tmp/names.txt`. Your run therefore cannot catch a listed name; the maintainer runs the real list before merging your pull request.

**Everything at once** is `tools/check phase0` or `tools/check integration` (they need `--names <file>` or `GATE_NAMES_FILE`, as above, and `CC_TYPES_DIR`). `integration` repeats every helper case twice, builds renamed copies and, on a loaded machine, can take an hour or more. Maintainers run it before a release; you do not need to.

After a Claude Code update, `tools/launcher-flags` compares the restart launcher's flag table with `claude --help`, and the plugin's own `smoke` command (`/afk-compact:status` prints the exact call) compares the Claude Code binary with the version this release was tested on.

## Coding notes

- **No network, no telemetry.** The plugin makes no network calls, and a gate fails the build when a network module sits on the report path. A change that adds a network call will not be accepted.
- **Logs stay content-free.** A log row never holds summary or handoff text, messages, commands, file contents or secrets. A background-job record is the one place where a command is kept, and it stays on your machine; the [privacy page](docs/privacy-and-logs.md) lists what is stored where. When you add a field to a row, add it to the allowlist for that event and describe it in [docs/privacy-and-logs.md](docs/privacy-and-logs.md).
- **Perl uses only core modules.** The helper must run on a stock macOS or Debian perl.
- **No npm under `plugin/`.** An npm manifest in a plugin makes Claude Code run `npm install` on users' machines; a gate fails the build if one appears.
- **Text the model reads is budgeted.** Skills, handoff instructions and the resume context have size caps in `tools/gates` and `tools/budget-reasons.json`. If a change needs more room, say why in the pull request.
- **Defaults live in one place.** The manifest template (`src/plugin.json`) holds each setting's default; the helper and hook code must agree with it, and a gate compares them.
- **Write plainly.** Documentation and messages should say what happens and what to do, in short sentences. Do not claim a behaviour the code does not have, and do not state a measured number unless you measured it.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make one focused change. Smaller pull requests are reviewed faster.
3. Add or update a test case when you change behaviour, and the text in `src/landing.md` or `src/docs/` when you change what a user sees.
4. Run `tools/build` if you changed `src/`, then the checks listed above.
5. Add a line under `Unreleased` in [CHANGELOG.md](CHANGELOG.md) for any change a user could notice. Do not change the version number; maintainers do that at release.
6. Open the pull request and fill in the template. Say what you ran and what you could not run. The checks you cannot run are the names list (a placeholder works for your own run), the type declarations for `tools/typecheck`, and Docker for the Linux launcher cases; the maintainer covers those.

**Commit messages.** Use a short plain subject that starts with the area, then a colon, then what changed, such as `gates: refuse a hook command that names a plugin folder` or `README: the install steps name the marketplace`. Use the body to explain why the change is needed and what you checked. Leave out co-author trailers and generator footers; the gates reject them, and GitHub credits you through the pull request.

**Licence.** The project is under the [Apache License 2.0](LICENSE). Under section 5 of that licence, a contribution you submit is licensed to the project under the same terms, with no separate agreement or sign-off line.

**Merging.** Pull requests are squash-merged, and the maintainer writes the final commit message, so the history on `main` stays one plain commit per change. Your commits on the branch need not be tidy.

**Review.** A maintainer reviews pull requests when they can; the project is small and replies may take days. If a review asks for changes, push to the same branch. A pull request with no reply from its author for a few weeks may be closed, and you can reopen it at any time.

## What CI runs

`.github/workflows/ci.yml` runs on every push to `main` and every pull request, on Ubuntu and macOS:

- **generated files are current**: the four `--check` commands from [Running the checks](#running-the-checks). If it fails, run `tools/build` and commit what changed; edit `src/docs/<page>.md` or `src/landing.md`, never the page under `docs/`.
- **text gates**: `tools/gates` over the built output and the community files. A pull request from a fork has no access to the names list, so its run uses a placeholder.
- **validate and unit tests**: `claude plugin validate` and `claude plugin test`, with Claude Code installed from npm and no login.
- **helper, watcher and launcher cases**: the Perl and shell cases.

CI does not run `tools/typecheck`, the Docker launcher cases or `tools/check integration`.

## Filing a good bug report

The plugin keeps content-free logs on your machine. `/afk-compact:report` bundles them so you can share what happened without sharing your work.

1. In the session that showed the problem (or any session on the same machine), run `/afk-compact:report --since 7d`. Use a shorter or longer window if you know when it happened.
2. The skill first runs a dry run that lists what would go in, then writes one zip and prints its path. **Nothing is uploaded.**
3. Read what is inside before you attach it. The zip holds a `README.txt` that explains each file, plus versions, your effective settings (numbers and on/off values; paths only as `default`, `custom` or `unset`), recorded probe results and per-session log rows. It holds no conversation text, summaries, commands, file paths, or repository and branch names.
4. The skill asks separately whether to add saved compaction summaries and published handoffs. Those hold your sessions' text, so the default answer is no. Say yes only if you are happy to share that text, because secret scans catch credentials but not business content.
5. You can check a zip with `report verify --zip <file>` before you send it. It runs through the same launcher call that `/afk-compact:status` prints for `report`.
6. Attach the zip to the issue, or tell us you would rather not and describe what you saw instead. Both are fine; the decision is yours.

Please also include:

- the plugin version (`/afk-compact:status` shows it) and the Claude Code version (`claude --version`);
- your operating system and whether you use a terminal session, the desktop app or an editor extension;
- what you expected, what happened, and the steps that lead to it;
- any non-default settings that could matter, such as `handoff_root`, `idle_compact` or `keep_warm_hours`.

If the report might hold something you cannot share, do not attach it: open the issue without it, and a maintainer will ask only for the specific facts needed.

## Maintainers

**Before merging an outside pull request**, run the names gate locally with the real list (`tools/gates plugin README.md docs --names <real list> --no-git-log`), because the pull request's own run used a placeholder. The push to `main` runs it again with the list kept as a repository secret.

**Cutting a release:**

1. Set `version` in `brand.json`, run `tools/build`, and move the `Unreleased` entries in `CHANGELOG.md` under the new version with its date.
2. Run `tools/check integration` on a quiet machine and keep the log.
3. Merge to `main` and create the tag `vX.Y.Z` on the merge commit. Check first that `plugin.json` and the marketplace entry agree on the version.
4. Create the GitHub release from that tag, titled with the version and using the new CHANGELOG section as its text.

Thank you for helping.
