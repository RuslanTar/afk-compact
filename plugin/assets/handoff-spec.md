# afk-compact handoff spec v2 (shared literals)

One source for the literals that the handoff skill, the resume skill, the compaction texts, the mod, the helper, the publish lint and the watcher share. The handoff template mirrors this file; where they differ, this file wins. Code reads only the `json spec-literals` block at the end and hard-codes no heading, vocabulary or pattern.

## 1. Marker and sentinel

- Marker: `⟪afk-compact v1 n=<nonce> s=main|sub|manual⟫`. Sentinel: `⟪/afk-compact n=<nonce>⟫`. The nonce is 8 lowercase hex from code.
- Scope: `main` (main compaction summary) · `sub` (subagent compaction summary) · `manual` (the handoff skill).
- In a summary or handoff the marker sits in the first 5 body lines after the wrapper lines are stripped, and the sentinel in the last 3 non-blank lines. Non-blank text after the sentinel is a trailer.
- Wrapper lines stripped before the search: the `This session is being continued…` line, a `<tools-used-before-summary>…</tools-used-before-summary>` block, a closed `<analysis>…</analysis>` block (the summarizer's scratch text, kept before `<summary>` in a PostCompact summary), a closed `<system-reminder>…</system-reminder>` block (the installed summary wraps the tools-used block in it), a `Summary:` line, and the `<summary>` / `</summary>` tags. An unclosed `<analysis>` or `<system-reminder>` block is body. Claude Code's own closing lines after an installed summary (`copy_trailers`) are cut from its end.
- In instructions (the mod's instructions, a classic `custom_instructions`) the marker sits mid-line, so that search is unanchored and the last match counts. It counts as ours only when a dispatch record holds its nonce.
- Any other bracketed or prefixed header line is someone else's: never ours, left untouched.

## 2. Sections

Main form, in this order (a heading matches by its literal prefix at the start of a `#` line, so `## Resume here (≤5 lines)` is `## Resume here`):

```
⟪afk-compact v1 n=<nonce> s=…⟫
# <ticket or topic> — <current state in ≤8 words>
## Resume here
## User constraints
## Approvals
## Decisions and do-not-re-raise
## In flight
## Live state
## Open questions
## Location
### GSD
### Environment
### Guards in force
### Ownership
## Work done and findings
## Evidence
## Next steps
⟪/afk-compact n=<nonce>⟫
```

Subagent form, in this order: `## Task as assigned` · `## Constraints from the parent` · `## Report` · `## Done` · `## Findings` · `## Produced but not yet delivered` · `## Own background tasks` · `## Next action`.

Each heading of both forms has a fixed section id (`section_ids`, e.g. `main:next-steps`, `sub:done`). Beta report exports name a section by this id, never by its position; an id never changes when a section is added, moved or renamed, and a new section gets a new id.

## 3. Verdicts

First match wins: `stale` · `scope-leak` · `unshaped` · `truncated` · `ok-trailer` · `ok`. For readers, "ok" means `ok` or `ok-trailer`.

## 4. Vocabularies

- **Status words** (Resume here; the work lane's state): `working` (a step can start, or a job runs whose result the work acts on) · `finished` (every listed step done, nothing runs) · `hard-blocked` (all left waits on the user, nothing runs) · `soft-blocked` (all left waits on the user, a job still runs). Older files may hold `active` · `blocked` · `waiting-owner` · `waiting-job` · `done`: read them, never write them. Next steps items end `· todo` or `· done`.
- **Work-state ladder**: `proposed` · `queued` · `implemented` · `tested` · `committed` · `pushed` · `in review` · `merged` · `deployed` · `published` · `installed`.
- **Claim tags**: `[verified <stamp>: <cmd>]` · `[unverified]` · `[inherited: <stem>]` · `Superseded: <id> by <id> (<stamp>)`. Live state tags: `measured` · `verified` · `unverified` · `inherited`.
- **Stamp** (RV-24): a time is always `YYYY-MM-DD HH:MM ±hhmm` (local date, local time, numeric UTC offset, all three, e.g. `2026-10-21 14:05 +0300`). The helper prints stamps; in a shell, `date '+%Y-%m-%d %H:%M %z'`. Older files may hold `HH:MM` or `MM-DD HH:MM` (`time_legacy_re`): read them, never write them. Frontmatter `date` stays ISO with a colon offset.
- **Ids**, one per item, never ranges, kept across a chain: `U-n` user constraint, approval or ask · `D-n` decision · `X-n` rejected option, refuted finding or failed approach · `Q-n` question · `B-n` in-flight row (plus its runtime id).
- **Questions**: owner `next-agent` · `user` · `external:<who>` · `bg:<B-n>`; raised by `user` · `agent` · `external`; status `unasked` · `asked <stamp>` · `timed out` (only when the tool result says it timed out) · `no answer (<the tool's words>)` (an empty dialog result or no reply) · `answered: <answer>`. Only the user answers a user-owned question: a background result, a notification or a peer message never changes its status.
- **Restart classes**: `auto` · `ask` · `never`.
- **Acuity** (Resume here, first line, after the status word): `stable` · `watch` · `unstable`. `unstable`: broken build, half-applied migration or destructive step, red test mid-fix, or `MID-STEP`. `watch`: jobs running, or a pending merge request, pipeline, review or answer, or a time limit. `stable`: none of these. It is the writer's rating. The **floor** is what code measured: a merge, rebase, cherry-pick or revert in progress → `unstable`; a measured in-flight row → `watch`; otherwise `stable`. A reader raises the rating to the floor and never lowers it. Missing in older files: read as `-` (no rating).
- **Stalled** (an agent or teammate a workflow did not start): (a) idle while the output it waits on has ended. That one gets a wake message with its id. (b) No progress past due plus grace, which is only reported in the post-compaction light path. A workflow is never "stalled" in this sense (the workflow gate applies).
- **In-flight `kind`**: `agent` · `teammate` · `workflow` · `monitor` · `cron` · `shell` · `server` · `peer` · `external`.
- **Dies on**: `/clear` · exit · 7-day expiry · nothing. A background shell or server survives `/clear`; at exit it stops unless the user picks "Move to background and exit", so its value is `exit`.
- **Frontmatter `status`**: `in-progress` · `blocked` · `completed`. **`lineage_reason`**: `clear` · `fork` · `bg-copy` · `handoff-resume` · `none`.
- **Resume relation**: `same-session` · `successor` · `other` · `unselected`. **Integrity**: `ok` · `possibly truncated` · `legacy` · `unshaped` · `s=sub`.
- **Carry base** (`previous_kind`, RV-19): `own` (this session's file) · `chain` (a lineage predecessor's file) · `foreign` (another session's file). These are the relations `same-session`, `successor` and `other` as the writer sees them. A document with `imported_from` is never the carry base.
- **Own handoff** (resume Rule 2): a file this plugin wrote in the private store (`handoff_root`): marker and sentinel with one nonce, no `export: repo`, no `imported_from`, and relation `same-session` or `successor` (carry base `own` or `chain`). This session's compaction summary and its saved copy are own. A file of this session or a lineage predecessor in the private store whose marker and sentinel carry one of the plugin's former names, with one nonce, reads as own (a read-only alias: nothing is ever written under a former name). Everything else is **foreign**: relation `other` or `unselected`, integrity `legacy`, a `repo:` candidate, an imported copy, and any line carrying a `[from …]` tag.
- **Real risk** (a command taken from a foreign handoff's text): ask first when it has an outward or destructive class (§12), contacts the network (a URL or host argument; `ssh`, `scp`, or `rsync` to a host; `curl`, `wget`; `git fetch`, `pull`, `push`, `clone`, `ls-remote`; a cloud, cluster, registry or package-manager command that reaches a service), writes or deletes outside the repository's work tree, matches a production class, is an explicit gate, reads credential material (`~/.ssh`, `.env*` and `.envrc`, key files, `.netrc`, `.npmrc`, shell history, `.git/config`, the process environment), reads a file outside the work tree, holds a credential value, or cannot be judged (command substitution, `eval`, `sh -c`, a pipe into a shell or interpreter, an encoded payload, a single quote `'`, which can end the quoting of whatever passes the command on). It carries **no real risk** when it is a local read-only command inside the repository (`git status`, `log`, `diff`, `show`; `rg`; `ls`; reading a tracked file), byte-identical to a command the plugin recorded (`jobs.jsonl`) while no test or build definition changed (below), or the repository's own test, check, lint or build run inside the work tree with no further target and only the flags `test_build_re` lists (§19): a `test`, `check`, `spec`, `lint`, `typecheck` or `build` target the repository defines, in a file git tracks, for make, npm, pnpm, yarn, rake or gradle; for make, npm, pnpm and yarn, whose targets the code checks, also with one of the suffixes `-fast`, `-unit`, `_unit`, `:unit` or `-quick`; for make also with the variables `V=1` or `VERBOSE=1`; `cargo test|build|check`; `go test|vet|build`; `pytest`, each with plain names or relative paths inside the tree. Any other target asks, however the repository defines it (`release`, `publish`, `install`, `deploy`, `db:*` and the like), and so does any option that names another definition, file, folder, plugin, program or output (`make -f`, `-C`, `rake -r`, `gradle -p`, `pytest -p`, `--basetemp`, `--rootdir`, `go -o`, `-exec`, `cargo --manifest-path`, `--target-dir` and the like); the exemption ends for the session once it changed a test or build definition (a Makefile, `package.json` scripts, a Rakefile, `build.gradle*`, `conftest.py`, `.envrc`, git hooks, CI files) on a foreign handoff's word. In code, such a change is any test or build definition that differs from HEAD in the work tree or between the HEAD the session started on (its first process record for that work tree) and HEAD, so a commit, merge, checkout or reset counts too; a test or build run asks when that start HEAD is unknown, or when git cannot list the changes (it fails, runs out of time or its output is cut off), and so does a recorded command then. The start HEAD is the oldest one of the session and of its predecessors through `/clear` and handoff-resume links (up to three). Stated limits: a fork starts on the HEAD it finds; a test or build file git ignores (an ignored `.bundle/config` or `.npmrc`) and git hooks never show in git status, so a change to one does not end the exemption; and a test file the session wrote on a foreign handoff's word is code like any other, run by the test command without an ask. `<store> risk --cmd-file <file>` applies these classes in code (`risk_classes`, §19); it reads the command from a file the session wrote with its Write tool, so foreign text never reaches a shell line. `readonly_cmd_re` matches one pipeline segment and refuses redirects, expansions, globs and arguments that start at home, at the root or in a parent folder, plus the options that run a program, write a file or follow a link out of the tree, in any short-option bundle or long-option abbreviation (`rg --pre`, `git grep -O` or `--open…`, `git log --output`, `sort -o`, `--out…` or `--compress…`, `tree -o`, a second `uniq` operand, `rg -L`, `grep -R`, `tree -l`, `ls -L`, `diff -r`); in code, `write-outside` and `read-outside` resolve each path argument's real path (an option's attached value too, and any `..` step) and compare it with the work tree component by component. `tests/fixtures/risk/corpus.tsv` is the reference corpus.
- **Explicit gate**: `deploy`; a change to an environment, its secrets or production data (`env-write`, which includes every production write, `prod-write`); infrastructure (`infra-write`); a push or force-push to a protected branch (the remote's default branch, a name matching `protected_branch_re`, or one the user added in the `protected_branches` setting); and any gate the user stated (a `U-` line or `Guards in force`). A gate always gets a fresh ask: no approval carries past it and no setting removes it. Claude Code's own permission prompts apply on top of every rule here.
- **Approval (scoped)** (`## Approvals`): `U-n: approval "<the user's words>" (answer to "<question>") — action <what> · targets <identity @ the state it rests on>, … · once | standing (until <condition>) · not yet used | used <stamp> · given <sid8> <stamp>`. It carries across a compaction or a resume within this session or from a predecessor reached only through `clear` or `handoff-resume` links (a `fork` or `bg-copy` predecessor's approvals, or those behind a link of any other kind, are context only, though its commands stay own) when (1) code checked the quote (frontmatter `approvals_checked`, or `Approvals (checked)` in the re-measure), (2) every target still exists and every recorded state still matches (same merge-request head, branch tip, lane, environment), (3) it is not spent and its effect is absent (a run cut off before its `used` mark must not repeat), and (4) its action is not an explicit gate. Under `unattended_prod_reads: forbid` a checked approval that names one production read and its targets counts like a fresh yes: the setting is the default rule and the user's explicit approval wins; a production write stays an explicit gate, and a production action counts as a read only when it is exactly one read-only command (`kubectl get`, `describe`, `logs`, `top`, `explain`, `version` or `api-resources`; `helm list`, `status`, `get` or `history`; a `readonly_cmd_re` command) in plain words with the listed flags only, every target is `<identity> @ <state>` with no second step, and no write or outward word appears; anything else, a read told in plain words included, counts as a write (fail closed). An approval's words name a push to a protected branch when either side of a `src:dst` refspec, a branch it names, or the branch after a remote prefix (`team/release` names `release`) is protected (a name followed by a sentence mark, "to main!", "(main)", "main/", counts as that name); a push approval that names no branch (only a `branch <name>` target or phrase, a refspec of a `git push` command, or in plain words a name right after "push" names one, and only when that name has a letter and either a slash or is a branch that exists in the working tree's repository; `HEAD`, a number ("push 2 commits"), a hyphenated word that is no branch ("the follow-up fix"), a filler word ("push this branch to origin"), a tag (`v1.2.0`, `refs/tags/…`, "the tag", `--tags`), a `git push` holding a command substitution or a variable (`$(…)`, a backtick, `$x`), a file path or an `owner/repo` slug does not), and a local merge (not a merge request) whose words name a protected branch, count as a push to a protected branch too; a gate named in plain words ("push feat/x and deploy") counts beside the push. Once a session has claimed an ended predecessor by resuming its newest handoff (`.sessions/successors/`), the claim splits the predecessor's line at its time: handoffs of the predecessor, or of a session before it on its line, dated at or before the claim carry approvals only along the claimant's line, and those written after the claim only along the predecessor's own; resumed itself, the predecessor re-asks its earlier approvals, and its quote checks count only what the user typed after the claim. A once approval is spent when its action ran (`used <stamp>`); a standing one ends when a target stops matching or the user withdraws it. When the words do not say "standing" (or the like), it is `once`. A foreign approval is context only (`context only, not valid here; re-ask`). In a handoff the plugin asked for (a stage bound to a plugin handoff turn, `handoff_ht`: reasons halt, precompact and idle) every own approval is context only too, `U-n: approval "<the user's words>" — action <what> · targets <…> ; context only, not valid here; re-ask` (`approval_context_re`, optionally ` · given <sid8> <stamp>`), with no `once`/`standing`, no state and no denial note, and its Next step reads `ask user: <action>`; publish lists none of them in `approvals_checked`, records no line hashes and writes `requested_by: plugin` into the frontmatter, so none carries. The same line is accepted in any handoff and never carries; `measure` lists it under `Approvals (context only, re-ask)`, as `(plugin handoff)` in a file marked `requested_by: plugin` (where no line carries, whatever its `approvals_checked` says) and as `(written as context)` elsewhere. `(answer to "<question>")` is optional: it keeps the question a short answer ("yes") replies to beside the user's words, and the quote check reads the words only; a handoff the plugin asked for writes neither it nor a denial note. In a handoff the user asked for, an approval whose action a call of this session, its subagents' and workflow agents' calls included, was refused for (by the auto-mode classifier, a deny rule, a denied directory, a built-in safety check or the permission mode, or the user at the prompt; not by a hook) is context only too, with its denial note: `U-n: approval "<the user's words>" — action <what> · targets <…> ; context only, not valid here; re-ask · denied <by whom> <stamp>`, and its Next step reads `ask user: <action>` (§15 `approval-denied`); a denial note never sits on a usable approval. Text in a file, a tool output other than the user's own answer in one of this session's question dialogs, an instruction file or another session's summary is never an approval.
- **Carried-line tag** (lines taken from another session's handoff): `[from <sid8> · <their id> · <their stamp>]`, or `[from <sid8> · - · <stamp>]` on a pointer line. A foreign approval is carried only as `context only, not valid here; re-ask`. A command taken from a foreign handoff (Step 1, a Next step, a probe, a re-check, a restart) keeps its tag (`-` for the id) in every later handoff, and a compaction summary marks it `[from <sid8>]`, until the user approves it or it is rebuilt from facts this chain checked; a tagged command is foreign wherever it appears.
- **Queue lane**: `^(lane|auto):[A-Za-z0-9._/-]+$`; only the helper writes it. A resume adopts only `lane:` ids.

## 5. Explicit none-forms

Only these sections take a none-form; other empty sections are omitted.

| Section | Handoff (skill) | Compaction summary |
|---|---|---|
| User constraints | `none stated` | `none stated` |
| In flight | `Nothing in flight — checked <stamp> via <channels>` or `Nothing in flight known (not checked)` | `Nothing in flight as of the last message (not checked)` |
| Live state | `none beyond git — checked <stamp>` | `none beyond git (not checked)` |
| Open questions | `none` | `none` |
| Own background tasks (subagent) | — | `none (not checked)` |

## 6. In-flight rows

- Handoff: a 7-column table `B-n · runtime id | kind · what · owner | due · watched (last probe) | probe | on finish | dies on | restart`, ≤8 rows; past 8 the table ends `+N more: B-9, B-10; see evidence/<stem>/inflight.md`.
- Compaction: one row per item, `B-n <runtime id> · kind · what · due · probe · class`, optional `restart:` line (data, never run), ≤8 rows; past 8, `+N more: <ids>`, and the re-measure lists every id.
- Restart recipe: `<bucket>/evidence/<stem>/restart/<B-n>.md`. Restarts run only from the recipe `heal-check` prints.
- Probe for a `shell`, `server` or `external` job: `<store> wait --for <spec> --max 0` (§14), which checks once and returns at once.

## 7. Ledger fold line

`D-1, X-2 settled; full text in <path>`: each moved id named, never a range. The line is ledger and is carried unchanged. `U-` lines never move.

## 8. Frontmatter

- Handoff: `kind: handoff`, `writer`, `nonce`, `date`, `session_id`, `actor`, `previous_session_id`, `lineage_reason`, `transcript_path`, `claude_pid`, `cc_version`, `repository`, `bucket`, `worktree`, `branch`, `git_commit`, `status`, `ticket`, `queue_lane`, `previous_handoff`, `previous_kind`, `own_previous_handoff`, `imported_from`, `approvals_checked`, `requested_by`, `gsd`. Empty keys are omitted. `previous_kind` (`own` · `chain` · `foreign`) and `own_previous_handoff` (a path, only when the carry base is foreign and an own file exists) are written by `begin`/`publish` (RV-19); `imported_from` (`repo:<rel path>`) only by `project copy --from repo`; `approvals_checked` (a comma list of the `U-` ids of `## Approvals` lines whose quote passed `approval-quote`, or that were carried from an own-chain file that listed them) only by `publish`, which also records the SHA-256 of each listed line in the store (`.sessions/approvals/<sid>.<nonce>.json`, never in the file); a listed line that no longer matches its hash, has none, or sits in a file without a record is context only (re-ask). `requested_by: plugin` (only by `publish`, in a stage bound to a plugin handoff turn) marks a handoff the user did not ask for: none of its approvals carries (§4 Approval (scoped)).
- Summary copy: `kind` (`compact-summary` · `subagent-summary`) and the handoff keys except `ticket`, `gsd`, `previous_kind`, `own_previous_handoff`, `imported_from`, `approvals_checked` and `requested_by`, plus `bucket_source`, `trigger`, `compaction_seq`, `tokens_before`, `tokens_after`, `verdict`, `channel`, `seat_state`, `evidence`, `redacted`.
- Export (repo mode, D-12 §1.5.5; `frontmatter_keys_export`): the handoff keys minus the machine-only `transcript_path`, `claude_pid` and `worktree`, minus the private-chain keys `previous_kind`, `own_previous_handoff`, `imported_from`, `approvals_checked` and `requested_by`, plus `export: repo`. `bucket`, `previous_handoff` and `gsd` are rewritten to repository-relative values. A key outside this list is dropped from an export.
- `writer`: `handoff` · `mod` · `postcompact-fallback`. Code writes frontmatter, marker and sentinel; a model never types them.

## 9. Locations

- Bucket `<handoff_root>/<repo>/<ticket-or-topic>/` (default root `~/.claude/handoffs`). Handoffs at its top level, named `YYYY-MM-DD_HH-MM-SS_<sid8>_<slug>.md`; readers order by frontmatter `date`.
- Copies: `compact/`, `compact/subagents/`, `compact/unattributed/`, names ending `-<id6>.md`.
- Evidence: `evidence/<stem>/` with `MANIFEST.tsv`. Disposable: `<disposable_root>/<YYYY-MM-DD>/<stem>-evidence/`.
- Sessions: pins `.sessions/<sid>.json`; lineage `.sessions/<sid>.lineage.json`; per-process records `.sessions/by-pid/<pid>-<lstart>.live-<sid8>.json` and `.ended-<sid8>.json`; approval-line hashes `.sessions/approvals/<sid>.<nonce>.json` (written once by `publish`); successor claims `.sessions/successors/<sid>.json` (written once by `pin`).
- Watch tree `<log_dir>` (default `<root>/.watch`): `<sid>.jsonl`, `<sid>/events/`, `<sid>.classic.jsonl`, `<sid>.alerts.jsonl`, `<sid>/compactions.jsonl`, `<sid>/mod-alive.json`, `<sid>/bg/slot-<k>.json`, `heal/<origin sid>/<item>.count`.

## 10. Secret rule set

One rule set for evidence copies, summary copies, drafts and recipes. Rule ids are printed and logged, never values.

- **Denied by name** → `withheld` (never scanned, never copied): `.env*` except `.example`, `.sample`, `.template` and `.dist` files; private keys; `.netrc`; `.npmrc`; `.claude.json`; `.credentials.json`; shell history; `*.har`; `*.sqlite`; `*.heapsnapshot`. Regular files only.
- **HARD**: provider key prefixes, PEM blocks, JWTs, `Bearer`/`Basic` headers, `scheme://user:pass@host` URLs.
- **WARN**: `password=`, `secret=`, `token=`, `key=` pairs; prefix-less 40-character cloud keys; base64 runs of 32 or more characters with entropy of at least 4.0 bits per character; cookies.
- **Actions**: a log or JSON file with any hit → a `redacted` copy keeping the original sha256; other files: a HARD hit → `withheld`, a WARN hit → a `redacted` copy; a shell or monitor job's output only as a redacted head/tail excerpt of ≤80 lines; a summary with a HARD hit → a redacted copy; in a draft or recipe a HARD hit blocks publishing and a WARN hit is an advisory with its rule ids.
- **One marker per secret (BD-2)**: every rule runs on the original text. Overlapping or touching hits merge into one span, which is replaced once by `[redacted:<rule>]`, labelled by the first rule in the `secret_rules` list (the most specific: `Authorization: Bearer <JWT>` → `Authorization: [redacted:jwt]`).
- **Agent output is always withheld (BD-4)**: a `tasks/<id>.output` is withheld (`rules: agent-output`) when any of these holds: (a) its real path is a transcript or session JSONL (the never-copy gate); (b) the sidecar or a job record lists task `<id>` with a type other than `shell` or `monitor` (`subagent`, `workflow` or another non-shell type); (c) its first non-empty line parses as a transcript row (a JSON object with `type` and `sessionId` or `parentUuid`). Otherwise (a shell or monitor job's own output) it is a redacted head/tail excerpt of ≤80 lines.
- **Clone patches (BD-1)**: for each local commit (≤50) and for the uncommitted diff, the helper lists every touched path (`git diff-tree -r --root --no-commit-id -z --name-status -M -C <sha>`; uncommitted: `git diff HEAD -z --name-status -M -C`). A path is **blocked** when the name gate refuses it (deny names, `never_copy`, and the user's `NAME:` rules if `secret_extra_rules` is adopted); for a rename or copy, both sides are blocked when either side is. If nothing is blocked, the patch is built as before. Otherwise it is rebuilt **without the blocked paths** (`git format-patch --stdout --no-renames -1 <sha> -- . ':(top,literal,exclude)<path>'…`; uncommitted: `git diff HEAD --binary --no-renames -- . <same excludes>`), argv only, no shell. **Fail-closed check:** `git apply --numstat -z` over the rebuilt bytes must list exactly the touched paths minus the blocked ones; a blocked path in that list, a mismatch or any git error → the whole patch is withheld (`rules: exclude-failed`). A rebuilt patch then goes through the caps and this rule set like any patch (a HARD hit in the text, commit message included → withheld). It is written as `<nnnn>-<sha8>.partial.patch`, its MANIFEST `meaning` is `partial patch: <k> path(s) left out`, and its evidence row label carries `partial (<k> withheld)`. Each blocked path gets one row: `status withheld`, `scan withheld`, `origin <top>#<sha8>:<path>` (or `#uncommitted:<path>`), `rules deny-name` or `rename-from-denied`, no bytes, no hash. A commit whose touched paths are all blocked gets only the withheld rows and no patch file. A partial patch is evidence for reading: applying it would recreate a commit without those files, so a resume never applies it (Dev-5), and the handoff's evidence line says "partial".

## 11. Clutter classes (lint and watcher; flag only)

Absolute-path lines · code blocks over 5 lines · log, warning and stack lines · arithmetic lines · 4 or more consecutive hash lines · temp paths (`/tmp`, `/private/tmp`, `/var/folders`, `$TMPDIR`, scratchpads, background-task outputs).

## 12. Outward and destructive classes

`env-write` · `infra-write` · `push` · `force-push` · `mr-write` · `http-write` · `deploy` · `publish` · `history-rewrite` · `recursive-delete` · `mcp-write`. A command in one of these classes needs a fresh ask unless an own-chain approval covers it (§4 **Approval (scoped)**). `deploy`, `env-write`, `infra-write`, `prod-write` and `protected-push` are explicit gates: always a fresh ask. `env-write` (a change to an environment's settings or secrets) is checked before `infra-write` (infrastructure), and both before `deploy`: the first of the three that matches names the command. `protected-push` is a `push` or `force-push` whose destination branch (the explicit refspec, else the current branch) is the remote's default branch or, lower-cased, matches `protected_branch_re` (`main`, `master`, `trunk`, `develop`, `stable`, `staging`, `gh-pages`, `prod`/`production` and their `-`, `_` or `/` children, `release`/`releases` and theirs, `hotfix/*`), or matches an entry of the user's `protected_branches` setting (names or globs, lower-cased; the setting only adds to this list, never removes from it).

**Production classes** (`prod_classes`, helper only): `prod-token` matches a `prod`, `production` or `prd` token (`--context=prod-eu`, `db.prod.example.com`, `AWS_PROFILE=production`, `--profile prd`; not `product` or `produce`). The user's `prod_patterns` add to it, never replace it. A production match that is read-only is `prod-read`, any other is `prod-write`; a production match always outranks an allowlist match. A false hit costs one question, the safe direction.

## 13. Alert texts

Fixed per rule; no user content. Shown as `afk-compact watcher: <text> (<alert_id>)`.

**First-run notice** (`notice`): shown once per install at the first main session start, then again only when its `id` changes (the `-1` is the notice version; it is bumped when what is logged changes in a way a user would care about). Fixed text, at most 200 characters, no user content: `afk-compact: local compaction logs are on (content-free; nothing is sent). To share them: /afk-compact:report. To turn them off: set watcher to off in /config.`

| Rule | Text |
|---|---|
| A-01 | summary copy missing |
| A-02 | unshaped or truncated shaped compaction |
| A-03 | scope leak |
| A-04 | fabricated check lines |
| A-05 | compaction outside the band |
| A-06 | cold large compaction |
| A-07 | thrash |
| A-08 | nudge unresolved |
| A-09 | ledger loss |
| A-10 | summary growth |
| A-11 | stalled background item |
| A-12 | outward action without consent |
| A-13 | session-id canary |
| A-14 | slow resume |
| A-15 | version, arm or hook-surface change |
| A-16 | afk-compact: the plugin's compaction hook was skipped by a managed plugin (possibly in a subagent); the classic hooks shaped and saved it. |
| A-17 | failed or blocked compaction |
| A-18 | auto-continue stopped |
| A-19 | auto-continue cap breached |
| A-20 | workflow stopped after compaction |
| A-21 | secret-shaped content in a summary or copy |
| A-22 | heal on an unproven relation |
| A-23 | resume block missing, doubled or degraded |
| A-24 | storage growth |
| A-25 | watcher unhealthy |
| A-26 | plugin layers not running |
| A-27 | auto-continue without a nudge |
| A-28 | compaction or handoff turn read cold |
| A-29 | idle compaction not shaped |

## 14. Wait specs (Dev-7 D2, D3; DP-1, DP-14)

`<store>`: the plugin's helper. The skill or the plugin's note gives its full path. In a handoff, write `<store>`, never the path: the path changes with every plugin update, and repo exports must not carry the home folder (lint `store-path`).

`<store> wait --for <cond> [--for <cond>…] [--while <guard>…] [--max <s>] [--stall <s>] [--deadline <epoch>]`

- **cond**: `pid-exit:<pid>[@<start-epoch>]` · `file:<path>` · `marker:<path>:<perl-regex>` · `exit:<path>`. **guard**: `pid:<pid>[@<start-epoch>]` · `file:<path>`. A path holds no `:`.
- The wait is met when any `--for` holds. It ends early (exit 12) when a `--while` guard stops holding. `--max` is 0 to 7200 seconds, default 270; `--max 0` checks once and returns at once. `wait` prints its pending line only after `--max` has passed, and an unattended session ends a background command at 1800 s by default, so a main session waits with `--max 1740` (`main_max_s`).
- `exit:<path>` reads the end marker of a job: a line `__exit <n>` (`^__exit (-?[0-9]+)$`) or the runtime trailer `[exited with code <n>]` prints `rc=<n>`. The trailer `[killed]` (a TaskStop, or the tasks stopped at exit) prints `killed`: the job was killed, never finished; a killed job is asked about, never relaunched by itself.
- **End marker (DP-1):** a job you will wait on is started with `; echo "__exit $?"` at the end of its command. A relaunch replays the recorded command byte for byte, so it carries the suffix when the original did; restart text never adds it.
- **Regex limits:** a `marker` pattern longer than 200 characters, or holding `(?{`, `(??{` or `(*`, is refused with exit 64. An overrun past `--max` plus 5 seconds ends with exit 70. Core Perl code never runs from a pattern.
- **Quoting:** resume passes a handoff's spec only inside single quotes. A spec containing `'` is reported, never run.
- **One output line.** Matched text is cut to 120 characters, never the whole line.

| Exit | Meaning |
|---|---|
| 0 | `wait: done <cond> after <n>s[ rc=<n>\| killed][ line=<n> match=<text>][ note=<…>]` |
| 10 | `wait: pending after <n>s (max <m>s); run the same command again` |
| 11 | `wait: stalled <path> no growth for <n>s` (with `--stall`) |
| 12 | `wait: ended <guard> (gone\|reused\|deleted) before <cond>` |
| 13 | `wait: overdue deadline <ISO> passed` (with `--deadline`) |
| 3 | `REFUSED: <not-regular\|unreadable> <path>` |
| 64 | usage: a bad spec, a pattern that does not compile or breaks the limits, `--max` out of range |
| 70 | internal error, or the `alarm` backstop fired |

## 15. Lint rule ids

Kebab-case ids, printed as `LINT <id> <where>` (blocking: nothing is published) or `ADVISORY <id> <where>` (published). Under the first line of each id in one publish run, `publish` prints `  why: <why> · fix: <fix>` from `lint_texts` (§19). Tests and readers match the first line, which is unchanged. The template's §1–§4 carry the drafting rules; this table is the full list (moved from template §7, PR-4).

| id | class | flags |
|---|---|---|
| `headings` | blocking | a heading missing, renamed or out of order |
| `meta-in-draft` | blocking | frontmatter, marker or sentinel in the draft |
| `update-heading` | blocking | an `UPDATE` or addendum heading |
| `resume-lines` | blocking | Resume here over 5 lines |
| `step1-mismatch` | blocking | Step 1 differs from Next steps item 1 (command or edit compared) |
| `none-form` | blocking | a none-section empty without its none-form |
| `ephemeral-path` | blocking | an ephemeral path with no durable copy and not on `Volatile:` |
| `live-asof` | blocking | a Live state row without an as-of |
| `unprinted-time` | blocking | a `checked`/`verified` time the helper did not print in this run, outside carried lines |
| `time-format` | blocking | a `checked`/`verified` time that is not a whole stamp, outside carried lines |
| `id-range` | blocking | an id range |
| `carry-provenance` | blocking | a line from a foreign base without its `[from …]` tag |
| `carry-approval` | blocking | a tagged approval without `context only, not valid here; re-ask`, or with `used`/`not yet used` |
| `approval-shape` | blocking | a `## Approvals` line without quoted words, `action`, `targets`, `once`/`standing`, or a state word (`not yet used` · `used <stamp>`; a tagged foreign line or an own context-only line: `context only, not valid here; re-ask`), or a second line with the same id; or a new approval line outside `## Approvals`. The question a short answer replies to may follow the words as `(answer to "<question>")`; the quote check reads the words only. In a plugin handoff turn each of these, a malformed tagged line included, reports `approval-plugin-turn` instead |
| `approval-plugin-turn` | blocking, plugin handoff turn | an own `## Approvals` line that is not the bare context-only form (`approval_context_re`): one with `once`/`standing` or a state word, one without `context only, not valid here; re-ask`, one with the question or a denial note, a malformed tagged line (no approval shape, no quoted words or no context-only note), a second line with the same id, or a new approval line outside `## Approvals` |
| `approval-denied` | blocking, handoff the user asked for | a usable approval (`once`/`standing` and a state) whose action a call of this session, its subagents' and workflow agents' calls included, was refused for (by the auto-mode classifier, a deny rule, a denied directory, a built-in safety check or the permission mode, or the user at the prompt; not by a hook), or an approval line with a denial note that is not the context-only form. A denied call covers an approval when a distinctive word of its input (one with a digit or a `/ . : # ! @ _ -` inside: a ticket key, a branch with a slash, a path or its file name, a URL; of a Bash command only its outward step, never a heredoc body or a quoted message, unless the outward step itself sits in the quotes, as in `bash -c "git push origin feat/x"` or `ssh host "kubectl delete pod web-1"`) or a service word of an MCP tool's name stands in the approval's action or targets, or when the call names no such word and shares an outward class with it |
| `approval-quote` | blocking, own lines | the quoted words are not in a human-typed user message of this session or in the user's answer in one of its question dialogs, the line is not carried from an own-chain file that listed it in `approvals_checked`, or a quote under 4 words does not answer an assistant message naming one of its targets (as the whole message, or as one numbered line of a reply that answers the one item of the closing list naming a target, or, when no numbered item of the assistant's text names one, itself holds an outward verb of the action or a target) |
| `private-path` | blocking, repo mode | a machine-private path left after the export rewrite (`~/.claude/projects/`, a `.jsonl` under `~/.claude/`, another user's home, a `claude-*` temp path) |
| `recipe-placeholder` · `recipe-script` · `recipe-spawn` | blocking | a recipe with a placeholder; a script not in the manifest; an agent spawn without model and effort |
| `secret-hard` | blocking | a HARD secret hit in the draft or recipes |
| `queue-off` | blocking | queue mode off, and a model-typed `Queued:` line or a `· queued` question row |
| `size` · `section-cap` | advisory | over 20 KB; a section over its `section_caps` value |
| `code-block` · `log-lines` · `hash-lines` | advisory | a code block over 5 lines; log-, warning- or stack-shaped lines; 4 or more consecutive hash lines |
| `changes` · `must-read` | advisory | over 15 changes; over 3 must-read paths |
| `recipe-mismatch` | advisory | a recorded job's recipe whose `command:` differs from its record |
| `overlap` | advisory | 30% or more of non-ledger lines shared with `previous_handoff` (ledger lines, headings, none-forms and helper-pasted Evidence lines excluded) |
| `secret-warn` | advisory | a WARN secret hit (rule ids printed, never values) |
| `acuity` | advisory | Resume here has no `Acuity:` (`missing`), or a rating below the measured floor (`below <floor>`) |
| `store-path` | advisory | a body line contains `/scripts/afk-compact-store` |
| `approval-unchecked` | advisory | the session transcript could not be read or the session's start is not on record, so no quote was checked; the line is published but not listed in `approvals_checked`, and the next session treats it as context |

Receipts: `Wrote handoff to: <path>` · `REFUSED: lint (<n> blocking); draft kept at <path>` · `REFUSED: <other reason>`; repo-mode export lines as in the handoff skill's Step 7.

- `time-format`: `checked` or `[verified` followed by a time that is not a full stamp, outside carried lines.
- Carried lines, which `unprinted-time` and `time-format` skip: a line byte-identical to a line of the base or of the own chain's file, and a line with a carried-line tag whose ledger content (bullet, id and carried-line tags removed) equals that of a foreign-base line. So a foreign line keeps its `checked` and `verified` times when it is carried.
- `carry-provenance`: a `U-`, `D-` or `X-` line whose content occurs in the foreign base and not in the own base, with no carried-line tag. `carry-approval`: a tagged approval line without `context only, not valid here; re-ask`, or with `used` / `not yet used` on it.
- `approval-quote` and `approval-unchecked` (own, untagged `## Approvals` lines): the quote is matched against this session's human-typed user rows and the user's answers in its question dialogs only (not another tool result, a meta row, a compaction summary, a task notification or a plugin's prompt), with white space folded, in memory; no quote text is written anywhere. A prompt sent through `claude -p` or the Agent SDK counts as typed; the `approvals_carry` row counts carried approvals by the origin of the row that held their quote (class words, no text). A dialog answer is the result of an `AskUserQuestion` call of the main session (not a subagent's), read from the answer record Claude Code keeps beside it: the chosen option label (each label of a multi-select answer), the typed Other text, a note the user wrote or their free-text response; never the question, its header, an option's description or preview, a dismissed dialog, a selection left when the dialog timed out, or a round where the user asked for more questions; nor an answer that a hook, a rule or a classifier gave (a recorded permission decision whose source is not the user), nor a dialog whose call already held answers. Only rows this session wrote after it started count, for a typed quote, the assistant message a short one answers, and a dialog's question and answer: not a row with another session's id or `forkedFrom`, one without a time, or one timed before the session's first per-process record (a fork, a `--fork-session` resume and a background copy write the rows they copy with the new id and the parent's times); with no record the line is `approval-unchecked`. A line counts as carried when an own-chain file (`previous_handoff` with `previous_kind` `own` or `chain`, or `own_previous_handoff`, whose approvals carry by §4) has a line with the same id, words, action, targets and `once`/`standing` and lists the id in `approvals_checked`; its state may go from `not yet used` to `used <stamp>`, never back. A quote under 4 words counts only when the last assistant message before it names one of the approval's targets and the quote is the whole message (neither it nor the quote numbered), or one whole numbered line of it (`1.`, `1)`, `1:`): when any numbered item of the assistant's text (any list, also one followed by prose, a later assistant row or a code block) names a target, a line counts only when the numbered list that ends the text has exactly one item naming a target and the line has that item's number, so no line counts when two or more items name one or when any line follows the list that names it; only when no numbered item names a target (or the text has no list), a line counts when it holds an outward verb of the action (push, merge, publish, deploy, rebase, squash, amend, delete, wipe; never an object or descriptive word such as "comments", "retry", "commit" or "update") or a target. An unnumbered line of a longer message, a line holding a refusal ("no", "not", "don't", "wait", "later", "tomorrow", "pause", "abort"), and a line ending in a question mark never count, and a refusal on an unnumbered line of a numbered reply ("wait, don't push yet") makes no line of it count. A list ends the text only when no unindented line, fence line or later assistant row follows it; a list inside a code block never does; a more-indented numbered line belongs to the item above it. "1. yes" in "1. yes / 2. no" answering "1. Run the tests? 2. Push feat/x?" approves no push, alone or as a whole one-line reply; a quote written with its item number must match it; in a dialog, only when it is a whole answer and that answer's question names one of them. An approval line outside `## Approvals` that is byte-identical to a line of the own chain's file is an older carried line: it is context, never carried as an approval, and not flagged.
- `private-path` (repo mode only, fix or report): a line that still holds a machine-private path after the export rewrite of D-12 §1.5.5 (the user's home is already `~/`): `~/.claude/projects/`, a `.jsonl` file under `~/.claude/`, another user's home, or an in-flight probe path (`/private/tmp/claude-*`, `/tmp/claude-*`, `$TMPDIR/claude-*`). It may fire on the same line as `ephemeral-path`: that rule accepts a durable copy or a `Volatile:` line, this one never does, because the path would reach git.

## 16. Caps

- `call_cap` 25: the handoff skill's hard cap on tool calls (Step 1 ≤4 · Step 2 ≤11 · Step 4 ≤2 · Step 6 1 · Step 7 ≤7). `recipe_cap` 8: restart-recipe writes (Step 5) on top. The plugin handoff turn derives its own call limit from both (1 + `call_cap` + `recipe_cap`).
- The compaction text budgets (D-17, compaction-rem-6) are not here: `tools/assemble` holds them.
- `clamp` (MOD-SPEC §1.2 effective thresholds; the mod, the helper's `/status` and the watcher's fallback read these, never their own copies): native trigger = window − `native_offset` 33,000; `reserve` = `reserve_base` 52,000 + `handoff_turn_max_tokens` (held to `handoff_tokens_min` 20,000 – `handoff_tokens_max` 150,000) with `handoff_turn: halt`, else `reserve_no_handoff` 100,000; soft max = min(setting, native trigger − reserve, ⌊`soft_ratio` 0.8 × window⌋); target = min(setting, ⌊soft max × `target_num` 2 / `target_den` 3⌋); below `min_target` 120,000 plugin compactions and the nudge are off; a configured `native_window_tokens` below `window_floor` 100,000 counts as 100,000. The 2/3 is two integers because a float 2/3 gives 119,999 at soft max 180,000.

## 17. Evidence rules (helper)

Moved from the template §5 (PR-4). The helper enforces all of it, and the template keeps the evidence-choice rules.
- **Caps.** Copy files ≤10 MB; bigger ones are `ref-only` (bytes, sha256, mtime, regeneration command, ≤40 head/tail lines of text). At most `evidence_total_max_mb` (default 50 MB) per handoff or sweep; a file past it is `withheld` (`rules: over-total`) and stays where it is. Dedupe by sha256 across buckets (`dup`); a bucket whose `evidence/` and `compact/` folders together exceed `evidence_quota_mb` gets a warning.
- **Where.** Needed later → `<handoff root>/<repo>/<bucket>/evidence/<stem>/`. Disposable → `<disposable root>/<YYYY-MM-DD>/<stem>-evidence/`, today's folder only, with a retention note from `disposable_keep_days` ("kept until you remove it" when unset). Defaults `~/.claude/handoffs` and `~/.claude/trash-staging`. Never in a git repository, `.planning/` or a temp folder.
- **Copy-time secret gate**: §10, applied before each copy. Modes: umask 077; folders 0700, files 0600.
- **Manifest** `MANIFEST.tsv`: the `manifest_columns` and `manifest_scan` literals; recipes, `ledger.md` and `inflight.md` included. Order: copy, re-hash, manifest, publish by exclusive create, receipt.

## 18. Identity, file name and lock (helper)

Moved from the template §6 (PR-4).
- **Identity** = full `session_id` + actor, from the plugin's per-process session record, cross-checked against the id the skill passes (mismatch → `begin` prints `identity: degraded (<reason>)` and the writer copies it under Ownership (template §6); none → random token, never a shared name). Compaction and `--resume` keep it; `/clear`, fork and background copies get a new one, linked by `previous_session_id` and `lineage_reason`. A new session that resumes another session's handoff is linked `handoff-resume` by `pin` (resume R4) only when it started fresh (startup or resume) with no link yet, the handoff is the predecessor's newest in the private store, the predecessor has ended and not by `/clear`, and no other session claimed that predecessor (`.sessions/successors/<sid>.json`, exclusive create); otherwise it stays `other`. `transcript_path` locates, never keys.
- **Name** `YYYY-MM-DD_HH-MM-SS_<sid8>_<slug>.md`, local time; readers order by frontmatter `date`, never by name or mtime; `-2` on a clash; `-a<agent8>` only with an agent id known to code. Only the main session writes (template §8).
- **Lock.** Publishing is an exclusive create with no lock; a published file is never rewritten. The one lock guards the helper's read-modify-write of `.sessions/<sid>.json` (bucket, lane, worktree): owner = sid + actor + pid + process start time + host; stale only when that pid is gone or its start time differs (then taken over and logged); a live lock is never broken.
- **Ownership** is checked before the first write to anything shared (foreign commits, a newer foreign handoff, a lane held elsewhere, another live session on the checkout): read-only there, recorded under Ownership. Never edit or delete another session's files.

## 19. Machine-readable literals

Patterns use the subset that both Perl and JavaScript read the same way: no flags, so letter case is spelled out in classes. A rule with `min_entropy` also needs the match's Shannon entropy (bits per character) at or above that value. A clutter class with `max_lines` flags a fenced block longer than that; one with `min_run` flags that many consecutive matching lines. `copy_trailers` lists engine trailers after a summary body that the normalizer cuts; none is known for the tested version.

```json spec-literals
{
  "spec_version": 2,
  "title_prefix": "# ",
  "sections_main": [
    "## Resume here",
    "## User constraints",
    "## Approvals",
    "## Decisions and do-not-re-raise",
    "## In flight",
    "## Live state",
    "## Open questions",
    "## Location",
    "## Work done and findings",
    "## Evidence",
    "## Next steps"
  ],
  "sections_location": [
    "### GSD",
    "### Environment",
    "### Guards in force",
    "### Ownership"
  ],
  "sections_subagent": [
    "## Task as assigned",
    "## Constraints from the parent",
    "## Report",
    "## Done",
    "## Findings",
    "## Produced but not yet delivered",
    "## Own background tasks",
    "## Next action"
  ],
  "section_ids": {
    "## Resume here": "main:resume-here",
    "## User constraints": "main:user-constraints",
    "## Approvals": "main:approvals",
    "## Decisions and do-not-re-raise": "main:decisions",
    "## In flight": "main:in-flight",
    "## Live state": "main:live-state",
    "## Open questions": "main:open-questions",
    "## Location": "main:location",
    "## Work done and findings": "main:work-done",
    "## Evidence": "main:evidence",
    "## Next steps": "main:next-steps",
    "## Task as assigned": "sub:task",
    "## Constraints from the parent": "sub:parent-constraints",
    "## Report": "sub:report",
    "## Done": "sub:done",
    "## Findings": "sub:findings",
    "## Produced but not yet delivered": "sub:undelivered",
    "## Own background tasks": "sub:background-tasks",
    "## Next action": "sub:next-action"
  },
  "marker_re": "^⟪afk-compact v1 n=([0-9a-f]{8}) s=(main|sub|manual)⟫$",
  "sentinel_re": "^⟪/afk-compact n=([0-9a-f]{8})⟫$",
  "instr_marker_re": "⟪afk-compact v1 n=([0-9a-f]{8}) s=(main|sub)⟫",
  "marker_window_lines": 5,
  "sentinel_window_nonblank_lines": 3,
  "wrappers": {
    "head_line_prefix": "This session is being continued",
    "tools_block_open": "<tools-used-before-summary>",
    "tools_block_close": "</tools-used-before-summary>",
    "reminder_block_open": "<system-reminder>",
    "reminder_block_close": "</system-reminder>",
    "summary_line": "Summary:",
    "summary_open": "<summary>",
    "summary_close": "</summary>"
  },
  "copy_trailers": [
    "^If you need specific details from before compaction \\(",
    "^Continue the conversation from where it left off without asking",
    "^The messages after this summary are the most recent messages from before compaction"
  ],
  "verdicts": ["stale", "scope-leak", "unshaped", "truncated", "ok-trailer", "ok"],
  "ok_verdicts": ["ok", "ok-trailer"],
  "scopes": ["main", "sub", "manual"],
  "status_words": ["working", "finished", "hard-blocked", "soft-blocked", "active", "blocked", "waiting-owner", "waiting-job", "done"],
  "acuity_words": ["stable", "watch", "unstable"],
  "acuity_re": "(?:^|· )Acuity: (stable|watch|unstable)\\b",
  "ladder": ["proposed", "queued", "implemented", "tested", "committed", "pushed", "in review", "merged", "deployed", "published", "installed"],
  "claim_tags": {
    "verified_re": "\\[verified [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}: [^\\]]+\\]",
    "unverified": "[unverified]",
    "inherited_re": "\\[inherited: [^\\]]+\\]",
    "superseded_re": "Superseded: [UDXQB]-[0-9]+ by [UDXQB]-[0-9]+ \\([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}\\)"
  },
  "live_state_tags": ["measured", "verified", "unverified", "inherited"],
  "time_re": "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}",
  "time_legacy_re": "([0-9]{2}-[0-9]{2} )?[0-9]{2}:[0-9]{2}",
  "id_prefixes": {"U": "user constraint, approval or ask", "D": "decision", "X": "rejected, refuted or failed", "Q": "question", "B": "in-flight row"},
  "id_range_re": "\\b[UDXQB]-[0-9]+(\\.\\.|–|—)([UDXQB]-)?[0-9]+\\b",
  "question_owners_re": "^(next-agent|user|external:.+|bg:B-[0-9]+)$",
  "question_raised_by": ["user", "agent", "external"],
  "question_status_re": "^(unasked|asked [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}|timed out|no answer \\(.+\\)|answered: .+)$",
  "restart_classes": ["auto", "ask", "never"],
  "kinds": ["agent", "teammate", "workflow", "monitor", "cron", "shell", "server", "peer", "external"],
  "dies_on": ["/clear", "exit", "7-day expiry", "nothing"],
  "frontmatter_status": ["in-progress", "blocked", "completed"],
  "lineage_reasons": ["clear", "fork", "bg-copy", "handoff-resume", "none"],
  "relations": ["same-session", "successor", "other", "unselected"],
  "integrity": ["ok", "possibly truncated", "legacy", "unshaped", "s=sub"],
  "lane_re": "^(lane|auto):[A-Za-z0-9._/-]+$",
  "lane_adopt_re": "^lane:[A-Za-z0-9._/-]+$",
  "none_forms_handoff": {
    "## User constraints": ["^none stated$"],
    "## In flight": ["^Nothing in flight — checked [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4} via .+$", "^Nothing in flight known \\(not checked\\)$"],
    "## Live state": ["^none beyond git — checked [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}$"],
    "## Open questions": ["^none$"]
  },
  "none_forms_compaction": {
    "## User constraints": ["^none stated$"],
    "## In flight": ["^Nothing in flight as of the last message \\(not checked\\)$"],
    "## Live state": ["^none beyond git \\(not checked\\)$"],
    "## Open questions": ["^none$"],
    "## Own background tasks": ["^none \\(not checked\\)$"]
  },
  "inflight_table_columns": ["B-n · runtime id", "kind · what · owner", "due · watched (last probe)", "probe", "on finish", "dies on", "restart"],
  "inflight_compact_row_re": "^-? ?B-[0-9]+ \\S+ · ",
  "inflight_max_rows": 8,
  "more_handoff_re": "^\\+[0-9]+ more: B-[0-9]+(, B-[0-9]+)*; see evidence/[^ ]+/inflight\\.md$",
  "more_compaction_re": "\\+[0-9]+ more: B-[0-9]+(, B-[0-9]+)*",
  "recipe_path": "<bucket>/evidence/<stem>/restart/<B-n>.md",
  "fold_line_re": "^(- )?([DX]-[0-9]+(, [DX]-[0-9]+)*) settled; full text in (\\S+)$",
  "frontmatter_keys_handoff": ["kind", "writer", "nonce", "date", "session_id", "actor", "previous_session_id", "lineage_reason", "transcript_path", "claude_pid", "cc_version", "repository", "bucket", "worktree", "branch", "git_commit", "status", "ticket", "queue_lane", "previous_handoff", "previous_kind", "own_previous_handoff", "imported_from", "approvals_checked", "requested_by", "gsd"],
  "frontmatter_keys_copy": ["kind", "writer", "nonce", "date", "session_id", "actor", "previous_session_id", "lineage_reason", "transcript_path", "claude_pid", "cc_version", "repository", "bucket", "bucket_source", "worktree", "branch", "git_commit", "status", "queue_lane", "previous_handoff", "trigger", "compaction_seq", "tokens_before", "tokens_after", "verdict", "channel", "seat_state", "evidence", "redacted"],
  "frontmatter_keys_export": ["kind", "writer", "nonce", "date", "session_id", "actor", "previous_session_id", "lineage_reason", "cc_version", "repository", "bucket", "branch", "git_commit", "status", "ticket", "queue_lane", "previous_handoff", "gsd", "export"],
  "export_value": "repo",
  "previous_kinds": ["own", "chain", "foreign"],
  "carry": {
    "tag_re": "\\[from [0-9a-f]{8} · ([UDX]-[0-9]+|-) · [^\\]]+\\]",
    "foreign_approval_note": "context only, not valid here; re-ask"
  },
  "call_cap": 25,
  "recipe_cap": 8,
  "section_caps": {"## Resume here": 1500, "## User constraints": 1500, "## Approvals": 1000, "## Decisions and do-not-re-raise": 2200, "## In flight": 2000, "## Live state": 1200, "## Open questions": 2000, "## Location": 1000, "## Work done and findings": 1800, "## Evidence": 600, "## Next steps": 1000},
  "lint_texts": {
    "headings": {"why": "readers find sections by their literal heading, in this order", "fix": "use the template §4 headings unchanged and in order; omit only an empty section without a none-form"},
    "meta-in-draft": {"why": "frontmatter, marker and sentinel come from code; typed ones break detection", "fix": "delete them from body.md; start at the # title"},
    "update-heading": {"why": "a handoff is rewritten, never appended", "fix": "fold the update into the sections and drop the heading"},
    "resume-lines": {"why": "the next session reads Resume here first; more lines bury Step 1", "fix": "keep the four §4.1 lines; move detail to its section"},
    "step1-mismatch": {"why": "two versions of the next action make the next session guess", "fix": "make Next steps item 1 the same command or edit as Step 1, character for character"},
    "none-form": {"why": "an empty section must say it was checked, not forgotten", "fix": "write the section's none-form from template §4"},
    "ephemeral-path": {"why": "temp paths vanish before a resume", "fix": "evidence --keep <path> and cite the durable path, or put it on Volatile: with a reason"},
    "live-asof": {"why": "a state claim without a time cannot be judged for age", "fix": "give the row an as-of from checked_at or a stamp"},
    "unprinted-time": {"why": "only a helper-printed time proves a check ran in this session", "fix": "use checked_at or a stamp time, or tag the line [unverified]"},
    "time-format": {"why": "readers compare stamps; a partial time is ambiguous", "fix": "write the whole stamp YYYY-MM-DD HH:MM +hhmm as printed"},
    "id-range": {"why": "a range hides which ids exist, so carried ids get lost", "fix": "list each id"},
    "carry-provenance": {"why": "another session's line is not this session's word", "fix": "add [from <sid8> · <their id> · <their stamp>] with the values from begin"},
    "carry-approval": {"why": "an approval carries only along your own chain, where its use is tracked; another session's approval is context", "fix": "write: context only, not valid here; re-ask, and drop used / not yet used"},
    "approval-shape": {"why": "the next session can act on an approval only when it can check its scope", "fix": "write the user's words, any (answer to \"<question>\"), the action, each target with its state, once or standing, and not yet used or used <stamp>"},
    "approval-quote": {"why": "only the user's own words can approve an action", "fix": "quote the user exactly, or move the item to Open questions as ask user"},
    "approval-plugin-turn": {"why": "the plugin asked for this handoff, not the user, so an approval in it must not read as usable", "fix": "write each as U-n: approval \"<words>\" — action … · targets … ; context only, not valid here; re-ask (no once, state, question or note); Next step: ask user:"},
    "approval-denied": {"why": "this session was refused that action, so a usable approval for it would steer the next session back to a denied step", "fix": "write it as … · targets … ; context only, not valid here; re-ask · denied <by whom> <stamp>, and its Next step as ask user:"},
    "private-path": {"why": "in repo mode the path would reach git", "fix": "use a durable bucket path or a pointer; Volatile: does not help here"},
    "recipe-placeholder": {"why": "a recipe with <…> cannot run as written", "fix": "write the literal value, or class the row ask"},
    "recipe-script": {"why": "a restart runs only a script whose sha256 is in the manifest", "fix": "evidence --keep <script> and cite the durable path"},
    "recipe-spawn": {"why": "a spawn without model and effort runs on defaults nobody chose", "fix": "add model <id>, effort <level>"},
    "secret-hard": {"why": "the file would hold a live credential", "fix": "remove the value and say where it lives; the rule ids name the pattern"},
    "queue-off": {"why": "no queue is configured, so nothing was queued", "fix": "keep the question in full and drop the Queued: line and the · queued mark"},
    "size": {"why": "past 20 KB the next session reads less of what matters", "fix": "cut in the template §2 order"},
    "section-cap": {"why": "one section crowds out the others", "fix": "cut that section toward its template §2 cap if §2 lets you cut it; else keep it and list the advisory in the report"},
    "code-block": {"why": "code is recoverable from the repository", "fix": "point to path#Symbol; keep ≤5 lines only mid-edit"},
    "log-lines": {"why": "pasted logs push out decisions", "fix": "write the conclusion and a reproducer command"},
    "hash-lines": {"why": "hash lists are recoverable from git", "fix": "write the commit range <base>..<head>"},
    "changes": {"why": "past 15 the list stops ranking", "fix": "keep the top 15 by importance; the commit range covers the rest"},
    "must-read": {"why": "more than 3 must-reads means none is", "fix": "keep the 3 that Step 1 needs"},
    "overlap": {"why": "a copied previous file carries stale state", "fix": "rewrite non-ledger lines with the latest values; carry only ledger lines unchanged"},
    "recipe-mismatch": {"why": "a recorded job is relaunched only byte for byte", "fix": "copy command: from the job record, or class the row ask"},
    "secret-warn": {"why": "a value that looks secret may leak", "fix": "take it out and say where it lives, or report the rule ids"},
    "acuity": {"why": "the next session sets its check depth from Acuity; a rating below the measured facts under-checks", "fix": "add Acuity: to the Status line, at least the floor shown (merge or rebase in progress: unstable; a running job: watch)"},
    "store-path": {"why": "the helper path changes with each plugin update and names your home folder", "fix": "write <store> instead of the path"},
    "approval-unchecked": {"why": "an unchecked approval cannot carry", "fix": "nothing to do; the next session re-asks"}
  },
  "lint_ids": {
    "blocking": ["headings", "meta-in-draft", "update-heading", "resume-lines", "step1-mismatch", "none-form", "ephemeral-path", "live-asof", "unprinted-time", "time-format", "id-range", "carry-provenance", "carry-approval", "private-path", "recipe-placeholder", "recipe-script", "recipe-spawn", "secret-hard", "queue-off", "approval-shape", "approval-quote", "approval-plugin-turn", "approval-denied"],
    "advisory": ["size", "section-cap", "code-block", "log-lines", "hash-lines", "must-read", "changes", "overlap", "recipe-mismatch", "secret-warn", "acuity", "store-path", "approval-unchecked"],
    "repo_mode_only": ["private-path"]
  },
  "private_path_classes": [
    {"id": "claude-projects", "re": "(~|\\$HOME|\\$\\{HOME\\})/\\.claude/projects/"},
    {"id": "claude-jsonl", "re": "(~|\\$HOME|\\$\\{HOME\\})/\\.claude/[^\\s'\"`]*\\.jsonl"},
    {"id": "other-home", "re": "(/[U]sers/[^/\\s'\"`]+/|/[h]ome/[^/\\s'\"`]+/|[A-Za-z]:\\\\{1,2}[U]sers\\\\{1,2}[^\\\\\\s'\"`]+\\\\)"},
    {"id": "probe-tmp", "re": "(/private/tmp/claude-|/tmp/claude-|\\$TMPDIR/claude-|\\$\\{TMPDIR\\}/claude-)"}
  ],
  "wait": {
    "cond_res": {
      "pid-exit": "^pid-exit:([0-9]+)(@([0-9]+))?$",
      "file": "^file:([^:]+)$",
      "marker": "^marker:([^:]+):(.+)$",
      "exit": "^exit:([^:]+)$"
    },
    "guard_res": {
      "pid": "^pid:([0-9]+)(@([0-9]+))?$",
      "file": "^file:([^:]+)$"
    },
    "max_default_s": 270,
    "max_range_s": [0, 7200],
    "main_max_s": 1740,
    "subagent_bash_timeout_ms": 300000,
    "marker_regex_max_chars": 200,
    "marker_regex_forbidden": ["(?{", "(??{", "(*"],
    "alarm_slack_s": 5,
    "match_text_max_chars": 120,
    "first_scan_max_bytes": 268435456,
    "exit_codes": {"done": 0, "refused": 3, "pending": 10, "stalled": 11, "ended": 12, "overdue": 13, "usage": 64, "internal": 70},
    "exit_markers": [
      {"id": "echo", "re": "^__exit (-?[0-9]+)$", "active": true},
      {"id": "runtime", "re": "^\\[exited with code (-?[0-9]+)\\]$", "active": true},
      {"id": "killed", "re": "^\\[killed\\]$", "active": true, "means": "killed"}
    ],
    "end_suffix": "; echo \"__exit $?\"",
    "inflight_probe_cmd": "<store> wait --for <spec> --max 0"
  },
  "frontmatter_kinds": ["handoff", "compact-summary", "subagent-summary"],
  "writers": ["handoff", "mod", "postcompact-fallback"],
  "evidence_statuses": ["copied", "dup", "ref-only", "redacted", "withheld", "missing"],
  "manifest_columns": ["copy_path", "origin", "bytes", "sha256", "mtime", "copied_at", "mode", "scan", "regen_cmd", "meaning"],
  "manifest_scan": ["full", "excerpt", "ref-only", "withheld", "redacted"],
  "receipts": {
    "wrote": "Wrote handoff to: ",
    "refused_lint_re": "^REFUSED: lint \\([0-9]+ blocking\\); draft kept at .+$",
    "refused_re": "^REFUSED: .+$"
  },
  "secret_rules": [
    {"id": "pem", "class": "HARD", "re": "-----BEGIN ([A-Z0-9 ]+)-----(?:(?:(?!-----BEGIN )[\\s\\S])*?-----END \\1-----|(?:(?:\\r?\\n|(?:\\\\r)?\\\\n)[ \\t]*(?:[A-Za-z0-9+/=]+|(?:Proc-Type|DEK-Info|Version|Comment|Hash|Charset): [^\\r\\n\\\\\"]*)?(?=[\\r\\n\\\\\"']|$))*)"},
    {"id": "aws-key-id", "class": "HARD", "re": "\\b(AKIA|ASIA)[0-9A-Z]{16}\\b"},
    {"id": "github-token", "class": "HARD", "re": "\\bgh[pousr]_[A-Za-z0-9]{36,}"},
    {"id": "github-pat", "class": "HARD", "re": "\\bgithub_pat_[A-Za-z0-9_]{50,}"},
    {"id": "gitlab-token", "class": "HARD", "re": "\\bglpat-[A-Za-z0-9_-]{20,}"},
    {"id": "slack-token", "class": "HARD", "re": "\\bxox[abposr]-[A-Za-z0-9-]{10,}"},
    {"id": "anthropic-key", "class": "HARD", "re": "\\bsk-ant-[A-Za-z0-9_-]{20,}"},
    {"id": "openai-key", "class": "HARD", "re": "\\bsk-(proj-)?[A-Za-z0-9]{20,}"},
    {"id": "google-api-key", "class": "HARD", "re": "\\bAIza[0-9A-Za-z_-]{35}"},
    {"id": "stripe-key", "class": "HARD", "re": "\\b[rs]k_live_[A-Za-z0-9]{20,}"},
    {"id": "npm-token", "class": "HARD", "re": "\\bnpm_[A-Za-z0-9]{36}\\b"},
    {"id": "jwt", "class": "HARD", "re": "\\beyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"},
    {"id": "auth-header", "class": "HARD", "re": "\\b([Bb]earer|[Bb]asic)[ \\t]+[A-Za-z0-9._~+/-]{16,}=*"},
    {"id": "url-userinfo", "class": "HARD", "re": "\\b[A-Za-z][A-Za-z0-9+.-]*://[^/\\s:@]*:[^/\\s@]+@[^/\\s]+"},
    {"id": "key-value", "class": "WARN", "re": "([Pp][Aa][Ss][Ss]([Ww][Oo][Rr][Dd]|[Ww][Dd])?|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Kk][Ee][Yy])[\"']?[ \\t]*[=:][ \\t]*[\"']?[^\\s\"',;]{6,}"},
    {"id": "cloud-key-bare", "class": "WARN", "re": "(^|[^A-Za-z0-9/+])(?=[A-Za-z0-9/+]{0,39}[A-Z])(?=[A-Za-z0-9/+]{0,39}[a-z])(?=[A-Za-z0-9/+]{0,39}[0-9])[A-Za-z0-9/+]{40}($|[^A-Za-z0-9/+=])"},
    {"id": "high-entropy", "class": "WARN", "re": "(^|[^A-Za-z0-9+/])(?=[A-Za-z0-9+/]{0,200}[0-9])(?=[A-Za-z0-9+/]{0,200}[A-Z])(?=[A-Za-z0-9+/]{0,200}[a-z])[A-Za-z0-9+/]{32,}={0,2}", "min_entropy": 4.0},
    {"id": "cookie", "class": "WARN", "re": "([Ss]et-)?[Cc]ookie\\\\?[\"']?[ \\t]*:[ \\t]*(\\\\?[\"'\\[][ \\t]*)*([^=\\s;\"'\\\\]+=\\\\?\"?[^;\\s\"'\\\\]*(\\\\?\")?;[ \\t]*)*[^=\\s;\"'\\\\]+=\\\\?\"?[^;\\s\"'\\\\]{8,}((\\\\?\")?;[ \\t]*[^=\\s;\"'\\\\]+=\\\\?\"?[^;\\s\"'\\\\]*)*"}
  ],
  "deny_names": {
    "globs": [".env*", "*.pem", "*.key", "*.p12", "*.pfx", "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*", ".netrc", ".npmrc", ".claude.json", ".credentials.json", ".bash_history", ".zsh_history", ".sh_history", "fish_history", "history.jsonl", "*.har", "*.sqlite", "*.sqlite3", "*.heapsnapshot"],
    "except_globs": [".env.example", ".env.sample", ".env.template", ".env.dist", ".env.*.example", ".env.*.sample", ".env.*.template", ".env.*.dist"]
  },
  "log_like_globs": ["*.log", "*.json", "*.jsonl", "*.ndjson", "*.output"],
  "clutter_classes": [
    {"id": "abs-path-line", "re": "^[ \\t]*([-*][ \\t]+)?(/|~/)[^ \\t]+[ \\t]*$"},
    {"id": "code-block", "re": "^[ \\t]*(```|~~~)", "max_lines": 5},
    {"id": "log-line", "re": "^[ \\t]*(\\[?[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}|\\[?(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|CRITICAL)\\]?[ :])"},
    {"id": "stack-line", "re": "^([ \\t]+at [^ ]+.*[(:][0-9]+|[ \\t]*File \"[^\"]+\", line [0-9]+|Traceback \\(most recent call last\\)|[ \\t]*(from )?[^ \\t]+\\.[a-z]+:[0-9]+:in )"},
    {"id": "arithmetic-line", "re": "^[ \\t]*([-*][ \\t]+)?[0-9][0-9.,_]*([ \\t]*[-+*/×x÷][ \\t]*[0-9][0-9.,_]*)+[ \\t]*=[ \\t]*[-+]?[0-9]"},
    {"id": "hash-run", "re": "^[ \\t]*([-*][ \\t]+)?`?[0-9a-f]{7,64}`?([ \\t]|$)", "min_run": 4},
    {"id": "tmp-path", "re": "(^|[\\s'\"(=:`])(/tmp/|/private/tmp/|/var/folders/|/private/var/folders/|\\$TMPDIR/|\\$\\{TMPDIR\\}/|[^\\s'\"`]*/scratchpad/|[^\\s'\"`]*/tasks/[^/\\s'\"`]+\\.output)"}
  ],
  "outward_classes": [
    {"id": "env-write", "re": "\\b(gh|glab)[ \\t]+(secret|variable)[ \\t]+(set|delete|remove)\\b|\\bheroku[ \\t]+config:(set|unset)\\b|\\bvercel[ \\t]+env[ \\t]+(add|rm)\\b|\\bfly(ctl)?[ \\t]+secrets[ \\t]+(set|unset|import)\\b|\\bkubectl[ \\t]+(create|delete)[ \\t]+(secret|configmap)\\b|\\baws[ \\t]+(ssm[ \\t]+(put|delete)-parameter|secretsmanager[ \\t]+(create|put|update|delete)-secret(-value)?)\\b"},
    {"id": "infra-write", "re": "\\b(terraform|tofu)[ \\t]+(apply|destroy|import|state[ \\t]+(rm|mv|push))\\b|\\bpulumi[ \\t]+(up|destroy)\\b|\\bkubectl[ \\t]+(apply|create|delete|patch|replace|scale|rollout|set|edit|drain|cordon|uncordon|taint)\\b|\\bhelm[ \\t]+(install|upgrade|uninstall|rollback)\\b|\\baws[ \\t]+cloudformation[ \\t]+(deploy|create-stack|update-stack|delete-stack)\\b"},
    {"id": "push", "re": "\\bgit\\b.*\\bpush\\b"},
    {"id": "force-push", "re": "\\bgit\\b.*\\bpush\\b.*(--force|--force-with-lease|[ \\t]-[A-Za-z]*f\\b|[ \\t]\\+[^ \\t]+)"},
    {"id": "mr-write", "re": "\\b(gh[ \\t]+(pr|issue)[ \\t]+(create|merge|close|reopen|comment|edit|review|ready)|glab[ \\t]+(mr|issue)[ \\t]+(create|merge|close|reopen|note|update|approve))\\b"},
    {"id": "http-write", "re": "\\b(curl\\b.*([ \\t](-X|--request)[ \\t]*(POST|PUT|PATCH|DELETE)\\b|[ \\t](-d|--data[a-z-]*|-F|--form|-T|--upload-file)\\b)|wget\\b.*--(post|method)|gh[ \\t]+api\\b.*([ \\t](-X|--method)[ \\t]*(POST|PUT|PATCH|DELETE)|[ \\t](-f|-F|--field|--raw-field|--input)\\b))"},
    {"id": "deploy", "re": "\\b(deploy|kubectl[ \\t]+(apply|create|delete|patch|replace|rollout|scale|set|edit)|helm[ \\t]+(install|upgrade|uninstall|rollback)|terraform[ \\t]+(apply|destroy|import)|tofu[ \\t]+(apply|destroy))\\b"},
    {"id": "publish", "re": "\\b((npm|yarn|pnpm)[ \\t]+publish|gem[ \\t]+push|twine[ \\t]+upload|cargo[ \\t]+publish|docker[ \\t]+push|gh[ \\t]+release[ \\t]+(create|upload|edit))\\b"},
    {"id": "history-rewrite", "re": "\\bgit\\b.*\\b(rebase|filter-branch|filter-repo|commit[ \\t]+.*--amend|reset[ \\t]+.*--hard|update-ref[ \\t]+-d)\\b"},
    {"id": "recursive-delete", "re": "\\b(rm[ \\t]+(-[A-Za-z]*[rR][A-Za-z]*|--recursive)\\b|find\\b.*[ \\t]-delete\\b|git[ \\t]+(.*[ \\t])?clean\\b|rsync\\b.*--delete)"},
    {"id": "mcp-write", "re": "^mcp__.+__([A-Za-z]+_)?([Cc]reate|[Uu]pdate|[Dd]elete|[Rr]emove|[Pp]ost|[Ss]end|[Mm]erge|[Pp]ublish|[Ww]rite|[Aa]dd|[Ee]dit|[Cc]omment|[Tt]ransition|[Aa]pprove|[Cc]lose)"}
  ],
  "prod_classes": [
    {"id": "prod-token", "re": "(^|[^A-Za-z0-9])([Pp][Rr][Oo][Dd]|[Pp][Rr][Oo][Dd][Uu][Cc][Tt][Ii][Oo][Nn]|[Pp][Rr][Dd])([^A-Za-z0-9]|$)"}
  ],
  "explicit_gate_classes": ["deploy", "env-write", "infra-write", "prod-write", "protected-push"],
  "protected_branch_re": "^(main|master|trunk|develop|development|stable|staging|gh-pages|prod|production|(prod|production)[/_-].+|releases?([/_-].+)?|hotfix/.+)$",
  "approval_re": "^[-*]?[ \\t]*U-([0-9]+): approval \"(.+?)\"(?: \\(answer to \".+\"\\))? — action (.+?) · targets (.+?) · (once|standing( \\([^)]*\\))?) · (not yet used|used [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4})( · given .+)?$",
  "approval_context_re": "^[-*]?[ \\t]*U-([0-9]+): approval \"(.+?)\"( \\(answer to \".+\"\\))? — action (.+?) · targets (.+?) ; context only, not valid here; re-ask( · denied [^·]+?)?( · given .+)?$",
  "risk_classes": [
    {"id": "gate", "from": "explicit_gate_classes"},
    {"id": "outward", "from": "outward_classes"},
    {"id": "production", "from": "prod_classes"},
    {"id": "credential-value", "from": "secret_rules"},
    {"id": "credential-read", "re": "(~|\\$HOME|\\$\\{HOME\\})/\\.(ssh|aws|kube|docker|gnupg|config/gh)(/|\\b)|(^|[\\s/'\\\"=])\\.env(?!\\.(example|sample|template|dist)\\b)[A-Za-z0-9_.-]*($|[\\s'\\\";|&)])|\\.(netrc|npmrc|pypirc|pgpass|git-credentials)\\b|\\b(id_rsa|id_dsa|id_ecdsa|id_ed25519)\\b|\\.(pem|key|p12|pfx|keystore|jks|p8|ppk)($|[\\s'\\\";|&)])|\\bcredentials(\\.json)?\\b|(^|[\\s/'\\\"=])\\.?[A-Za-z_]*_history\\b|\\bhistory\\.jsonl\\b|/proc/|\\.git/config\\b|\\b(security[ \\t]+find-(generic|internet)-password|op[ \\t]+(read|item[ \\t]+get)|pass[ \\t]+show)\\b"},
    {"id": "network", "re": "[A-Za-z][A-Za-z0-9+.-]*://|(^|[;&|(][ \\t]*)(sudo[ \\t]+)?([A-Za-z_][A-Za-z0-9_]*=[^ \\t]*[ \\t]+)*(curl|wget|ssh|scp|sftp|ftp|telnet|nc|ncat|socat|aws|gcloud|gsutil|az|kubectl|helm|terraform|tofu|pulumi|gh|glab|heroku|vercel|fly|flyctl|doctl|npx)\\b|\\brsync\\b[^|;&]*[ \\t][^ \\t:/]+:|\\bgit\\b[^|;&]*[ \\t](fetch|pull|push|clone|ls-remote|submodule[ \\t]+update|remote[ \\t]+update)\\b|\\bdocker[ \\t]+(pull|push|login|run|build|compose[ \\t]+(pull|up|build))\\b|\\b(npm|pnpm)[ \\t]+(install|i|ci|add|update|publish|view|info|audit|outdated)\\b|\\byarn([ \\t]+(install|add|upgrade|publish|info|audit)\\b|[ \\t]*$)|\\bpip[0-9.]*[ \\t]+(install|download)\\b|\\b(gem|bundle|bundler)[ \\t]+(install|update|push|fetch|outdated)\\b|\\bcargo[ \\t]+(install|update|publish|fetch|search)\\b|\\bgo[ \\t]+(get|install|mod[ \\t]+download)\\b|\\bbrew[ \\t]+(install|upgrade|update|fetch)\\b"},
    {"id": "opaque", "re": "'|\\$\\(|`|<\\(|>\\(|(^|[;&|(][ \\t]*)(eval|source|exec|\\.)[ \\t]|\\b(sh|bash|zsh|dash|ksh|fish)[ \\t]+-[a-z]*[cs]\\b|\\|[ \\t]*(sudo[ \\t]+)?(env[ \\t]+)?(sh|bash|zsh|dash|ksh|fish|python[0-9.]*|perl|ruby|node|php|osascript|xargs)\\b|\\bbase64[ \\t]+(-d|--decode|-D)\\b|\\bxxd[ \\t]+-r\\b|\\b(python[0-9.]*|perl|ruby|node|php)[ \\t]+-[a-zA-Z]*[ce]\\b"},
    {"id": "write-outside", "from": "code"},
    {"id": "read-outside", "from": "code"},
    {"id": "not-read-only", "from": "code"}
  ],
  "readonly_cmd_re": "^(?![^\\n]*[<>$`*?\\[])(?![^\\n]*(\\\\|[^ \\t\\n=]\\\"[^ \\t\\n]|\\\"-))(?![^\\n]*\\{[^}]*(,|\\.\\.))(?![^\\n]*(^|[ \\t=\\\"'])(~|/|\\.\\.(/|$|[ \\t\\\"'])))(git([ \\t]+-C[ \\t]+[^ \\t]+)?[ \\t]+((status|log|diff|show|blame|rev-parse|ls-files|ls-tree|describe|shortlog|grep|cat-file|show-ref|merge-base|rev-list|worktree[ \\t]+list|stash[ \\t]+list)(?![^\\n]*[ \\t][\\\"']?(-[A-Za-z0-9]*O|--output|--op|--ext-diff|--textconv|--filters|--no-index))([ \\t]|$)|reflog(?![ \\t]+(?!show\\b)[a-z])([ \\t]|$)|(branch([ \\t]+(-a|-r|-v|-vv|--list|--all|--show-current|--contains|--merged|--no-merged))*|tag([ \\t]+(-l|--list))*|remote([ \\t]+-v)?)[ \\t]*$)|(rg|grep|egrep|fgrep)(?![^\\n]*[ \\t][\\\"']?(--pre|--hostname-bin|--follow|--der|-[A-Za-z0-9]*[LRS]))([ \\t]|$)|sort(?![^\\n]*[ \\t][\\\"']?(-[A-Za-z]*o|--o|--co|--fil))([ \\t]|$)|tree(?![^\\n]*[ \\t][\\\"']?(-[A-Za-z]*[oRl]|--fromfile))([ \\t]|$)|uniq([ \\t]+-[A-Za-z0-9-]+)*([ \\t]+[^- \\t][^ \\t]*)?[ \\t]*$|file(?![^\\n]*[ \\t][\\\"']?-[A-Za-z]*C)([ \\t]|$)|date(?![^\\n]*[ \\t][\\\"']?(-[A-Za-z]*s|--s))([ \\t]|$)|(ls|du)(?![^\\n]*[ \\t][\\\"']?(-[A-Za-z0-9]*L|--der))([ \\t]|$)|diff(?![^\\n]*[ \\t][\\\"']?(-[A-Za-z0-9]*r|--rec))([ \\t]|$)|(cat|head|tail|wc|stat|pwd|which|type|df|sha256sum|shasum|md5|md5sum|cut|cmp|basename|dirname|realpath|readlink)([ \\t]|$))",
  "test_build_re": "^make[ \\t]+(?![^ \\t]*([Dd]eploy|[Rr]elease|[Pp]ublish|[Pp]ush|[Ii]nstall|[Pp]rod|[Uu]pload))(test|check|spec|lint|typecheck|build)(-fast|-unit|_unit|:unit|-quick)?([ \\t]+(-j[0-9]*|-[kqsv]+|--(keep-going|silent|quiet|verbose|trace|info|stacktrace|offline|no-daemon|continue)|V=1|VERBOSE=1))*[ \\t]*$|^((npm|pnpm|yarn)[ \\t]+run|yarn|pnpm)[ \\t]+(?![^ \\t]*([Dd]eploy|[Rr]elease|[Pp]ublish|[Pp]ush|[Ii]nstall|[Pp]rod|[Uu]pload))(test|check|spec|lint|typecheck|build)(-fast|-unit|_unit|:unit|-quick)?([ \\t]+(-j[0-9]*|-[kqsv]+|--(keep-going|silent|quiet|verbose|trace|info|stacktrace|offline|no-daemon|continue)))*[ \\t]*$|^(rake|bundle[ \\t]+exec[ \\t]+rake|gradle|\\./gradlew)[ \\t]+(?![^ \\t]*([Dd]eploy|[Rr]elease|[Pp]ublish|[Pp]ush|[Ii]nstall|[Pp]rod|[Uu]pload))(test|check|spec|lint|typecheck|build)([ \\t]+(-j[0-9]*|-[kqsv]+|--(keep-going|silent|quiet|verbose|trace|info|stacktrace|offline|no-daemon|continue)))*[ \\t]*$|^(npm|pnpm)[ \\t]+test([ \\t]+(-j[0-9]*|-[kqsv]+|--(keep-going|silent|quiet|verbose|trace|info|stacktrace|offline|no-daemon|continue)))*[ \\t]*$|^cargo[ \\t]+(test|build|check)(?![^\\n]*(^|[ \\t=/])\\.\\.(/|[ \\t]|$))([ \\t]+(-q|-v|-vv|--(quiet|verbose|release|all-targets|workspace|all|lib|bins|tests|locked|offline|frozen|no-fail-fast|all-features|no-default-features)|(-p|--package|--features|-F|--test|--bin|--example)[ \\t=]+[A-Za-z0-9_][A-Za-z0-9_,-]*|(-j|--jobs)[ \\t=]*[0-9]+|[A-Za-z0-9_][A-Za-z0-9_:]*))*([ \\t]+--([ \\t]+(--(nocapture|ignored|include-ignored|exact|quiet|show-output)|--test-threads=[0-9]+|-q|[A-Za-z0-9_][A-Za-z0-9_:]*))*)?[ \\t]*$|^go[ \\t]+(test|vet|build)(?![^\\n]*(^|[ \\t=/])\\.\\.(/|[ \\t]|$))([ \\t]+(--?(v|race|short|cover|failfast|json|x|n|a)|--?(count|timeout|parallel|cpu|p)[ \\t=]+[0-9][0-9a-z.,]*|--?(run|skip|bench)[ \\t=]+[A-Za-z0-9_^/.-]+|--?tags[ \\t=]+[A-Za-z0-9_,.]+|\\./\\.\\.\\.|(\\./)?[A-Za-z0-9_][A-Za-z0-9_./-]*))*[ \\t]*$|^(pytest|python3?[ \\t]+-m[ \\t]+pytest)(?![^\\n]*(^|[ \\t=/])\\.\\.(/|[ \\t]|$))([ \\t]+(-[qvxsl]+|-r[A-Za-z]+|--(lf|ff|nf|sw|last-failed|failed-first|new-first|stepwise|exitfirst|quiet|verbose|showlocals|no-header|strict-markers|collect-only|co)|--(tb|maxfail|durations)=[A-Za-z0-9]+|-n[ \\t]*([0-9]+|auto)|-[km][ \\t]+([A-Za-z0-9_]+|\\\"[A-Za-z0-9_ ]*\\\")|[A-Za-z0-9_.][A-Za-z0-9_./-]*(::[A-Za-z0-9_.\\[\\]-]+)*))*[ \\t]*$",
  "notice": {"id": "watcher-1", "version": 1, "text": "afk-compact: local compaction logs are on (content-free; nothing is sent). To share them: /afk-compact:report. To turn them off: set watcher to off in /config."},
  "clamp": {"native_offset": 33000, "min_target": 120000, "reserve_base": 52000, "reserve_no_handoff": 100000, "window_floor": 100000, "soft_ratio": 0.8, "target_num": 2, "target_den": 3, "handoff_tokens_min": 20000, "handoff_tokens_max": 150000},
  "alert_texts": {
    "A-01": "summary copy missing",
    "A-02": "unshaped or truncated shaped compaction",
    "A-03": "scope leak",
    "A-04": "fabricated check lines",
    "A-05": "compaction outside the band",
    "A-06": "cold large compaction",
    "A-07": "thrash",
    "A-08": "nudge unresolved",
    "A-09": "ledger loss",
    "A-10": "summary growth",
    "A-11": "stalled background item",
    "A-12": "outward action without consent",
    "A-13": "session-id canary",
    "A-14": "slow resume",
    "A-15": "version, arm or hook-surface change",
    "A-16": "afk-compact: the plugin's compaction hook was skipped by a managed plugin (possibly in a subagent); the classic hooks shaped and saved it.",
    "A-17": "failed or blocked compaction",
    "A-18": "auto-continue stopped",
    "A-19": "auto-continue cap breached",
    "A-20": "workflow stopped after compaction",
    "A-21": "secret-shaped content in a summary or copy",
    "A-22": "heal on an unproven relation",
    "A-23": "resume block missing, doubled or degraded",
    "A-24": "storage growth",
    "A-25": "watcher unhealthy",
    "A-26": "plugin layers not running",
    "A-27": "auto-continue without a nudge",
    "A-28": "compaction or handoff turn read cold",
    "A-29": "idle compaction not shaped"
  }
}
```
