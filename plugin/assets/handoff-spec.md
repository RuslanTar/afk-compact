# compactinue handoff spec v1 (shared literals)

One source for the literals that the handoff skill, the resume skill, the compaction texts, the mod, the helper, the publish lint and the watcher share. The handoff template mirrors this file; where they differ, this file wins. Code reads only the `json spec-literals` block at the end and hard-codes no heading, vocabulary or pattern.

## 1. Marker and sentinel

- Marker: `⟪compactinue v1 n=<nonce> s=main|sub|manual⟫`. Sentinel: `⟪/compactinue n=<nonce>⟫`. The nonce is 8 lowercase hex from code.
- Scope: `main` (main compaction summary) · `sub` (subagent compaction summary) · `manual` (the handoff skill).
- In a summary or handoff the marker sits in the first 5 body lines after the wrapper lines are stripped, and the sentinel in the last 3 non-blank lines. Non-blank text after the sentinel is a trailer.
- Wrapper lines stripped before the search: the `This session is being continued…` line, a `<tools-used-before-summary>…</tools-used-before-summary>` block, a `Summary:` line, and the `<summary>` / `</summary>` tags.
- In instructions (the mod's instructions, a classic `custom_instructions`) the marker sits mid-line, so that search is unanchored and the last match counts. It counts as ours only when a dispatch record holds its nonce.
- Any other bracketed or prefixed header line is someone else's: never ours, left untouched.

## 2. Sections

Main form, in this order (a heading matches by its literal prefix at the start of a `#` line, so `## Resume here (≤5 lines)` is `## Resume here`):

```
⟪compactinue v1 n=<nonce> s=…⟫
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
⟪/compactinue n=<nonce>⟫
```

Subagent form, in this order: `## Task as assigned` · `## Constraints from the parent` · `## Report` · `## Done` · `## Findings` · `## Produced but not yet delivered` · `## Own background tasks` · `## Next action`.

## 3. Verdicts

First match wins: `stale` · `scope-leak` · `unshaped` · `truncated` · `ok-trailer` · `ok`. For readers, "ok" means `ok` or `ok-trailer`.

## 4. Vocabularies

- **Status words** (Resume here): `active` · `blocked` · `waiting-owner` · `waiting-job` · `done`.
- **Work-state ladder**: `proposed` · `queued` · `implemented` · `tested` · `committed` · `pushed` · `in review` · `merged` · `deployed` · `published` · `installed`.
- **Claim tags**: `[verified <stamp>: <cmd>]` · `[unverified]` · `[inherited: <stem>]` · `Superseded: <id> by <id> (<stamp>)`. Live state tags: `measured` · `verified` · `unverified` · `inherited`.
- **Stamp** (RV-24): a time is always `YYYY-MM-DD HH:MM ±hhmm` (local date, local time, numeric UTC offset, all three, e.g. `2026-10-21 14:05 +0300`). The helper prints stamps; in a shell, `date '+%Y-%m-%d %H:%M %z'`. Older files may hold `HH:MM` or `MM-DD HH:MM` (`time_legacy_re`): read them, never write them. Frontmatter `date` stays ISO with a colon offset.
- **Ids**, one per item, never ranges, kept across a chain: `U-n` user constraint, approval or ask · `D-n` decision · `X-n` rejected option, refuted finding or failed approach · `Q-n` question · `B-n` in-flight row (plus its runtime id).
- **Questions**: owner `next-agent` · `user` · `external:<who>` · `bg:<B-n>`; raised by `user` · `agent` · `external`; status `unasked` · `asked <stamp>` · `timed out` · `answered: <answer>`.
- **Restart classes**: `auto` · `ask` · `never`.
- **In-flight `kind`**: `agent` · `teammate` · `workflow` · `monitor` · `cron` · `shell` · `server` · `peer` · `external`.
- **Dies on**: `/clear` · exit · 7-day expiry · nothing. A background shell or server survives `/clear`; at exit it stops unless the user picks "Move to background and exit", so its value is `exit`.
- **Frontmatter `status`**: `in-progress` · `blocked` · `completed`. **`lineage_reason`**: `clear` · `fork` · `bg-copy` · `handoff-resume` · `none`.
- **Resume relation**: `same-session` · `successor` · `other` · `unselected`. **Integrity**: `ok` · `possibly truncated` · `legacy` · `unshaped` · `s=sub`.
- **Carry base** (`previous_kind`, RV-19): `own` (this session's file) · `chain` (a lineage predecessor's file) · `foreign` (another session's file). These are the relations `same-session`, `successor` and `other` as the writer sees them. A document with `imported_from` is never the carry base.
- **Carried-line tag** (lines taken from another session's handoff): `[from <sid8> · <their id> · <their stamp>]`, or `[from <sid8> · - · <stamp>]` on a pointer line. A foreign approval is carried only as `context only, not valid here; re-ask`.
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
- Probe for a `shell`, `server` or `external` job: `compactinue-store wait --for <spec> --max 0` (§14), which checks once and returns at once.

## 7. Ledger fold line

`D-1, X-2 settled; full text in <path>`: each moved id named, never a range. The line is ledger and is carried unchanged. `U-` lines never move.

## 8. Frontmatter

- Handoff: `kind: handoff`, `writer`, `nonce`, `date`, `session_id`, `actor`, `previous_session_id`, `lineage_reason`, `transcript_path`, `claude_pid`, `cc_version`, `repository`, `bucket`, `worktree`, `branch`, `git_commit`, `status`, `ticket`, `queue_lane`, `previous_handoff`, `previous_kind`, `own_previous_handoff`, `imported_from`, `gsd`. Empty keys are omitted. `previous_kind` (`own` · `chain` · `foreign`) and `own_previous_handoff` (a path, only when the carry base is foreign and an own file exists) are written by `begin`/`publish` (RV-19); `imported_from` (`repo:<rel path>`) only by `project copy --from repo`.
- Summary copy: `kind` (`compact-summary` · `subagent-summary`) and the handoff keys except `ticket`, `gsd`, `previous_kind`, `own_previous_handoff` and `imported_from`, plus `bucket_source`, `trigger`, `compaction_seq`, `tokens_before`, `tokens_after`, `verdict`, `channel`, `seat_state`, `evidence`, `redacted`.
- Export (repo mode, D-12 §1.5.5; `frontmatter_keys_export`): the handoff keys minus the machine-only `transcript_path`, `claude_pid` and `worktree`, minus the private-chain keys `previous_kind`, `own_previous_handoff` and `imported_from`, plus `export: repo`. `bucket`, `previous_handoff` and `gsd` are rewritten to repository-relative values. A key outside this list is dropped from an export.
- `writer`: `handoff` · `mod` · `postcompact-fallback`. Code writes frontmatter, marker and sentinel; a model never types them.

## 9. Locations

- Bucket `<handoff_root>/<repo>/<ticket-or-topic>/` (default root `~/.claude/handoffs`). Handoffs at its top level, named `YYYY-MM-DD_HH-MM-SS_<sid8>_<slug>.md`; readers order by frontmatter `date`.
- Copies: `compact/`, `compact/subagents/`, `compact/unattributed/`, names ending `-<id6>.md`.
- Evidence: `evidence/<stem>/` with `MANIFEST.tsv`. Disposable: `<disposable_root>/<YYYY-MM-DD>/<stem>-evidence/`.
- Sessions: pins `.sessions/<sid>.json`; lineage `.sessions/<sid>.lineage.json`; per-process records `.sessions/by-pid/<pid>-<lstart>.live-<sid8>.json` and `.ended-<sid8>.json`.
- Watch tree `<log_dir>` (default `<root>/.watch`): `<sid>.jsonl`, `<sid>/events/`, `<sid>.classic.jsonl`, `<sid>.alerts.jsonl`, `<sid>/compactions.jsonl`, `<sid>/mod-alive.json`, `<sid>/bg/slot-<k>.json`, `heal/<origin sid>/<item>.count`.

## 10. Secret rule set

One rule set for evidence copies, summary copies, drafts and recipes. Rule ids are printed and logged, never values.

- **Denied by name** → `withheld` (never scanned, never copied): `.env*` except `.example`, `.sample`, `.template` and `.dist` files; private keys; `.netrc`; `.npmrc`; `.claude.json`; `.credentials.json`; shell history; `*.har`; `*.sqlite`; `*.heapsnapshot`. Regular files only.
- **HARD**: provider key prefixes, PEM blocks, JWTs, `Bearer`/`Basic` headers, `scheme://user:pass@host` URLs.
- **WARN**: `password=`, `secret=`, `token=`, `key=` pairs; prefix-less 40-character cloud keys; base64 runs of 32 or more characters with entropy of at least 4.0 bits per character; cookies.
- **Actions**: a log or JSON file with any hit → a `redacted` copy keeping the original sha256; other files: a HARD hit → `withheld`, a WARN hit → a `redacted` copy; background-task outputs only as redacted head/tail excerpts; a summary with a HARD hit → a redacted copy; in a draft or recipe a HARD hit blocks publishing and a WARN hit is an advisory with its rule ids.

## 11. Clutter classes (lint and watcher; flag only)

Absolute-path lines · code blocks over 5 lines · log, warning and stack lines · arithmetic lines · 4 or more consecutive hash lines · temp paths (`/tmp`, `/private/tmp`, `/var/folders`, `$TMPDIR`, scratchpads, background-task outputs).

## 12. Outward and destructive classes

`push` · `force-push` · `mr-write` · `http-write` · `deploy` · `publish` · `history-rewrite` · `recursive-delete` · `mcp-write`. A command in one of these classes needs a fresh ask; a handoff or summary never grants it.

## 13. Alert texts

Fixed per rule; no user content. Shown as `compactinue watcher: <text> (<alert_id>)`.

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
| A-16 | sec-default bypass suspected |
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

## 14. Wait specs (Dev-7 D2, D3; DP-1, DP-14)

`compactinue-store wait --for <cond> [--for <cond>…] [--while <guard>…] [--max <s>] [--stall <s>] [--deadline <epoch>]`

- **cond**: `pid-exit:<pid>[@<start-epoch>]` · `file:<path>` · `marker:<path>:<perl-regex>` · `exit:<path>`. **guard**: `pid:<pid>[@<start-epoch>]` · `file:<path>`. A path holds no `:`.
- The wait is met when any `--for` holds. It ends early (exit 12) when a `--while` guard stops holding. `--max` is 0 to 7200 seconds, default 270; `--max 0` checks once and returns at once.
- `exit:<path>` reads the end marker of a job: a line `__exit <n>` (`^__exit (-?[0-9]+)$`) or the runtime trailer `[exited with code <n>]` prints `rc=<n>`. The trailer `[killed]` (a TaskStop, or the tasks stopped at exit) prints `killed`: the job was killed, never finished; a killed job is asked about, never relaunched by itself.
- **End marker (DP-1):** a job you will wait on is started with `; echo "__exit $?"` at the end of its command. A relaunch replays the recorded command byte for byte, so it carries the suffix when the original did; restart text never adds it.
- **Regex limits:** a `marker` pattern longer than 200 characters, or holding `(?{`, `(??{` or `(*`, is refused with exit 64. An overrun past `--max` plus 5 seconds ends with exit 70. Core Perl code never runs from a pattern.
- **Quoting (Dev-5):** resume passes a handoff's spec only inside single quotes. A spec containing `'` is reported, never run.
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

Kebab-case ids, printed as `LINT <id> <where>` (blocking: nothing is published) or `ADVISORY <id> <where>`. The publish lint and the template's lint list use exactly these.

- **Blocking**: `headings` · `meta-in-draft` · `update-heading` · `resume-lines` · `step1-mismatch` · `none-form` · `ephemeral-path` · `live-asof` · `unprinted-time` · `time-format` · `id-range` · `carry-provenance` · `carry-approval` · `private-path` · `recipe-placeholder` · `recipe-script` · `recipe-spawn` · `secret-hard`.
- **Advisory**: `size` · `section-cap` · `code-block` · `log-lines` · `hash-lines` · `must-read` · `changes` · `overlap` · `recipe-mismatch` · `secret-warn`.
- `time-format`: `checked` or `[verified` followed by a time that is not a full stamp, outside lines carried byte-identical from the base.
- `carry-provenance`: a `U-`, `D-` or `X-` line whose content occurs in the foreign base and not in the own base, with no carried-line tag. `carry-approval`: a tagged approval line without `context only, not valid here; re-ask`, or with `used` / `not yet used` on it.
- `private-path` (repo mode only, fix or report): a line that still holds a machine-private path after the export rewrite of D-12 §1.5.5 (the user's home is already `~/`): `~/.claude/projects/`, a `.jsonl` file under `~/.claude/`, another user's home, or an in-flight probe path (`/private/tmp/claude-*`, `/tmp/claude-*`, `$TMPDIR/claude-*`). It may fire on the same line as `ephemeral-path`: that rule accepts a durable copy or a `Volatile:` line, this one never does, because the path would reach git.

## 16. Caps

- `call_cap` 25: the handoff skill's hard cap on tool calls (Step 1 ≤4 · Step 2 ≤11 · Step 4 ≤2 · Step 6 1 · Step 7 ≤7). `recipe_cap` 8: restart-recipe writes (Step 5) on top. The plugin handoff turn derives its own call limit from both (1 + `call_cap` + `recipe_cap`).
- The compaction text budgets (D-17, DP-8) are not here: `tools/assemble` holds them.

## 17. Machine-readable literals

Patterns use the subset that both Perl and JavaScript read the same way: no flags, so letter case is spelled out in classes. A rule with `min_entropy` also needs the match's Shannon entropy (bits per character) at or above that value. A clutter class with `max_lines` flags a fenced block longer than that; one with `min_run` flags that many consecutive matching lines. `copy_trailers` lists engine trailers after a summary body that the normalizer cuts; none is known for the tested version.

```json spec-literals
{
  "spec_version": 1,
  "title_prefix": "# ",
  "sections_main": [
    "## Resume here",
    "## User constraints",
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
  "marker_re": "^⟪compactinue v1 n=([0-9a-f]{8}) s=(main|sub|manual)⟫$",
  "sentinel_re": "^⟪/compactinue n=([0-9a-f]{8})⟫$",
  "instr_marker_re": "⟪compactinue v1 n=([0-9a-f]{8}) s=(main|sub)⟫",
  "marker_window_lines": 5,
  "sentinel_window_nonblank_lines": 3,
  "wrappers": {
    "head_line_prefix": "This session is being continued",
    "tools_block_open": "<tools-used-before-summary>",
    "tools_block_close": "</tools-used-before-summary>",
    "summary_line": "Summary:",
    "summary_open": "<summary>",
    "summary_close": "</summary>"
  },
  "copy_trailers": [],
  "verdicts": ["stale", "scope-leak", "unshaped", "truncated", "ok-trailer", "ok"],
  "ok_verdicts": ["ok", "ok-trailer"],
  "scopes": ["main", "sub", "manual"],
  "status_words": ["active", "blocked", "waiting-owner", "waiting-job", "done"],
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
  "question_status_re": "^(unasked|asked [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}|timed out|answered: .+)$",
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
  "frontmatter_keys_handoff": ["kind", "writer", "nonce", "date", "session_id", "actor", "previous_session_id", "lineage_reason", "transcript_path", "claude_pid", "cc_version", "repository", "bucket", "worktree", "branch", "git_commit", "status", "ticket", "queue_lane", "previous_handoff", "previous_kind", "own_previous_handoff", "imported_from", "gsd"],
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
  "lint_ids": {
    "blocking": ["headings", "meta-in-draft", "update-heading", "resume-lines", "step1-mismatch", "none-form", "ephemeral-path", "live-asof", "unprinted-time", "time-format", "id-range", "carry-provenance", "carry-approval", "private-path", "recipe-placeholder", "recipe-script", "recipe-spawn", "secret-hard"],
    "advisory": ["size", "section-cap", "code-block", "log-lines", "hash-lines", "must-read", "changes", "overlap", "recipe-mismatch", "secret-warn"],
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
    "main_max_s": 1800,
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
    "inflight_probe_cmd": "compactinue-store wait --for <spec> --max 0"
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
    "A-16": "sec-default bypass suspected",
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
    "A-27": "auto-continue without a nudge"
  }
}
```
