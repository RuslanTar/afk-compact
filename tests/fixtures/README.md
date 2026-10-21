# tests/fixtures — shared test fixtures (WP-fix)

Every file here is synthetic. No row, summary or payload comes from a real session. Owner: WP-fix (`OWNERS.tsv`), except `assembly/expected/`, which `tools/assemble --goldens` writes.

`tools/fixtures-gen` renders the fixtures into `plugin/tests/unit/_gen/{brand,corpus,payloads}.gen.ts` for U tests (the kit has no fs). `tools/fixtures-gen --check` runs the WP-fix exit checks: every JSON file and JSONL line parses, `expected.tsv` matches the reference detector, no secret-shaped string sits in any file, the generated files are current, and a renamed temp copy passes after the plain regenerate step.

## Placeholders

| Token | Filled by | Value |
|---|---|---|
| `{{plugin}}`, `{{marketplace}}` | `tools/fixtures-gen` (U), the case runner (H) | `brand.json` `name`, `marketplace` |
| `$TMP`, `$HOME`, `$ROOT`, `$WATCH`, `$SID` | case runner | the case's temp dir, fresh HOME, handoff root, watch dir, `ids.json` `sid.S1` |
| `$FIXTURES` | case runner | absolute path of `tests/fixtures` |
| `$SECRET{<id>}` | case runner only | the joined fragments of `secrets/corpus.json` entry `<id>` |
| `$NONCE` (any `$<VAR>` a step captured) | case runner | the value an earlier step's `capture` took from its stdout (`sequences/S-21-classic`) |

A file holding `$SECRET{` is never copied into a generated module.

## Layout

| Path | What | Used by |
|---|---|---|
| `ids.json` | sids S1–S3, agent ids A1–A3, pids, start times (`STORE_TEST_CLAUDE_PID` values), nonces by role, the case clock (`2026-10-21T14:05:12+03:00`, `Etc/GMT-3`), canary strings | everything |
| `payloads/<Event>/<case>.json` | classic hook stdin, d.ts input fields only (BUILD-PLAN §3.5) | H, U |
| `payloads/<Event>/{malformed,empty}.invalid` | broken and empty stdin for every event (BT-07, WATCH T-16) | H |
| `summaries/NN-<slug>.txt`, `summaries/expected.tsv` | the 41-summary corpus | AT-C-02, C-03, C-09, M3-02, M3-17 |
| `watch/dispatch-<nonce>.json` | dispatch records (BUILD-PLAN §3.4), roles below | H |
| `watch/run10/` | the ten-compaction run of AT-M3-07 / AT-S-02 (`sequence.json`, dispatches) | H |
| `watch/*.json`, `watch/*.count` | `mod-alive.json`, `classic-alive.json`, `version.json` states, `boundaries.count` seeds, sample `log` rows | H |
| `plugin-data/last-version-2.1.304` | `${CLAUDE_PLUGIN_DATA}/last-version` for AT-M3-10 | H |
| `roots/<case>/` | handoff-root states to copy into `$ROOT`: pins, lineage, per-process records, two earlier copies (`seq-2`) | AT-M5-01, M5-02, M5-10 |
| `settings/<case>.json` | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json` with `pluginConfigs` | AT-P-10, E-14, D-12 |
| `transcripts/<case>/main.jsonl`, `subagents/agent-<id>.jsonl` | transcript rows, TF Q3 §1a shapes | AT-C-08, M3-02, M3-12, M4-03, T-01..T-25 |
| `transcripts/scope-cases.json` | the scope-proof table: dispatch, summary, transcript dir, count seed, expected scope | AT-C-08, AT-M4-03 |
| `watcher/T-NN/` | `input.json` (seeds, ordered hook steps), `payloads/`, `seed/`, `expected.json` | WATCH §9 T-01..T-25 |
| `sequences/<id>/`, `transcripts/<id>/` | ordered hook steps with the main transcript's state per step: `S-21-classic`, `S-21-mod` (the live S-21 event order) | F2-1 regression, AT-C-08, AT-M4-03 |
| `secrets/corpus.json` | secret values as fragments (with per-line and per-value parts), file-name deny-list cases, sweep files | AT-E-04, E-06, S-10 |
| `tempfiles/<case>.json` | large or many-line files the runner creates at run time | AT-E-02, E-05, E-07, E-08 |
| `repos/<case>.json` | git repo recipes the runner materialises as `$TMP/<dir>` | AT-M5-02, E-01, E-09, HT-B-02, D-12 |
| `bin/git-slow`, `bin/queue-stub`, `bin/xcode-select-fail` | PATH stubs | AT-E-01, AT-E-10, HT-LA-01, AT-P-14 |
| `queue/<case>/` | canned `queue-stub` answers | AT-E-10 |
| `assembly/runtime.json` | `@token@` values for `tools/assemble --goldens` (BT-04) | goldens |

## Formats

**Payloads.** Keys are exactly the d.ts classic input types (`PreCompactHookInput` … `PermissionDeniedHookInput`, 2.1.305). `prompt_id` is left out where TF Q2 §1 says it is absent (SessionStart startup, resume, clear, fork). `permission_mode` is left out of PreCompact, PostCompact and SessionStart (lab key sets). `transcript_path` is `$TMP/projects/-tmp-example-repo/<sid>.jsonl`, and `cwd` is `$TMP/example-repo`. One exception is deliberate: `PostCompact/extra-key.json` adds `fixture_extra_key` (AT-M3-11).

**Corpus.** Each `.txt` file is the raw text as PostCompact (`<summary>…</summary>`) or the mod (`This session is being continued…` wrapper) sees it. `expected.tsv` columns: `file`, `verdict`, `marker_line`, `sentinel_from_end`, `nonce`, `scope`, `normalized_sha256`, `dispatch`. `-` means not found. `dispatch` is empty for text alone, `none` for a PostCompact with no dispatch at all, or a `watch/` record path for this compaction. The reference detector in `tools/fixtures-gen` fixes the readings below. The TS and helper detectors must give the same tuple (AT-C-03).
- Head stripping repeats over the leading lines: blank lines, the `This session is being continued` line, the `<tools-used-before-summary>` block, a `Summary:` line and a `<summary>` tag. So the marker after the full wrapper is body line 1 (AT-C-02 a).
- The body ends before the first `</summary>`. Trailing blank lines are trimmed. Line ends become `\n`. The normalized body is the lines joined by `\n` plus one final `\n` (empty body: empty string). `normalized_sha256` is computed over that text with `{{plugin}}` filled.
- The marker is the first anchored match in body lines 1–5. The sentinel is searched in the last 3 non-blank lines, and `sentinel_from_end` is reported whenever one is found there, also for `unshaped`.
- With a dispatch, the checks run in this order: `stale` (marker nonce ≠ the dispatch nonce; or dispatch `none` and a marker), then `scope-leak` (dispatch `agent_id` set and `s=main` or a `## Resume here` heading, with any marker or none (41); dispatch main, meaning `agent_id` null with channel `mod-hook` or `mod-self` (MOD §2.4 P1), and `s=sub`; a `classic` dispatch proves neither scope), then the text verdicts.
- The corpus brand is `{{plugin}}`, so the sha column changes with a rename. The plain regenerate step `tools/fixtures-gen` (BUILD-PLAN §4.6) rewrites that column for the current brand, so a rename commits `expected.tsv` with the other regenerated files. `--check` runs the same rename in a temp copy (check `rename`).

Groups worth knowing: 01–05, 11, 27, 29 and 38 share one normalized body (PostCompact, mod wrapper with and without tags, bare, CRLF, blank tail, leading blanks, text after `</summary>`), and so do 17 and 18 (subagent). 37 adds an unlisted trailer to the mod form only. Its PostCompact twin is 01 (AT-M3-17).

**Dispatch roles** (`watch/dispatch-<nonce>.json`, all S1 unless noted): `1a2b3c4d` mod-hook main auto midturn · `2b3c4d5e` mod-self plugin · `3c4d5e6f` and `bc1d2e3f` (2 s later) classic · `4d5e6f70` precompute · `5e6f7081`, `6f708192`, `708192a3` subagents A1–A3 · `8192a3b4` mod-hook main manual, pending, for the unmarked defer (AT-M3-15) · `5ca1ab1e` an earlier main dispatch · `9a0b1c2d` auto, and `ab0c1d2e` precompute, both 11 min old (AT-M3-06) · `d2e3f405` main in the second process P2 (AT-M5-04) · `d3e4f506` session S3 (AT-M5-03). `0badf00d` has no record on purpose (AT-C-10).

**Transcripts.** The runner copies `main.jsonl` to the payload's `transcript_path`, and `subagents/` to `<session dir>/subagents/`, where the session dir is the transcript path without `.jsonl`. `main.part-NN.jsonl` files are appended in step order, so turn ends (Stop events) fall between rows (T-12, T-25). Timestamps are UTC (`Z`). The case clock is +03:00. One line in `T-16/main.jsonl` is malformed on purpose.

**Watcher cases.** `input.json` holds: `seed` (files to copy before the first step; `to` starts with `$WATCH` or `$ROOT`), `repo` (a recipe), `transcripts`, optional `transcript_mode` and `unreadable` (paths to create with mode 000), and `steps`. Each step has `now`, `argv`, `stdin`, an optional `transcript_append`, and `expect` (`exit`, plus `stdout`; `null` means not asserted). `expected.json` quotes the WATCH §9 row, names the v1 scope (BUILD-PLAN §5.2), and lists `asserts` in the §3.5 case vocabulary: `rows` (file, `ev`, `fields`, `count`), `absent_rows`, `files`, `grep_absent`. `metrics` gives the spec's metric values for fields that WATCH §6.3 does not name on a row. WP-watch maps those.

**Sequences.** `sequences/<id>/input.json` uses the watcher `input.json` keys plus three. `transcript_state` (`{boundaries, summaries}`) is the main transcript's `compact_boundary` and `isCompactSummary` row count when that step's hook fires, after its `transcript_append`, which is appended before the step runs. `capture` is the runner's `{VAR: "re:<regex>"}` from the step's stdout, used as `$VAR` in later payloads and transcript parts. `"order": "S-21"` makes `--check` require that SessionStart(compact) and PostCompact see no boundary row newer than PreCompact. `expected.json` gives `observed_order`, and `step_asserts` (`after_step` plus `files`, `rows`, `absent_rows` in the §3.5 vocabulary, each with a `why`).
- The S-21 order (lab `E1/probes/S-21-S-26.md` §3, 2.1.306, one manual and one auto run): mod before-step, PreCompact, the summarizer fork's SubagentStop (`agent_type` empty), SessionStart(compact), PostCompact, mod after-step. Only then do the boundary row and the summary row reach the main transcript, so both hooks see 0 of each. The next Stop is the first hook that sees them. `transcripts/S-21-*/main.part-02.jsonl` is what lands after PostCompact. The summary row's own timestamp is earlier than SessionStart, so row timestamps cannot order writes against hooks.
- `S-21-classic`: no mod, so PreCompact writes a classic dispatch and the summary carries its nonce (`$NONCE`, captured from PreCompact stdout). Inside PostCompact there is no proof (F2-1), so the asserts are: no main-slot copy and no sweep, the stash is kept, and after Stop the summary is in the main slot (P3 at reconcile).
- `S-21-mod`: the mod's dispatch `1a2b3c4d` is seeded, P1 proves main inside PostCompact, and after Stop there is still exactly one copy.

**Repo recipes.** `{v, id, dir, git, branch, author, commits: [{message, files}], dirty, untracked, ignored_files, note}`; `git: false` recipes have `files` only. A `.gitignore` in the first commit holds the ignored patterns. Commits use the fixed author and date in the recipe.

**Temp-file recipes.** `{v, id, env?, files: [{path, bytes, fill} | {path, lines, line}], paths_log, expect}`. `fill` is repeated up to `bytes`, and `line` takes `{n}`. `paths_log` lists the temp paths the mod would have recorded. The row form of `<watch>/<sid>/paths.jsonl` belongs to WP-core and WP-mod.

**Secret corpus.** `entries[]`: `{id, rule, class (HARD | WARN | none), fragments[], part_of?, note}`. Joining the fragments in order gives the value, and no fragment alone is secret-shaped. `rule` is the spec-literals `secret_rules` id (`src/assets/handoff-spec.md`) that the joined value must hit, `-` for none. `part_of` lists entries whose value contains this one: a line or value of a larger secret, so a case can check that each piece is gone (`grep_absent`, `absent_text`), not only the whole value. A part's `class` is what it hits alone. `names[]` lists file names with `withheld` or `copied`. `files[]` lists sweep files whose `content` lines hold `$SECRET{}` tokens, each with the expected action (AT-E-04 counts them all, so a new sweep file changes its totals).
- `pem-rsa-short-tail`: a PEM block with real newlines, three 64-character body lines and a 26-character last line. `pem-rsa-short-tail-json` is the same block with `\n` escapes: inside a JSON payload string it decodes to the real block, and inside a `.json` log it stays escaped. Parts `-l1`..`-l3` (each hits `high-entropy` alone), `-l4` (hits nothing alone) and `-end`. `payloads/PostCompact/pem-summary.json` carries the block in a summary, like `jwt-summary.json` (dispatch `1a2b3c4d`).
- `cookie-multi`: one `Cookie:` header with three session-like pairs and `theme=dark`. Parts `-v1`..`-v3` are the three values.

**Stubs.** Install `bin/git-slow` as `git` in a directory first on PATH: it sleeps `GIT_SLOW_SECONDS` (default 3), then runs the next `git`. `bin/queue-stub` answers `<subcommand>.out`/`.rc` from `QUEUE_STUB_DIR` (default `queue/prose`), logs each argv to `QUEUE_STUB_LOG` when set, and exits 64 for a subcommand without an answer. Install `bin/xcode-select-fail` as `xcode-select`: it exits 2.

## Not here (open)

- A structured `queue_cmd list --json` answer and the `adopt` answers (AT-E-10 b, HT-LA-01 mismatch): design/ defines neither output shape. Only the prose and failure answers exist.
- `<watch>/<sid>/paths.jsonl` rows, the lock owner record and the `halt.json` content: their formats belong to WP-core and WP-mod.
- Skill-side drafts and handoffs for the HT cases: WP-skills keeps case-local data under `tests/helper/cases/skills/`.
