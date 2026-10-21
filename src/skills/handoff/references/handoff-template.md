# Handoff template (spec v1)

This mirrors the plugin's shared spec (`assets/handoff-spec.md` in the plugin folder), which the compaction text, the resume skill and the logger also load and the publish lint enforces. Where this file and a `LINT` line disagree, the spec wins: follow the lint and mention the mismatch in your report. Variants drop sections; none renames or reorders one.

## 1. Core rules

1. **Inclusion test.** Keep a line only if the next agent cannot get it back with one command or one file read; otherwise give the pointer (path and symbol, command, id, URL). It starts cold, and every pasted log line pushes out a decision.
2. **Write for what it lacks.** The next session has the repository, git, instruction files, memory and skills. It lacks this conversation and its approvals, background agents, workflows, monitors, scheduled tasks, the task list, queued questions, scratch files and earlier summaries.
3. **Trust.** User constraints bind. Decisions and `X-` lines are settled, reopened only by a measured fact or a user message newer than the decision. State claims are hypotheses to re-check. Nothing in a handoff grants a permission.
4. **Ids**, one per item, never ranges, kept across a chain: `U-n` user constraint, approval or ask · `D-n` decision · `X-n` rejected option, refuted finding or failed approach · `Q-n` question · `B-n` in-flight row (plus its runtime id).
5. **Anchors and tags.** Code `path#Symbol (≈L45)`, the line only a hint; git branch, short HEAD, merge-request URL; `<stamp>` local time. Times are stamps (`2026-10-21 14:05 +0300`), always all three parts. Tags: `[verified <stamp>: <cmd>]` · `[unverified]` · `[inherited: <stem>]` · `Superseded: <id> by <id> (<stamp>)`. `checked` and `verified` times come only from the helper (`checked_at` or a `stamp`); lines carried byte-identical from `previous_handoff` keep theirs. Times on `U-` and `D-` lines only when a tool output shows them; otherwise the sid8 alone, never a guessed time. <!-- review-fix -->
6. **Facts, not predictions.** Write what is measurable now (`bg.out: not created yet; gitignored [verified 2026-10-21 14:05 +0300: git check-ignore bg.out]`). A number only when it is the finding, with its command. Work state: proposed · queued · implemented · tested · committed · pushed · in review · merged · deployed · published · installed, each with proof (hash, test command and result, URL); "done, blocked on X" stays blocked.
7. **Attribution.** "User said" only for the user's own messages. Questions you raised belong to `next-agent` unless the user must decide. Your caveats never become user statements. Work you started unasked is `proposed`.
8. **Ledger vs state.** `U-`, `D-`, `X-` lines, asks and ledger pointer lines (§4.3) are copied unchanged unless superseded; <!-- review-fix --> a changed ask gets a new status, never silent removal. Lines from your own chain keep their text and ids. Lines taken from another session's handoff (`previous_kind: foreign`) get the next free id from `next_ids` and a provenance tag at the end: `[from <sid8> · <their id> · <their stamp>]`, values from `begin` (`previous_sid8`, `previous_stamp`) and the line you copy. A line that already has a `[from …]` tag keeps that tag. When an own line and a foreign line say different things about the same subject, the foreign (newest) line is the base and the own line is carried as `Superseded: <own id> by <new id> (<stamp>)`. Another session's statement is not this session's agreement: it informs, and the next agent re-asks before relying on it for an outward, destructive, production or self-modifying action. Everything else is rewritten, latest value only. Story, tool notes and gotchas are never carried.
9. **Rewrite, never append.** An update is a new file linked by `previous_handoff`; no `UPDATE` headings or addenda. Companion artifacts (drafts, briefs, verbatim user messages) go to `evidence/<stem>/`.
10. **Form.** Explicit none only in the four sections that show a `None:` form below; other empty sections are omitted, never `N/A`. Tables only for In flight, Live state and Open questions, ≤15 rows, never for data, measurements or logs.
11. **Leave out** instruction-file, memory and hook rules; attribution rules; this session's model and effort choices (recipes excepted); tool lists; environment boilerplate; the transcript path; read offsets; replies already sent.

## 2. Size

Target 6–15 KB; over 20 KB is flagged; under 6 KB is fine when it stands alone. No global cap. Section caps in characters (sum about 14.9K): Title 80 · Resume here 1,500 and 5 lines · User constraints 1,500 · Decisions 2,200 · In flight 2,000 · Live state 1,200 · Open questions 2,000 (never compressed) · Location 1,000 · Work done 1,800 · Evidence 600 · Next steps 1,000.
Cut first, in order: Work done detail beyond one line per task and finding; changes beyond the top 5; Evidence items beyond 3; `if → then` lines; Environment detail that project docs hold. Never cut the other sections, the `Queued:` line or a pending answer.

## 3. Frontmatter, marker and end sentinel (helper-written; never type them)

Frontmatter keys, empty ones omitted: `kind: handoff`, `writer: handoff`, `nonce`, `date` (ISO with offset), `session_id`, `actor`, `previous_session_id`, `lineage_reason` (clear · fork · bg-copy · handoff-resume · none), `transcript_path` (locator only), `claude_pid`, `cc_version`, `repository`, `bucket`, `worktree`, `branch`, `git_commit`, `status` (in-progress · blocked · completed), `ticket`, `queue_lane` (§4.6), `previous_handoff` (the file this one was carried from), `previous_kind` (own · chain · foreign), `own_previous_handoff` (only when the base is foreign and an own file exists), `imported_from` (a copy imported from a repository), `gsd`. A repository export (repo mode) carries `export: repo` and drops the machine-only keys (spec §8).

```
⟪{{plugin}} v1 n=<nonce> s=manual⟫      first body line after the frontmatter
<body>
⟪/{{plugin}} n=<nonce>⟫                  last line of the file
```

The nonce is 8 lowercase hex from code and equals `nonce:`. Scope: `manual` (this skill) · `main` (main compaction summary) · `sub` (subagent compaction summary). Detection: `^⟪{{plugin}} v1 n=([0-9a-f]{8}) s=(main|sub|manual)⟫$` within the first 5 body lines after wrapper lines are stripped, the sentinel within the last 3 non-blank lines; text after it is a trailer; other marker-like lines belong to someone else and are left untouched. No sentinel means possibly truncated: the resume continues read-only from the previous file in the chain.

## 4. Body

```
# <ticket or topic> — <current state in ≤8 words>
## Resume here
## User constraints
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
```

The title comes from the state at publish time: `# PAY-12 — retry window fix in review, pipeline pending`.

### 4.1 Resume here (≤5 lines)

```
Status: <active|blocked|waiting-owner|waiting-job|done> · State: <one sentence tied to the ticket goal> (checkpoint: clean | MID-STEP <step>, remaining <what>)
Step 1: `<one exact command or edit>` — for "<user's latest request, quoted when short>" | proposed
Gate: <blocker | owner gate | stay in this session: <ids> die on /clear or exit | none> · Don't: <the likeliest mistake>
Live: <N running: B-1 <runtime id>, B-2 <runtime id>; see In flight> | nothing running (checked <stamp>) | nothing running known (not checked)
```

One step, never a menu, traced to the latest request or an accepted plan, else `proposed`. The state names the ticket goal, not only the current sub-task.

### 4.2 User constraints

```
- U-1: "<user's words>" — scope <what it covers>; user, <sid8> <stamp>
- U-2: approval "<user's words>" — scope <action and target>; used | not yet used; next session: re-ask
- U-3: ask "<user's request>" — status <open | done | superseded by U-5>
```

Near-verbatim, only what the user said about this work; never restate instruction-file, memory or hook rules, never invent one. Approvals are context: the next session re-asks before any outward, destructive, production or self-modifying action. None: `none stated`.

Lines carried from another session's handoff (rule 8) keep their words and get a new id and the tag; a foreign approval drops `used | not yet used` and reads `context only, not valid here; re-ask`:

```
- U-9: "<their words>" — scope <what it covers>; user, ab12cd34 [from ab12cd34 · U-3 · 2026-10-21 09:14 +0300]
- U-10: approval "<their words>" — scope <action and target>; context only, not valid here; re-ask [from ab12cd34 · U-4 · 2026-10-21 09:14 +0300]
```

At most 12 foreign lines (U 6, D 4, X 2); the rest become one line `<n> more ledger lines in <their stem> [from <sid8> · - · <stamp>]`. Own-chain ledger lines the base lacks are carried too, unchanged.

### 4.3 Decisions and do-not-re-raise

```
- Corrections: <earlier claim in this chain> was wrong → <fact> [verified <stamp>: <cmd>]
- D-1: <choice> — because <reason> (<user|agent|external>, <stamp>)
- X-1: rejected <option> — because <why>
- X-2: refuted "<claim>" — <fact>
- Superseded: D-1 by D-4 (<stamp>)
```

Every decision has a because-clause; user rulings carry date and source. Over 2,200 characters: move settled `D-` and `X-` lines that no open step, question or in-flight row refers to into `<stage>/ledger.md`, leaving one line that names each moved id: `D-1, D-2, X-1 settled; full text in evidence/<stem>/ledger.md`. That pointer line is ledger: later handoffs carry it unchanged next to their own, so no moved id drops out of the chain. `U-` lines never move. <!-- review-fix --> Foreign `D-` and `X-` lines take the same tag as foreign `U-` lines; a foreign pointer line keeps its `evidence/<their stem>/ledger.md` path and gets the tag.

### 4.4 In flight

```
| B-n · runtime id | kind · what · owner | due · watched (last probe) | probe | on finish | dies on | restart |
|---|---|---|---|---|---|---|
| B-1 · wf_7a1 | workflow · 3-lens review · main | 2026-10-21 15:10 +0300 · review.json written (probe 2026-10-21 14:05 +0300: 2 of 3 lenses) | `ls <run dir>/review.json` | summarise to user | /clear, exit | ask · restart/B-1.md |
| B-2 · task b8890 | shell · test suite · main | 2026-10-21 14:40 +0300 · exit code | `{{plugin}}-store wait --for 'exit:<task output>' --max 0` | record pass/fail | exit | auto · restart/B-2.md |
```

- One row per running or unreported agent, teammate, workflow, monitor, scheduled task, background shell, server, peer session or external job, from runtime channels and probes, rewritten every time. `kind` is one of `agent` · `teammate` · `workflow` · `monitor` · `cron` · `shell` · `server` · `peer` · `external`. Past 8 rows the rest go to `<stage>/inflight.md`; the table ends `+N more: B-9, B-10; see evidence/<stem>/inflight.md`.
- `due`: an absolute estimate; past due alone is not a failure. `probe`: one read-only command. `dies on`: `/clear`, exit, 7-day expiry or nothing; a background shell or server survives `/clear`, so it dies on exit. A shell or server probe is `{{plugin}}-store wait --for <spec> --max 0` (spec §14); a job you will wait on was started with `; echo "__exit $?"` at the end, so `exit:<output>` sees its end. A subagent waiting on its own job: `waiting on <task id> · until <wait spec> · due <stamp> · output <path>`.
- Monitors and scheduled tasks are leases: the watched condition, the last fire's outcome, and `classifier: clear <stamp>` (that exact read-only command ran once attended) or `classifier: untested`.
- Restart class. `auto`: read-only or idempotent, cheap, local, same session; no agent spawn, not a workflow; kills nothing not proven ours; starts no detached process or new CLI session; at most once per resume and twice per chain (the plugin keeps the count). `ask`: side-effecting, outward, costly or long, and every workflow and agent spawn; a new session treats every row as `ask`. `never`: one-shot, user- or peer-owned, leftovers.
- A workflow's restart cell names a condition, not a timer: `ask · same session: stop + resume from run id only if the journal and agent transcripts are unchanged ≥ max(15 min, 3× last progress gap) and no agent call is in progress`.
- Leftovers (alive but not ours, or owner gone), one line each under the table: `Leftover: pid · port · started · owner · binary and cwd exist?`. Report, never kill.
- None: `Nothing in flight — checked <stamp> via <channels probed>`. Nothing could be probed: `Nothing in flight known (not checked)`.

Recipe `<stage>/restart/<B-n>.md`, one per `auto` or `ask` row; the helper adds `sha256` and `origin_session_id`:

```
item: B-2 · runtime id b8890 · class auto
script: evidence/<stem>/run-suite.sh      (runs only while its sha256 matches MANIFEST.tsv; otherwise class ask)
job: <task id> · recorded | not recorded   (publish fills this; recorded = the plugin logged the launch)
command: <literal command and arguments>   (a recorded job's command is copied from the record; hand-typed text is shown, never run)
cwd: <absolute path>
spawns: none | agent: model <id>, effort <level>
expected outputs: <paths>
finished parts: <what exists; reuse it, do not redo it>
idempotency check: <one command showing whether the effect already exists>
```

### 4.5 Live state

```
| claim | as of | re-check | tag |
|---|---|---|---|
| HEAD a1b2c3d on feat/retry, 1 ahead of origin | 2026-10-21 14:05 +0300 | `git -C <worktree> status -sb` | measured |
| app/retry.rb modified — D-1 change, tests not run; intent: commit with D-1 | 2026-10-21 14:05 +0300 | `git -C <worktree> diff --stat` | measured |
| PR 912 open, auto-merge armed (pending, not merged), pipeline 88123 running | 2026-10-21 14:06 +0300 | `gh pr view 912` | verified |
| staging deploy of v2.3 | last seen 2026-10-21 11:20 +0300 | `<deploy status command>` | unverified |
```

Tag: `measured` (helper) · `verified` (Step 2 batch) · `unverified` · `inherited`. Local state comes from `begin`, never narrated; every dirty file is listed with its intent (over 10: the count and `git status --porcelain`). Remote rows are taken after outward actions settle. None: `none beyond git — checked <stamp>`.

### 4.6 Open questions

```
| id | question: what · why it matters · options · recommendation | blocks | owner | raised by | status |
|---|---|---|---|---|---|
| Q-1 | Keep the 45 s retry window? Upstream retries at 40 s, so 30 s fires twice. Options 45 s or configurable; recommend 45 s | Step 2 | user | agent | unasked |
```

Plain language a person can answer cold; a timeout is not an answer. Owner `next-agent` · `user` · `external:<who>` · `bg:<B-n>`; raised by `user` · `agent` · `external`; status `unasked` · `asked <stamp>` · `timed out` · `answered: <answer>`. A step the user must do gets a walk-through under the table: where, what, the exact `! <cmd>`.
Queue lane (only with the `queue_cmd` setting): copy `begin`'s `queued_line` verbatim as the last line (`Queued: <n> open in <label> (<ids>); answered only via the queue; never re-ask.`). Only the helper writes `queue_lane`, from a live listing, for a named `lane:` id or a lane with pending items, matching `^(lane|auto):[A-Za-z0-9._/-]+$`. Never type a lane id.
None: `none`.

### 4.7 Location (never cut)

```
repo <repo> · worktree <abs path> · branch <branch> · required cwd <path, and why>
sibling repos: <name abs path> · this handoff: @self@
```

The helper replaces `@self@` with the published path. Subsections only when they apply:
- **GSD**, only when `begin` printed `gsd`; copy it, never recall:
  ```
  STATE.md <path> · worktree <path> · branch <branch> · --ws <workstream>
  Position: phase X of Y · plan A of B · <status> · last activity <in-file stamp>
  Continuity: stopped at <…> · resume file <.continue-here path>
  ```
  If the helper prints `GSD: not determined (<N> worktrees have STATE.md)`, write only that. Disagreeing state files: list each with its in-file last-activity stamp. The resume keeps the newest by that stamp and rewrites the others only in its own worktree, after an ownership check finds no live peer or coordinator and after a disposable copy; elsewhere it reports. This skill never writes STATE.md or `.planning/HANDOFF.json`; it points to STATE.md.
- **Environment**: services and how to start them, the env contract (names, never values), where credentials live and how they are provisioned, the account; point to project docs that hold it.
- **Guards in force** (≤5 lines, only when met this session): `<guard> → blocks <what> → sanctioned route <allow rule | user-run ! <cmd> | project script>`. Never a way around a guard.
- **Ownership**: writer sid8; other live sessions or peers on this checkout, bucket or lane; foreign commits; newer handoffs from other sessions and what they decided; `read-only: <resource>, owned by <sid8 | peer>`.

### 4.8 Work done and findings

```
- <task>: <ladder stage> — <proof>
- Finding: <conclusion> — <path#Symbol | command | URL>
- Changes (up to 15, by importance): <behaviour> — `path#Symbol`
- Commits: <base>..<head> (<n> commits)
- Tests: <pass|fail> <count> — `<command>`
- Must read (≤3): <path> — <why>
```

Tests: result, count and command, never output. Logs and warnings: conclusion and reproducer. Arithmetic: result and how. Code only when mid-edit, ≤5 lines. Non-obvious learnings go here as one-liners.

### 4.9 Evidence

Paste the helper's lines and add ≤5 items:

```
Evidence: <bucket>/evidence/<stem>/ (<N> files, <X> MB; MANIFEST.tsv)
- <durable path> — <what it shows> (origin <ephemeral path>, may be gone)
Disposable: <disposable root>/<date>/<stem>-evidence/ (<retention note from the helper>)
Ref-only: <path> — <bytes>, sha256 <8>, regenerate: `<cmd>`
Volatile: <ephemeral path> — <reason not copied>
```

Every ephemeral path cited anywhere in the body has a durable copy here or sits on `Volatile:`. Durable paths appear only as the helper printed them. An output an In-flight row is still writing (probe paths included) goes on `Volatile:` as `<path> — live output of B-n`; do not copy it. <!-- review-fix: otherwise every probe path is a blocking LINT -->

### 4.10 Next steps

```
1. <Step 1's command or edit, character for character, without its "— for …" tail> — done when <observable>
2. <action> — done when <observable>
   if <transition> → <action>          (optional)
- pending answer: <the unsent table, number or draft, in full> — send if not already sent
```

Gated items read `ask user: <action> (needs fresh approval; user-run: ! <cmd>)`, never an order. <!-- review-fix: item 1 wording above; the lint compares the command or edit only -->

## 5. Evidence preservation (owner defaults)

- **Rule.** Never depend on a file that can vanish on its own; cite one only beside a durable copy or on `Volatile:`. Ephemeral: `/tmp`, `/private/tmp`, `/var/folders`, `$TMPDIR`, session scratch folders, background-task outputs. 30-day: Claude Code's projects, plans and tasks folders. Durable: the handoff tree, tracked files, archives.
- **What.** Evidence and the tools that made it: scripts, briefs, workflow scripts with literal arguments, journals, small outputs, drafts, the background-work record, scratch-clone patch series. Cited only, never copied: transcripts, session logs, shell history, environment dumps, credentials.
- **Caps.** Copy files ≤10 MB, ≤50 MB per handoff; the rest are `ref-only` (bytes, sha256, mtime, regeneration command, ≤40 head/tail lines of text). Dedupe by sha256 across buckets (`dup`); a bucket whose `evidence/` and `compact/` folders together exceed `evidence_quota_mb` gets a warning.
- **Where.** Needed later → `<handoff root>/<repo>/<bucket>/evidence/<stem>/`. Disposable → `<disposable root>/<YYYY-MM-DD>/<stem>-evidence/`, today's folder only, with a retention note from `disposable_keep_days` ("kept until you remove it" when unset). Defaults `~/.claude/handoffs` (bucket `~/.claude/handoffs/<repo>/<ticket-or-topic>/`) and `~/.claude/trash-staging`. Never in a git repository, `.planning/` or a temp folder.
- **Secret gate**, before each copy and over the draft and recipes at publish. Denied by name: `.env*` (except example, sample, template, dist), private keys, `.netrc`, `.npmrc`, `~/.claude.json`, shell history, `*.har`, `*.sqlite` and similar; regular, scannable files only. HARD patterns: provider key prefixes, PEM blocks, JWTs, `Bearer`/`Basic` headers, `user:password@` URLs. WARN patterns: `password=`, `secret=`, `token=`, `key=` pairs, prefix-less cloud keys, long high-entropy strings, cookies. A log or JSON file with any hit → a `redacted` copy keeping the original sha256; other files: a HARD hit or a deny-listed name → `withheld`, a WARN hit → a `redacted` copy. In the draft and recipes a HARD hit blocks and a WARN hit is advisory. Background-task outputs only as redacted head/tail excerpts. Rule ids are printed, never values. umask 077; folders 0700, files 0600.
- **Manifest** `MANIFEST.tsv`: `copy_path origin bytes sha256 mtime copied_at mode scan regen_cmd meaning`, scan `full` · `excerpt` · `ref-only` · `withheld` · `redacted`; recipes, `ledger.md` and `inflight.md` included. Order: copy, re-hash, manifest, publish by exclusive create, receipt.

## 6. Session id and lock

- **Identity** = full `session_id` + actor, from the plugin's per-process session record, cross-checked against the id the skill passes (mismatch → the line `identity: degraded (<reason>)` under Ownership; none → random token, never a shared name). Compaction and `--resume` keep it; `/clear`, fork and background copies get a new one, linked by `previous_session_id` and `lineage_reason`. `transcript_path` locates, never keys.
- **Name** `YYYY-MM-DD_HH-MM-SS_<sid8>_<slug>.md`, local time; readers order by frontmatter `date`, never by name or mtime; `-2` on a clash; `-a<agent8>` only with an agent id known to code. Only the main session writes (§8).
- **Lock.** Publishing is an exclusive create with no lock; a published file is never rewritten. The one lock guards the helper's read-modify-write of `.sessions/<sid>.json` (bucket, lane, worktree): owner = sid + actor + pid + process start time + host; stale only when that pid is gone or its start time differs (then taken over and logged); a live lock is never broken.
- **Ownership** is checked before the first write to anything shared (foreign commits, a newer foreign handoff, a lane held elsewhere, another live session on the checkout): read-only there, recorded under Ownership. Never edit or delete another session's files.

## 7. Lint (helper, at publish; it flags and never edits)

- **Blocking** `LINT`, nothing published: headings missing, renamed or out of order; frontmatter, marker or sentinel in the draft; Resume here over 5 lines; Step 1 differs from Next steps item 1; a none-section empty without its none-form; an ephemeral path with no durable copy and not on `Volatile:`; a Live state row without an as-of; a `checked` or `verified` time the helper did not print in this run, or one that is not a whole stamp, outside lines carried byte-identical from `previous_handoff` <!-- review-fix: carried Corrections/X- lines failed the lint -->; a line from a foreign base without its `[from …]` tag, or a tagged approval without `context only, not valid here; re-ask` or with `used`/`not yet used`; in repo mode, a machine-private path left after the export rewrite (`~/.claude/projects/`, a `.jsonl` under `~/.claude/`, another user's home, a `claude-*` temp path); an id range; an `UPDATE` or addendum heading; a recipe with a placeholder, a script not in the manifest, or an agent spawn without model and effort; a HARD secret hit in the draft or recipes.
- **Advisory** `ADVISORY`, published: over 20 KB; a section over its cap; a code block over 5 lines; log-, warning- or stack-shaped lines; 4 or more consecutive hash lines; over 15 changes or 3 must-read paths; a WARN secret hit; a recorded job's recipe whose `command:` differs from its record; 30% or more of non-ledger lines shared with `previous_handoff` (lines starting `U-`, `D-`, `X-`, `Q-` or `Superseded:`, headings, none-forms and helper-pasted Evidence lines excluded).
- Receipts: `Wrote handoff to: <path>` · `REFUSED: lint (<n> blocking); draft kept at <path>` · `REFUSED: <other reason>`. In repo mode one export line follows a written receipt: `Exported to repository: <path> (untracked; review and commit it yourself)` · `Export refused: <reason>` · `Not exported: <how to accept>`.

## 8. Subagent form (returned as text, never written)

In order: Task as assigned (quoted) · Constraints from the parent · Report (where and how; default: this text, to the parent) · Done, with proof · Findings (exact ids, numbers, paths) · Produced but not yet delivered (verbatim when short) · Own background tasks (id, until <wait spec>, due, output) · Next action (exact). End with `return text; the parent writes the file`.
