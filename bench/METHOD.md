# Pre-registration: Claude Code native compaction vs afk-compact 0.1.9

Version 1.0, written 2026-11-12, before any bench-v2 run.
**Status: frozen.** The sha256 of the frozen original is `2ab89647fe257e61f98f6c5faf143e1befbb6c516f1ae8901c4010940637f974`. This public copy rewrites only user-local paths and private identifiers, and leaves out figures measured in earlier lab runs (see [PRIOR.md](PRIOR.md)), so its own hash differs from the original's. A second freeze step after the pilot (`FREEZE-2.md`) pins the generated scenarios, keys, quiz texts, judge prompts and harness tree. It may change only what section 16 lists. Any other change after this freeze is a deviation and is reported as one.

Inputs this design rests on: the earlier lab runs ([PRIOR.md](PRIOR.md)), the weighting of the earlier plugin text, a profile of real compaction use, a loss analysis of real sessions, and cost data from the author's own use. Reproducible numbers here come from the design scripts `prior_variance.py`, `power_v2.py`, `cost_v2.py` and `calib_usage.py`. None of them calls a model.

Not in the repository yet: the run book (cited below by section), the design, lab and campaign scripts named below (`prior_variance.py`, `gen_harbourline.py`, `report_run.py`, `blind.py`, `run_checks.py`, `stats2.py`, ...), `FREEZE-2.md` and `docs/benchmark.md`. They are published with the results.

---

## 0. In one screen

- **Question.** In a long session that compacts again and again, what does Claude Code's native compaction lose? What does afk-compact 0.1.9 change? Three things are measured: what the session can still state, what it can recover when asked, and how it behaves after a resume. Both arms use the same Claude Code (2.1.322), the same model (`claude-opus-5-5`, effort `high`) and the same scripted prompts.
- **Why a v2.** The 2026-10-20 lab (OCT20) had several limits:
  - n = 1 per arm;
  - an easy scenario near the ceiling for native;
  - auto-memory leaking canaries;
  - a plugin-arm text that shares very few words with 0.1.9.

  Real use is harder, by the author's profiling of real sessions:
  - the median compaction is a session's 4th, and the tail runs to the 14th and beyond;
  - dozens of facts are in force at a cut;
  - most cuts have a job running;
  - at plugin-threshold cuts the live summary keeps only part of the exact ids verbatim.

  Under the plugin's own instructions, Claude Code's summary often dropped a ledger line in repeat compactions. The plugin's saved copy put the lines back, but on disk, not in the conversation.
- **The cells:**
  - **SC-A** is the headline: a p50 load that grows to p90, over 10 compactions.
  - **SC-B** holds a p90 load from the start, over 6 compactions.
  - **SC-C** covers away and back: idle return, `claude --resume` and `/clear`.
  - **OCT20 replica** keeps comparability with the 2026-10-20 data: 5 mid-turn auto compactions.
  - **Mode R** is the real 410K cut with the plugin's own trigger (stage B).
- **Primary endpoint (co-primary, Holm).** Both are measured in SC-A, on 37 static early facts, as the per-seed paired difference afk − native in recall points share, graded by deterministic keys:
  - **E1a**, closed book (no tools), averaged over N = 1..10 compactions;
  - **E1b**, open book (read-only tools), averaged over N ∈ {2, 4, 7, 10}.
- **Everything else is secondary, with CIs:** summary recall by two blind judges, exact ids and numbers, drift of early rules, next step after resume, background work, approvals and their scope, idle return, after `/clear`, and cost and time.
- **Capabilities native lacks are behaviour tests with pass rates in both arms.** For example, after `/clear`, native gets a plain "continue" prompt and afk its documented `/afk-compact:resume`, and both are graded the same way. They are never shown as invented recall numbers.
- **Sample size.**
  - **Stage A** fits the $1,000 cap (estimate $877): SC-A 8 pairs, SC-C 6, OCT20 4, SC-B 2.
  - **Stage B** needs a raised cap (estimate $1,423): SC-A to 12 pairs, SC-B to 6, SC-C to 8, Mode R 3 pairs, plus a Sonnet replication, a DIY-instructions arm and auto-memory on.
  - **Power (E1a):**
    - 8 pairs detect an AUC gap of about 0.12 with 80% power;
    - 12 pairs detect about 0.10;
    - gaps under about 0.06 will read as "no detectable difference". That is reported as it is.
- **Earlier runs are pooled into the OCT20 panel only.** They are weighted (native 0.25-0.5; lab text 0.09-0.17, template weight × version weight × scenario weight) with a weighted Bayesian bootstrap. Pooled results are shown beside the v2-only ones, with sensitivity at weights 0 and 1.

## 1. The question, and the claims it can support

**What may be claimed.** Only what the results show, stated with:
- the model and effort;
- the Claude Code version and the afk-compact version;
- the cut size and the number of compactions;
- n;
- the CI.

The study measures matched cut points at about 160K tokens in a synthetic seeded repository, on one model. It says nothing about other models, other window sizes, or the author's real sessions. If native compaction keeps the facts, or the plugin does not help, the README says that or makes no claim. Every run is published, including invalid runs with their reasons. No number appears anywhere before the campaign has produced it.

**What may not be claimed.**
- "afk-compact retains X% more" from the real-use facts (and similar). They have no native baseline and stay as text under the figure, labelled as the author's own use.
- Any result from the 2026-10-20 plugin arms as 0.1.9 evidence. They used a different text (similarity 0.037).
- A pooled number on its own. Pooled numbers appear only beside the v2-only number.

## 2. Arms

| Arm | What it is |
|---|---|
| **native** | Claude Code 2.1.322, called by full path, with no plugin. Fake HOME, settings S-common (section 3). |
| **afk** | The same, plus afk-compact **0.1.9**. It is installed through a directory marketplace from a `git archive` snapshot of `release-0.1.9-wip` at **37c9dcc31c084cdb642574fdc137f7bfe813a22f** (tree `77e4a38e…`; `plugin/.claude-plugin/plugin.json` version 0.1.9). **Every plugin option stays at its install default.** The only addition is one allow rule for the plugin's own helper (`Bash("<plugin folder>/scripts/afk-compact-store" *)`); without it, `dontAsk` mode would deny the plugin's resume calls. |
| diy (stage B, exploratory) | native, plus a fixed `## Compact Instructions` block in the repository's `CLAUDE.md` (Appendix B). It answers one user question: "could I just write better compact instructions myself?" It is not part of any primary or secondary hypothesis. |

The following are identical in every arm:
- binary, model, effort and window;
- the scripted user turns and the seed;
- `--strict-mcp-config` and `--permission-mode dontAsk` (never a bypass);
- the same allowlist;
- `PATH` and the statusline logger;
- the cache TTL (`promptCacheTtl: "1h"`, the subscription default);
- auto-memory off (setting plus `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`);
- no user `CLAUDE.md`, except in the diy arm.

## 3. Common settings and environment

- **Environment.** Each nested session keeps Claude Code's own nesting markers exactly as inherited: `CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `AI_AGENT`, `CLAUDE_EFFORT` and `TRACEPARENT`, when present.
  - No `CLAUDECODE` stripping of any kind.
  - Claude Code 2.1.322 turns transcript saving off in a session that inherits `CLAUDE_CODE_CHILD_SESSION`. Its own banner says: "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker · restart with CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1". So every session sets `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`. Without a transcript nothing can be measured. The marker itself is untouched, and the setting is the same in both arms.
  - All other variables are dropped: the author's shell variables, `CLAUDE_CONFIG_DIR`, `ANTHROPIC_*` and the `CLAUDE_CODE_*` tuning variables, except those a cell sets on purpose.
  - Then: `HOME` is the run's fake HOME, `DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, and `PATH` is fixed to `/usr/bin:/bin:/usr/sbin:/sbin`.
  - The exact script is in the run book, section 5.
- **No instruction file from outside the run.** The run repositories sit under the author's home directory, so `<home>` is one of their ancestors. Claude Code's CLAUDE.md walk up the parent directories would otherwise load the author's own `~/.claude/CLAUDE.md`, whatever `HOME` says. (The lab and d-shadow avoided this only by working outside `$HOME`.)
  - Main sessions, every arm: the fake HOME settings carry `claudeMdExcludes` with every `CLAUDE.md`, `CLAUDE.local.md` and `.claude/CLAUDE.md` path in the repository's ancestors. The only CLAUDE.md that can load is the repository's own, which exists in the diy arm alone.
  - Quiz forks and judges: they also set `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`.
  - Gate G12 and validity rule V13 check this.
- **Settings in the fake HOME's `settings.json`, both arms.** The tool rules are listed in full in the run book, section 6.

  | Key | Value |
  |---|---|
  | `autoMemoryEnabled` | `false` |
  | `promptCacheTtl` | `"1h"` |
  | `cleanupPeriodDays` | `3650` |
  | `statusLine` | a logger that appends Claude Code's statusline JSON to `home/sl.jsonl` (rate limits, cost, context, effort) |
  | allow | read, edit and write tools; `git`, including `git push` to the local bare remote; `make test-fast`, `make migrate-staging` and `make migrate-prod` (fake targets that write marker files); background Bash; `TaskOutput`, `TaskList` and `TaskGet`; `Agent` (needed for the planted background agents) |
  | deny | web tools, `Workflow` and `curl`; reading `~/.claude/projects/**` in the main session (this keeps the closed-book quiz clean; it is allowed in the open-book fork, section 8.2) |
- **Per cell:**

| Cell | Trigger of each cut | `autoCompactEnabled` | `idleCompaction` | Window |
|---|---|---|---|---|
| SC-A, SC-B (mode M) | the driver types `/compact` at a clean turn end once the context is at least **160,000** tokens | false | false | the model default (1M, recorded at preflight) |
| SC-C | `/compact` at 160K for cut 1; then whatever the defaults do during a 60-plus-minute idle | true | true (default) | 1M |
| OCT20 replica | Claude Code's own auto compaction, mid-turn (as in 2026-10-20) | true | false | `CLAUDE_CODE_AUTO_COMPACT_WINDOW=150000` |
| Mode R (stage B) | native: `/compact` at a turn end at 400K or more. afk: the plugin's own trigger at its default 400K target, with its precompact turn | true | false | 1M |

In mode M the plugin's own trigger stays inert, because its target is 400K. The two arms then differ in exactly what afk-compact adds around a `/compact`:
- its handoff-shaped summary instructions;
- the saved copy and its verdict;
- the one-time resume block.

This is the manual-compaction path, about 30% of real compaction points. Mode R tests the plugin's own trigger path (32% of real points) at real scale.

## 4. Lenses

Each lens maps to one panel of the headline figure. The table also names the cell and measure for each lens.

| # | Lens | Taxonomy source | Cell(s) | Measure (section 8) | Kind |
|---|---|---|---|---|---|
| L1 | Recall over successive compactions, with load rising from p50 to p90 (SC-A) and p90 from the start (SC-B) | real-use profile; loss analysis | SC-A, SC-B | closed-book quiz, 37 static early facts (SC-A) | **co-primary E1a**; SC-B secondary |
| L1b | Recoverable when asked (tools allowed) | loss analysis (copy restores on disk) | SC-A, SC-B | open-book quiz | **co-primary E1b** |
| L2 | Exact identifiers and numbers | real-use profile (exact ids at plugin-threshold cuts) | SC-A, SC-B | quiz subset; id survival per cut; runtime-id carry | secondary |
| L3 | Constraints, decisions and failed approaches given early (drift) | loss analysis (rules drift; failed approaches lost first) | SC-A, SC-B | quiz subset; violation probes ("dropped then broken" vs "kept but broken") | secondary |
| L4 | Next step after resume | loss analysis | SC-A, SC-B, SC-C | P-turn graded each cut; resume turns in SC-C | secondary |
| L5 | Background work continuity | loss analysis (task ids of running jobs) | SC-A, SC-B, SC-C | job quiz items; check-don't-relaunch probe; result reported per the user's rule; runtime ids in summary | secondary (behaviour) |
| L6 | Approvals and their scope | loss analysis | SC-A, SC-B, SC-C | one-time reuse probe; standing in-scope probe; out-of-scope probe | secondary (behaviour) |
| L7 | Idle return | loss analysis; real-use profile | SC-C | return-turn checks R1-R6; return cost | secondary (behaviour) |
| L8 | Continuation after `/clear` or in a new process | loss analysis | SC-C | checks after `/clear` (C1-C5) and after `claude --resume` (K1-K3) | secondary (behaviour) |
| L9 | Cost and time | own-use cost data | all | $ and tokens per cycle and per run; minutes per cycle; plugin-started turns | secondary |

These are outside scope: subagent compaction (rare), secrets copied into summaries (a privacy lens nobody asked for), and the short automated-worker workload. Failed approaches and how-to procedures are in scope as fact types. Real data says the plugin may be no better on them, and that must be visible.

## 5. Cells and scenarios

Every SC scenario is generated per seed by `gen_harbourline.py` (the run book, section 4). The setting is an invented ferry-booking service, "Harbourline":
- ticket prefix `HBL-` and repository `harbourline-api`;
- standard-library Python, with `fares/`, `manifests/`, `notify/`, `migrations/`, `tools/`, `logs/` and `data/`;
- tests through `make test-fast`;
- a local bare `remote.git` with `main` pushed at the baseline;
- fixed author and commit dates per seed, so commit hashes are deterministic.

Seeded values (numbers, ids, line numbers, names, hosts and times) change per seed. The model cannot know them from priors, and both arms of a seed get byte-identical scripts.

Leak check (gate G11): no planted value of four or more characters may occur in the plugin snapshot or in Claude Code's own texts. The 0.1.9 handoff template contains OCT20 strings. The OCT20 replica is unaffected because no handoff skill runs at a 150K window. The validator flags any read of the template by the main session.

### 5.1 SC-A: "steady lane", p50 load rising to p90, 10 compactions (the headline)

**Shape.**
- Segment 1 plants 37 static and 4 stateful early facts, plus 3 work threads: main ticket, flaky spec, and a review waiting on an MR. Then come fillers up to the 160K cut and a plan turn.
- Segments 2-10 each start with the P-turn (the first turn after the cut) and the quiz.
- Each later segment then brings 2-3 scripted work and probe turns, 2 quizzed churn facts (a new decision with its reason, and a new exact id or number) and about 3 unquizzed churn facts (commit hashes of work done, numbers in findings). Fillers grow the context back to the cut.

**Load at the cut.**
- About 41 facts in force at cut 1 (≈ p50 of the plugin's notes);
- about 55 by cut 5 (≈ p75);
- about 70 by cut 10 (at or above the real p90 of about 60).

So SC-A runs through the real load range as its chain deepens, the way real sessions do (in the real-use profile the oldest directive sits 4 / 9 / 14 compactions back at p50 / p75 / p90).

**Fillers.**
- Each segment has 1-2 user prompts that ask the session to read 3-4 files of about 20K tokens each (logs, CSV statements, code) and answer one question per file.
- The answers carry new ids and numbers, which is realistic churn.
- Fillers never mention a planted fact.

**Jobs.**
- B1 is a background shell of about 3 h that runs to the end.
- B2 is a background agent (model `haiku`) of about 40 min that finishes during segment 3 or 4 and reports a count.

### 5.2 SC-B: "multi-lane orchestrator", p90 load from cut 1, 6 compactions

Segment 1 plants about 60 static early facts, with about 12 dense user turns of about 5 facts each, plus about 8 stateful facts. It has 5 threads: 3 MR lanes, a dependency bump, and a pending design ruling owned by someone else.

| Type | Count |
|---|---|
| constraints | 16 |
| decisions with reasons | 12 |
| failed approaches | 4 |
| exact ids | 12 (6 hashes, 4 tickets, 2 anchors) |
| numbers | 4 |
| static job facts | 4 |
| scoped approvals | 4 |
| pending asks | 3 |
| open questions | 4, 2 of them owned by a third party |
| procedure | 1 |

**Jobs.** 6 background shells and 3 background agents (model `haiku`). 5 of the 9 finish at scheduled points.

**Churn.** 6 facts per segment, 3 of them quizzed.

**Quiz.** Split into two forks per quiz point (A: rules, decisions, approvals, questions; B: ids, numbers, jobs, procedures, failed approaches), so each answer stays under about 40 keys.

**Probes.** 3 violation probes, 2 approval probes, 1 job probe, 1 third-party-question probe, and the next step at every cut.

SC-B against SC-A at the same N separates load from depth; SC-A alone confounds them, as real data does.

Real p90 sessions also run workflows (about 4 at p90 in the real-use profile). SC-B uses background shells and agents instead, because the Workflow tool is an author-specific setup. This is stated as a limit.

### 5.3 SC-C: away and back

1. **Segment 1.** It plants an SC-A subset:
   - constraints U1, U2, U3, U5, U8, U9;
   - decisions D1, D2, D3, D7, D8, D9;
   - failed approaches X1, X2;
   - ids H1, H2, T1, MR;
   - numbers V1, V2;
   - job B1 (3 h, still running at the return);
   - approvals A1 (one-time) and A2 (standing);
   - pending asks PA1, PA2 and PA3;
   - open question Q1;
   - procedure PR1.

   Then fillers to 160K, a plan, and `/compact` (cut 1).
2. **Segment 2.** It runs, in order:
   - the P-turn;
   - "tests pass, push as approved" (uses A1);
   - the user answers PA2;
   - work turns and fillers until the context is at least 205K (above native idle compaction's 200K minimum);
   - a plan;
   - B3, a background shell of about 25 min, started last so that it finishes 15-25 min into the idle.
3. **Idle.** The driver sends nothing until 60 minutes after the last activity (which includes B3's notification turn), with a hard maximum of 100 minutes. Each arm does what its defaults do, and the path is recorded per run:
   - native idle compaction (fires 54 min after the last activity when the context is at least 200K and the 1h TTL is on);
   - plugin keep-warm while B1 runs;
   - plugin idle compaction;
   - nothing.
4. **Return** (fixed text): "I'm back after about an hour. Where are we? Which background jobs finished while I was away and what did they report, which of my questions or asks are still open, and can you push the fix branch again now?" This turn is graded (R1-R6), then quiz fork Q-idle.
5. **New process.** `/exit`, then a new process `claude --resume <SID>` with the same flags. The turn: "Continue where we left off: do only the next step, then stop." It is graded (K1-K3), then quiz fork Q-resume. Both arms use Claude Code's own resume here, so no large difference is expected (afk adds a freshly measured resume block).
6. **`/clear`.** Each arm uses its documented path:
   - native: "We cleared the context. Continue the HBL-⟨n⟩ work where we left off: do only the next step, then stop.";
   - afk: `/afk-compact:resume` (documented: "Resume from a handoff or a saved compaction copy").

   Then it is graded (C1-C5), quiz fork Q-clear, and exit.

### 5.4 OCT20 replica (comparability with 2026-10-20)

- **Inputs.** The lab's own inputs, unchanged:
  - `template/` from `bin/gen_repo.py`;
  - `prompts.json` (waves: T1-T5, then FILL turns until at least one boundary, then T6, T7 and T8);
  - the 14 canaries C1-C14.
- **Model.** `claude-opus-5-5` at effort **xhigh**, as in 2026-10-20.
- **Compaction.** Window 150K through `CLAUDE_CODE_AUTO_COMPACT_WINDOW`. Mid-turn auto compactions are expected (5 in 2026-10-20). Runs are compared by summary index S1..S5; a run with fewer summaries adds to fewer indices.
- **Known flaw, kept for comparability.** The background agent's `sleep` may be blocked, as it was then. It is reported, not fixed.
- **Differences from 2026-10-20:**
  - fake HOME;
  - auto-memory off, which removes the T7 confound;
  - `dontAsk` with an allowlist instead of `auto`;
  - Claude Code 2.1.322, which keeps a verbatim tail after the summary (2.1.309 and later);
  - no lab probe mod or logging hooks in either arm.

### 5.5 Mode R (stage B): real scale with the plugin's own trigger

- **Script.** SC-A segments 1-4, with fillers sized for a 410K cut. That gives 4 cuts, with closed-book quizzes at N = 0..4 and open-book quizzes at N = 2 and 4.
- **Arms.** Native compacts with `/compact` at a turn end once the context reaches 400K or more. afk runs at defaults, so the plugin compacts by itself at its 400K target after its precompact handoff turn.
- **What it tests.** Whether the mode-M gap holds at the real context size, with the plugin's real trigger.
- **n.** 3 pairs, descriptive. Context size and trigger path change together here. That is stated, not hidden.

### 5.6 Seeds and pairing

Seed blocks are reserved per cell, so stage B extends a cell without reusing a seed.

| Cell | Seeds | Stage A | Stage B |
|---|---|---|---|
| SC-A | 1-16 | 1-8 | 9-12 (up to 16 after re-estimation, section 10.3) |
| SC-B | 101-108 | 101-102 | 103-106 |
| SC-C | 201-210 | 201-206 | 207-208 |
| OCT20 | replicates r1-r8 (fixed scenario) | r1-r4 | — |
| Mode R | 301-303 | — | 301-303 |
| SC-A on Sonnet (stage B) | 1-6 | — | 1-6 |

- **Pilot seeds** 0 (SC-A, 3 cuts), 200 (SC-C) and OCT20 replicate p1 never enter an analysis.
- **Pairing.** A pair is one seed run in both arms at the same time, with start order alternating by seed parity (ABBA): even seeds launch native first, odd seeds afk first, about 5 s apart.

## 6. Planted facts and keys

### 6.1 Fact types

| Type | Grading parts |
|---|---|
| constraint (U) | core rule; reason where given |
| decision with reason (D) | choice; reason |
| failed approach (X) | what failed; why, or don't retry |
| exact id: hash, ticket, file:line anchor, MR, request id | exact string |
| number (V) | exact value, normalised for thousands separators and units |
| background job (B) | command or tag and log path; the runtime task id is scored apart (M5) |
| approval (A) | target; once or standing; exclusion |
| pending ask (PA) | what; that it waits for the user |
| open question (Q) | the question; the owner; that it is not decided |
| procedure (PR) | how; the forbidden way |
| superseded or updated (stateful) | the current value; an old value given as current is **stale** |
| decoy (H) | must be "unknown"; any value is a **hallucination** |

**Source.** Each fact is tagged `user` (said in a user turn) or `tool` (found by the model with a tool: H5, P1, RQ and V4 in SC-A). The `tool` facts count only if the model's own reply before cut 1 states the value (plant check, section 12).

### 6.2 SC-A static early facts (37; values ⟨…⟩ are seeded)

| Id | Type | Planted as (paraphrase of the user turn) | Key groups: core / reason |
|---|---|---|---|
| U1 | constraint | never edit anything under `manifests/legacy/`; the port authority's parser reads them byte for byte | `manifests/legacy` / parser\|byte\|port authority |
| U2 | constraint | run tests only with `make test-fast`, never unittest or pytest directly; the full suite hits the sandbox payments API | `make test-fast` / payments\|sandbox |
| U3 | constraint | keep code compatible with Python ⟨3.8⟩: no `match`, no `X \| Y` unions | the exact version |
| U4 | constraint | keep each commit under ⟨220⟩ changed lines | the number |
| U5 | constraint | never push to main | main + never\|not\|no |
| U6 | constraint | no merges or deploys after ⟨17:40⟩ on Fridays (ferry operations freeze) | time + Friday / freeze\|operations |
| U7 | constraint | keep review-bot runs under $⟨40⟩ | the amount |
| U8 | working rule | when a background job finishes, tell me its result in one line | tell\|report + finish\|done\|result |
| U9 | constraint | use `data/fares-⟨2026Q3⟩.csv`, never the live export | the file name |
| D1 | decision | half-even rounding only in `fares/round.py`, because the regulator's table ⟨HR-17⟩ is half-even | half-even\|banker + round.py / ⟨HR-17⟩\|regulator |
| D2 | decision | cap manifest batches at ⟨480⟩ rows, because the port API rejects more than ⟨500⟩ | ⟨480⟩ / ⟨500⟩\|reject |
| D3 | decision | money in Decimal, never float; float broke the March reconciliation, ticket ⟨HBL-1131⟩ | Decimal / ⟨HBL-1131⟩ |
| D4 | decision | webhook retries back off ⟨45⟩ s, because the notify gateway allows ⟨40⟩ per minute | ⟨45⟩ s / ⟨40⟩ |
| D6 | decision | child fare = ⟨0.55⟩ of adult, per tariff notice ⟨TN-08⟩ | ⟨0.55⟩ / ⟨TN-08⟩ |
| D7 | decision | store UTC, show Europe/⟨Tallinn⟩, because routes cross a time-zone line | UTC + ⟨Tallinn⟩ / cross\|zone |
| D8 | decision | refund window ⟨72⟩ h, per legal memo ⟨LGL-22⟩ | ⟨72⟩ / ⟨LGL-22⟩ |
| D9 | decision | in-process queue (`notify/queue.py`), not Redis, because ⟨ferry-app-2⟩ has no Redis | in-process\|queue.py + not Redis / ⟨host⟩ |
| X1 | failed | `lru_cache` on fare lookups broke multi-currency (FareRow is unhashable); don't retry | lru_cache / unhashable\|multi-currency |
| X2 | failed | the Decimal context patch changed rounding everywhere; reverted in ⟨hash4⟩ | getcontext\|context patch\|global / ⟨hash4⟩ |
| X3 | failed | moving fare rules to YAML failed: the regulator's diff tool needs Python literals | YAML / diff tool\|literal |
| H1 | id (user) | last good build ⟨hash1⟩ | the 7-hex prefix |
| H2 | id (user) | the regression came in ⟨hash2⟩ | exact |
| H5 | id (tool) | the commit that added the second rounding, found with `git log -S` | exact |
| T1 | id | main ticket ⟨HBL-1184⟩ (branch `hbl-⟨1184⟩-round`) | exact |
| T2 | id | flaky manifest spec ⟨HBL-1190⟩ | exact |
| MR | id | MR !⟨77⟩ waits for ⟨Ines⟩'s review | ⟨77⟩ + ⟨Ines⟩ |
| P1 | anchor (tool) | the second rounding is at `fares/round.py:⟨212⟩` | round.py + the line |
| RQ | id (tool) | first FAIL in `logs/manifests-⟨date⟩.log` is `req_⟨6 hex⟩` | exact |
| V1 | number | reconciliation tolerance ⟨0.075⟩ EUR per batch | exact |
| V2 | number | the dashboard reads port ⟨8743⟩ | exact |
| V3 | number | sweep timeout ⟨5400⟩ s | exact |
| V4 | number (tool) | the FAIL line's delta is ⟨218.58⟩ EUR | exact |
| B1 | job | `python3 tools/reindex.py --all --tag ⟨T⟩` in the background, logs to `.bench/reindex-⟨T⟩.log`, about 3 h, don't wait | reindex + ⟨T⟩ |
| A2 | approval | you may run `make migrate-staging` whenever this ticket needs it, without asking; never `make migrate-prod` | migrate-staging + without asking\|whenever\|standing / prod excluded |
| PA1 | pending ask | don't run the fare-table migration until I decide after ⟨Ines⟩'s review | fare-table + wait\|until\|don't / ⟨Ines⟩\|review |
| Q1 | open question | refunds per leg or per booking? ⟨Dana⟩ from finance decides; don't pick | leg\|booking / ⟨Dana⟩, and no "decided" |
| PR1 | procedure | to check the reindex, read the last line of its log; never loop with sleep | log path\|last line / no sleep |

**Stateful early facts (4), graded against the truth at quiz time:**
- **D5**, the CSV delimiter: comma, then semicolon from segment 3 ("the German finance team's Excel"). "comma" after segment 3 is stale.
- **A1**, the one-time scoped push: "you may push `hbl-⟨1184⟩-round` once, after `make test-fast` passes; never main". It is used in segment 2. The truth for "used?" is read from `remote.git` at quiz time.
- **Q2**, hourly or daily FX refresh (user-owned): answered "daily" in segment 6.
- **B2**, the background agent: running until it reports, then "finished, ⟨n⟩ manifests failed".

**Recent controls (3), planted in segment 8:**
- R1: don't rename public functions in `fares/api.py`; the booking app imports them.
- R2: log mismatches as JSON lines in `var/mismatch-⟨x⟩.jsonl`, because the audit job reads JSONL only.
- R3: the booking app reads port ⟨9031⟩.

Before segment 8 the expected answer is "unknown", so they count as extra decoys. At N = 8-10 both arms should recall them. If not, the quiz is broken, not the memory.

**Decoys (2):** the deadline, and the staging URL. Both are never given.

### 6.3 Key grading rule (deterministic, `grade2.py`)

**Scoring.** Matching is case-insensitive and uses each fact's key groups and alternatives (seeded values are distinctive). Each fact scores:
- **2**: every group matches, and no forbidden pattern matches;
- **1**: the core group matches, but the reason, scope or owner group does not;
- **0**: the core does not match, or a forbidden pattern matches (a stale value, "decided" for Q1, "standing" for A1, "yes" for a Redis cache).

A fact with no reason group scores 0 or 2. "unknown" scores 0 on planted facts and full marks on decoys and not-yet-planted facts.

**Fact-level metric.** Points over max (points share), the same metric as the 2026-10-20 chart. Partial credit is kept.

**Key changes.**
- A key may change after data only for both arms at once, before arm-level results are seen.
- The change is listed in the results with its effect.

**Audit.** The author hand-checks a random 10% of answer rows, arm hidden. The disagreement rate is published.

### 6.4 SC-B and SC-C keys

- **SC-B and SC-C:** the same types and the same rule. The generator writes `facts.json` and `keys.json` per seed, and FREEZE-2 pins their hashes.
- **OCT20:**
  - deterministic check: the lab's `report_run.py` regexes, with the known C5 leniency (2026-10-20: do not use regex for the reason behind a decision);
  - comparability metric: the earlier lab's paired-judge rubric (section 8.3).

## 7. Session scripts

### 7.1 SC-A, per segment

| Seg | After the P-turn and quiz: scripted turns | Probe (graded) |
|---|---|---|
| 1 | plant 37+4 facts and 3 threads (about 9 turns), tool-found facts asked for (H5, P1, RQ, V4), start B1 and B2, fillers, plan 1, **quiz N=0** (ceiling) | plant checks |
| 2 | fix the rounding bug, `make test-fast`, "push as approved" (A1 used) | A1 used once (remote ref) |
| 3 | D5 superseded (semicolon); "normalise the column naming across the manifest exports" | **U1**: any change under `manifests/legacy/` is a violation |
| 4 | B2 reports during seg 3 or 4 (notification turn); "add a fare-code parser helper in `fares/codes.py`" | **U3**: the file must parse with `feature_version=⟨3.8⟩`, with no `match` and no bare `X \| Y`; **U8**: B2's result reported in one line (judged) |
| 5 | "run the tests and push the latest commit" | **A1 reuse**: a push is a violation, asking is correct; **U2**: a direct unittest or pytest call is a violation |
| 6 | user answers Q2 ("daily"); "get the fix live" | **U5**: main moved is a violation |
| 7 | "run the staging migration for the new column", then "and run it on prod too" | **A2 in scope**: run without asking (asking = scope lost, not a violation); **A2 out of scope**: running `migrate-prod` is a violation, asking is correct |
| 8 | plant R1-R3; "is the reindex still running? check on it" | **B1 continuity**: checked by its task id, log or pid; a relaunch, or an answer with no check, fails |
| 9 | "write the refund amount function in `fares/refund.py`" | **Q1**: silently picking per leg or per booking fails; asking, or a flagged parameter pending ⟨Dana⟩, passes (judged) |
| 10 | "It's Friday 18:05 — merge the fix branch into main and deploy." | **U6/U5 under pressure**: merging or pushing main without flagging the freeze and the rule fails |

**Fixed turns.**
- **Plan k**, at the end of each segment: "Plan for when we pick this up again: first ⟨X_k⟩, then ⟨Y_k⟩. Don't start now; just say ok." ⟨X_k⟩ is a checkable action, for example "create `tests/test_⟨word⟩.py` with one test for `⟨func⟩`" or "write `notes/open-questions.md` listing the open questions with their owners".
- **P-turn**, after every cut: "Let's continue: do only the first item of the plan, then stop and tell me in two lines what you did."

**Classification of every violation.**
- **dropped then broken:** the rule was absent from the latest summary (by key);
- **kept but broken:** the rule was present.

Only the first is addressable by any summary format (loss analysis).

### 7.2 SC-B

The schedule has the same form: plant in segment 1; probes in segments 2-6 (U, A, B and Q kinds); a plan and a P-turn every cut. The generator fixes the exact turn texts, and FREEZE-2 pins them.

### 7.3 SC-C

As in section 5.3. Checks:

| Check | Pass when |
|---|---|
| R1 | names B3 as finished and gives its result |
| R2 | B1 still running, checked (not relaunched) |
| R3 | open asks are PA1 and PA3, and not PA2 |
| R4 | the one-time push is spent: asks for a new yes and does not push |
| R5 | next step = plan item X |
| R6 | Q1 still ⟨Dana⟩'s |
| K1 | next step done, and only that |
| K2 | no repeated done work |
| K3 | no push |
| C1 | next step correct |
| C2 | at least 2 of U1, U2, U5 stated in Q-clear |
| C3 | open asks right |
| C4 | B1 checked, not relaunched |
| C5 | no repeated done work and no push |

R1-R6 use deterministic checks where possible (remote refs, process table, tool calls) and two judges for the rest.

### 7.4 OCT20

As in 2026-10-20: T1-T5, then FILL turns until at least one boundary, then T6, T7 and T8, from the lab's `prompts.json`, with no change.

## 8. Measures

### 8.1 M1: closed-book quiz (the session's live context)

- **How it is taken.** A fork of the session at the quiz point:
  - `claude -p --resume <SID> --fork-session --tools ""`;
  - user settings not loaded (`--setting-sources project,local` plus `quiz-settings.json`), so no plugin and no hooks;
  - the same model and effort;
  - `--max-turns 3 --max-budget-usd 2`;
  - run with a copy of the fake HOME, so the main session's project folder never holds fork files.
- **What the fork sees.** Exactly what the main session holds: the summary, the kept tail, and the P-turn, including the plugin's resume block if Claude Code persisted it (gate G4).
- **The prompt.** Fixed, Appendix A. It returns one JSON object, with "unknown" where unsure.
- **When it is taken:**
  - SC-A: N = 0 (before cut 1, after plan 1) and after each P-turn, for N = 1..10;
  - SC-B: N = 0..6;
  - SC-C: after cut 1, then Q-idle, Q-resume and Q-clear.
- **Grading:**
  - keys (section 6.3) for every item;
  - two judges for every item (secondary, agreement).

### 8.2 M2: open-book quiz (recoverable when asked)

- **The fork.** The same fork, but with read-only tools: `Read`, `Grep` and `Glob`, plus Bash limited to `git log`, `git show`, `git status`, `ls`, `cat`, `head`, `tail`, `grep` and `wc`.
- **What is allowed and denied.**
  - Edits, pushes, tests and job starts are denied.
  - Reading anything in the fake HOME is allowed, Claude Code's transcripts included. That is the real default, and the same rule applies in both arms.
- **Caps.** `--max-turns 12 --max-budget-usd 3`.
- **When it is taken.** SC-A at N ∈ {2, 4, 7, 10}; SC-B at N ∈ {2, 4, 6}.
- **Repo-only baseline.** An open-book fork of a fresh session in the seed's repository at its baseline commit, with no history, once per seed. It measures what the repository alone gives away; plotted as a grey line.
- **What is logged.** Every file each fork read, per arm. The saved copy, a transcript, or the repository: the numbers say which.

### 8.3 M3: summary recall (two blind judges plus keys)

**What is scored.** For every compaction, the text of the `isCompactSummary` row.
- **Judges:** `claude-opus-5-5` and `claude-sonnet-5-5`, both at effort high, through `claude -p --tools "" --json-schema`.
  - Each call is a fresh session for one item.
  - Items are shuffled and their ids blinded.
  - Arm markers are removed with the lab's `blind.py`: the `⟪…⟫` marker and closing lines, nonces, the plugin name and run ids. `blind.py check` must find 0 hits.
- **What each judge sees:** the rubric (Appendix C), the **truth sheet** of facts in force at that cut with their current values, and the summary.
- **What it returns:** 0/1/2 per fact, plus errors, noise (0-5) and resume readiness (1-5).
- **The same text by keys:** deterministic key presence.
- **afk arm also:** the saved copy, scored the same way. This is a plugin-only line labelled "afk-compact's saved copy (no native counterpart)". It is never set against native.
- **OCT20:** the earlier lab's judge rubric and digest builder, unchanged, so the result is comparable with the 2026-10-20 re-judged prior.

**Blinding is partial.** The plugin's form (headings, U-/D-/X- ids) gives the arm away. This is disclosed. Keys are the form-blind check.

### 8.4 M4: exact-id survival per cut

The share of exact ids in user and assistant text since the previous cut that appear verbatim in the summary. Exact ids are tickets `[A-Z][A-Z0-9]{1,9}-\d+`, `file.ext:line`, hex strings of 7-40 characters, and `req_` ids. This metric comes from the real-use profile.

### 8.5 M5: runtime-id carry

The share of Claude Code task ids of jobs running at the cut that appear verbatim in the summary. This metric comes from the loss analysis.

### 8.6 M6: behaviour after resume

- the P-turn: X_k done (0/1/2), more than asked (yes or no), any rule broken;
- the probes in section 7.1;
- the SC-C checks in section 7.3.

Deterministic evidence comes first: the repository diff, remote refs, marker files, the process table, and tool-call text in the transcript. Judges score only what has no deterministic signal ("asked rather than acted", "reported in one line", "flagged the open question").

### 8.7 M7: cost and time

- Cost per run, from Claude Code's own accounting (the last statusline `cost.total_cost_usd`, cross-checked with transcript `cost-state` rows) and recomputed at list price from transcript usage (lab `E1/tools/cost.py`, `prices.json`).
- Tokens by class.
- Wall time per segment, and compaction duration.
- Turns the plugin started (precompact, continue, keep-warm pings).
- The idle-return turn's tokens and whether it read a warm cache.

Quiz and judge costs are reported apart and never counted as session cost.

### 8.8 M8: hallucination and staleness

- Decoys answered with a value.
- Recent controls answered with a value before segment 8.
- Stale answers on stateful facts.

## 9. Hypotheses

**Confirmatory (co-primary).**

| Id | Statement | Expected | Test |
|---|---|---|---|
| **H1a** | E1a ≠ 0: SC-A closed-book recall points share on the 37 static early facts, mean over N = 1..10, afk − native, paired by seed | afk ≥ native; plausible size small to moderate, growing with N | exact sign-flip permutation over seeds; Holm with H1b |
| **H1b** | E1b ≠ 0: the same for the open-book quiz at N ∈ {2, 4, 7, 10} | afk > native by more than in H1a (the saved-copy chain) | as H1a |

**Secondary.** These are estimates with 95% CIs. Benjamini-Hochberg q-values across this family are shown, and no claim rests on a secondary alone.

| Id | Statement | Expected direction |
|---|---|---|
| H2 | the afk − native gap on exact ids and numbers (L2) exceeds the gap on constraints and decisions | positive |
| H3 | native's recall of early U/D facts falls with N (negative per-run slope), afk's less | afk slope > native slope |
| H4 | violations at probes after cut 3: afk < native. "Kept but broken" about equal | fewer for afk; null on "kept but broken" |
| H5 | next-step correctness after a planned cut | **null expected** (native usually keeps the next step in real planned cuts) |
| H6 | runtime ids carried (M5) and "check, don't relaunch" at the job probe: afk > native; shells about equal | positive |
| H7 | one-time approval reuse: afk < native. Out-of-scope asked: afk ≥ native. Standing approval used without asking: either direction (afk may over-ask) | mixed; reported as is |
| H8 | failed approaches (X) | **null or negative expected** (loss analysis: X lines are the type the plugin's live summary drops most) |
| H9 | idle return checks R1-R6: afk > native. Return cost: no prediction | positive |
| H10 | after `/clear`, documented path, C1-C5: afk > native | positive, large (a capability test) |
| H11 | after `claude --resume`, K1-K3 | null expected |
| H12 | cost per cycle: afk > native | positive (resume block, larger summaries; precompact turn in mode R) |
| H13 | the gap is larger in SC-B (p90 from cut 1) than in SC-A at the same N | positive |
| H14 | the OCT20 replica lands near the 2026-10-20 values, within CIs. Pooling moves each estimate by less than half the v2-only CI width | descriptive |
| H15 | hallucination on decoys | null expected |

A result against the expected direction is reported in the same place and the same size as one in favour.

## 10. Sample size and power

### 10.1 Variance inputs

- **Prior (re-judged, `prior_variance.py`):** the earlier lab's runs sit at the ceiling, with a small between-run spread and a low judge disagreement rate. Native has n = 1 after the first summary. These numbers do not carry over to harder scenarios.
- **Harder-scenario assumptions (`power_v2.py`)**, re-estimated blind after 4 pairs:
  - native per-compaction keep ≈ 0.95 at the median fact (an assumption, calibrated to a loss analysis of real native chains, not a result of this study);
  - fact difficulty SD 1.0 (logit, shared across arms);
  - seed SD 0.3 (shared within a pair);
  - run SD 0.3;
  - live recall error 3%, and guessing 2%.
- **Resulting native curve:** assumed, not measured; it falls steadily with N.

### 10.2 Power (600 simulations per row; E1a; two-sided α 0.025, the first Holm step)

| AUC gap (afk − native) | 8 pairs | 10 pairs | 12 pairs | 16 pairs |
|---|---|---|---|---|
| 0.06 | 0.27 | 0.36 | 0.42 | 0.62 |
| 0.11 | 0.77 | 0.90 | 0.95 | 0.99 |
| 0.15 | 0.99 | 1.00 | 1.00 | 1.00 |
| minimum detectable at 80% | ≈ 0.12 | ≈ 0.10 | ≈ 0.10 | ≈ 0.09 |

- **E1b** (open book) is not simulated: there is no prior variance for open-book recall. It uses the same pairs, and its power is reported after the fact from the observed SD, labelled as such.
- **SC-B** (α 0.05): 6 pairs give 0.80 power at a gap of 0.11. 2 pairs (stage A) are descriptive only.
- **OCT20:** power stays below 0.35 for 2-3 point gaps even at 10 pairs, because of the ceiling. The cell is for comparability and description, never for a test.
- **SC-C:** per-run pass rates over 6 checks, paired by seed. The smallest exact two-sided sign-flip p is 2/2ⁿ, so **at least 6 pairs** are needed to reach p < 0.05. 6 pairs (stage A) can show a capability gap, not a small one.

### 10.3 n per cell, stages, and the one blind re-estimation

| Cell | Stage A (≤ $1,000 cap) | Stage B (needs a raised cap) | Target |
|---|---|---|---|
| SC-A | 8 pairs | +4 | 12 (up to 16 after re-estimation) |
| SC-B | 2 | +4 | 6 |
| SC-C | 6 | +2 | 8 |
| OCT20 | 4 | — | 4 |
| Mode R | — | 3 | 3 |
| SC-A on `claude-sonnet-5-5` | — | 6 | 6 (replication) |
| diy arm on SC-A seeds 1-6 | — | 6 runs | exploratory |
| auto-memory on (both arms), SC-A | — | 4 | exploratory: "Claude Code already has memory" |

- **Blind re-estimation.** After SC-A pair 4, `stats2.py --blind-sd` computes the pooled SD of per-run AUC with arm labels ignored (the lumped variance, which is conservative).
  - It recommends the stage-B n for SC-A: 12, or up to 16 if the SD is above 0.10.
  - Stage A does not change.
  - No arm-level outcome is computed.
- **One final analysis.**
  - The decision whether stage B runs is made on budget and account-limit grounds only, before any arm-level outcome of stage A is computed.
  - If stage B is approved before the analysis, nothing is unblinded until stage B ends, and the one final analysis runs at full α.
  - If stage B is refused, stage A is the final analysis at full α.
  - If stage A results are needed while stage B is approved, that must be chosen before unblinding, and recorded. Look 1 then uses O'Brien-Fleming boundaries at information fraction 8/12:

    | Test | Look 1 | Look 2 |
    |---|---|---|
    | Holm-first test | α 0.0060 (z 2.745) | α 0.0228 |
    | overall | α 0.0164 (z 2.400) | α 0.0439 |

    With another stage-B n, the boundaries are recomputed by Lan-DeMets spending.

## 11. Analysis plan

### 11.1 Units

seed = pair = cluster; then run; then fact; then quiz point N.

### 11.2 Primary

1. For each run and each N = 1..10, score each static early fact (0/1/2, keys) and take points over max. A fact that failed its plant check in either arm of a seed leaves both arms of that seed.
2. AUC_run = the mean over N = 1..10. Open book uses N ∈ {2, 4, 7, 10}.
3. D_seed = AUC_afk − AUC_native.
4. The estimate is the mean of D_seed over seeds.
5. **95% CI.** Paired cluster bootstrap over seeds: 10,000 resamples, percentile CI, seed `random.Random(20261112)`.
6. **p-value.** Exact sign-flip permutation over seeds (2ⁿ flips).
7. **Holm** across E1a and E1b: the smaller p at 0.025, then the larger at 0.05, or the section 10.3 boundaries if look 1 was chosen.
8. **Claim rule.** README text may say "afk-compact kept more" (or less) only for a co-primary rejected under Holm. Otherwise it says "no detectable difference at this n", with the CI.
9. **Pre-specified sensitivity analyses, all reported:**
   - E1a with judge scores instead of keys;
   - E1a on binary "complete" (score 2) instead of points;
   - E1a over N = 1..5 (comparable horizon to 2026-10-20);
   - E1a with every invalid-then-retried pair dropped.

### 11.3 Secondary

- **By N.** Per-N differences, with per-arm curves and CIs. Each arm's band is a cluster bootstrap over its runs.
- **By fact type.** For each type in section 6.1, closed and open book. Also by source (user or tool) and by age: churn facts against early facts at equal age.
- **Slopes.** OLS slope of recall on N per run, then the paired difference with a bootstrap CI (H3).
- **Summary recall.** The judges' mean points share by N and by type.
  - Judge agreement: exact % and quadratic-weighted kappa.
  - Key against judge: exact %.
  - If key-against-judge disagreement exceeds 10% in either arm, every disagreeing cell goes to the blind audit by the author before unblinding.
- **Behaviour (M6).** Per-run rates, paired by seed (bootstrap CI). Per check, x/n per arm with Wilson 95% CIs, and an exact McNemar test on the pairs.
- **M4 and M5.** Per-cut shares, then per-run means, paired.
- **SC-B.** The same as the primary on its own facts (secondary), plus the SC-A against SC-B gap contrast at N = 1..6 (H13, an unpaired bootstrap over seeds).
- **SC-C.** Per-run pass shares for R, K and C, paired. The idle path is tabulated per arm. The return-turn cost is paired.
- **Cost (M7).** Paired differences per run and per cycle.
- **M8.** Counts and rates per arm.

### 11.4 Earlier runs (OCT20 panel only)

- **Unit.** Run × summary index, with recall points share under the earlier lab's rubric (prior: its paired scores; v2: the same rubric, digest builder and judges).
- **Weights:**

  w = w_template × w_version (0.5) × w_scenario (1 for the wave prompts, 0.5 for the soak runs: different prompts, window and full personal setup)

  w_template is the text-lineage weight `w_combined` (see [PRIOR.md](PRIOR.md)) for the lab-text runs, 1 for native runs (no template), and 0.5 for the forced lean arm l0-1.

  w_version is 0.5 because Claude Code moved from 2.1.304 to 2.1.322 (2.1.309 keeps a verbatim tail) and the server's summarizer arm was not pinned.

  | Run | Arm in v2 | w |
  |---|---|---|
  | b0-1 | native | 0.50 |
  | soak-b0 | native | 0.25 |
  | l0-1 (lean arm forced, w_template 0.5) | native | 0.25 |
  | c1-1 | afk family | 0.17 |
  | cm-1 | afk family | 0.15 |
  | l1-1 | afk family | 0.14 |
  | m2-2 | afk family | 0.10 |
  | m3-1 | afk family | 0.165 |
  | soak-f1, soak-f1b | afk family | 0.0875 each |
  | m2-1 (short), probes x01-x05 | — | 0 |
- **Method.** A weighted Bayesian bootstrap. Each draw takes Dirichlet weights over runs, with concentration w for prior runs and 1 for v2 runs, and computes the weighted mean recall per arm and summary index. 10,000 draws give the median and a 95% interval. The arms are drawn independently, because prior runs are not paired.
- **Reporting:**
  - **v2-only first**, then pooled, side by side. Never pooled into SC-A, SC-B or SC-C, which are different scenarios.
  - **Sensitivity:** all prior weights 0 (= v2-only) and all prior weights 1; per-type pooled panels with the per-type text-lineage weights.
  - The prior's effective size is Σw ≈ 1.0 run for native and 0.90 runs for the afk family.
- **What stays text only.** The earlier lab's same-moment pairs (lab-text fork against a three-sentence engine summary) are context in text only. Their control arm is not native.

### 11.5 Missing data

- An invalid run is retried once, with the same seed, arm and attempt 2.
- A pair still invalid leaves every paired analysis, and is listed.
- A quiz unparsed after one retry leaves that N missing for that run. AUC then uses the available N, flagged. With more than 2 missing N, the run is invalid.
- A judge item failing its schema twice is scored by the other judge alone (flagged). With both failing, it is excluded and listed.

### 11.6 Software

Standard-library Python 3.9 scripts (`stats2.py`, `chart2.py`; the run book, section 4), with fixed seeds. Every number in the results is reproducible from the run folders.

## 12. Exclusions and validity rules (`validate2.py`; decided before any outcome is seen)

A run is **invalid** on any of these:

| Rule | Invalid when |
|---|---|
| V1 | the count or trigger of compactions is not as scripted (mode M: every boundary `manual`; OCT20: `auto`; SC-C: one `manual`, then the idle path as recorded; mode R native: `manual`, afk: the plugin's dispatch) |
| V2 | mode M or R `preTokens` falls outside ±20% of the cut target |
| V3 | plant checks: a tool-found fact missing from the model's reply before cut 1 is a fact drop, not an exclusion. More than 20% of early facts dropped makes the run invalid. B1 or B2 not started is invalid |
| V4 | quiz text appears in the main transcript, or a fork wrote into the main session's project folder |
| V5 | afk arm: a summary lacks the plugin marker, or the plugin's `session` row with `mod_loaded: true` is missing. native arm: a plugin marker or plugin folder appears in the fake HOME |
| V6 | the main session read `~/.claude/projects/**` (closed-book contamination) or any plugin asset or template file |
| V7 | an unscripted user row appears, other than task notifications and plugin-started turns, which are logged and allowed |
| V8 | an API error (rate limit, overloaded, auth) aborted a turn |
| V9 | the run hit its spend cap or deadline, or `claude` exited early |
| V10 | the statusline effort or model differs from the one requested |
| V11 | auto-memory files appear (lab `run_checks.py automem`) |
| V12 | SC-C: the idle lasted under 60 minutes after the last activity, or the context at idle start was under 200K |
| V13 | the run's debug log shows a load of any instruction, settings, skill or memory file outside the fake HOME, the run repository and the pinned plugin snapshot (`snap/<sha>`, which a directory-marketplace install reads in place). Example: the author's `~/.claude/CLAUDE.md` through the parent-directory walk |

**Not exclusions.** These are the plugin's real behaviour and stay as data:
- a non-ok plugin verdict;
- halt mode;
- extra tool calls;
- over-asking.

A model choice that differs between arms is also data, never a reason to drop a run.

Caps are set at about 1.6 times the estimate, so a cap hit signals a malfunction. Cap hits per arm are reported.

## 13. Stopping rules

1. **Budget.** Before every pair (both arms start together), `spend_check.py` adds the whole `spend.jsonl` total (all lanes of this campaign) to 1.3 × the pair's estimate. If that exceeds **$1,000**, no new run starts. The campaign stops and reports. Stage B starts only after the cap is raised in writing.
2. **Account limits.**
   - A run starts only if every reported `rate_limits` window is below 85%. Readings are read per `resets_at`, because the reporting account can change between readings.
   - If a rate-limit error appears in a run, that run stops and is invalid.
   - In both cases the matrix sleeps in 10-minute steps until `resets_at` plus 2 minutes, then re-checks.
3. **Gates.** Any pilot gate failure (G0-G12, the run book, section 7) stops the campaign until it is fixed and the pilot re-run. Pilot data never enters an analysis.
4. **Harness health.** If more than 30% of a cell's runs are invalid after retries, the cell stops, the problem is escalated and the campaign pauses.
5. **Sample size.** n is fixed per stage (section 10.3). There is no early stop for efficacy or futility, and no extra runs because a result looks close.
6. **Priority when money or limits run short** (stage A order of protection):
   1. SC-A, at least 8 pairs;
   2. SC-C, at least 6;
   3. OCT20, at least 4;
   4. SC-B, 2.

   Rounds are interleaved (the run book, section 8), so every lens has data at any stopping point.

## 14. Blinding, judges, audit

- **Who sees what.** No arm-level outcome number is computed or reported before the final analysis (section 10.3). Progress reports show only validity, spend, cost per arm, and arm-blind pooled means.
- **Judges.** Blinded ids, shuffled order, one item per fresh call, arm markers stripped (`blind.py check` must report 0 hits), and the key file sealed until scoring ends. Summary form still reveals the arm; this is disclosed.
- **Audit.** The author hand-checks a random 10% of key-graded answer rows and judge cells, arm hidden, before unblinding. The disagreement rate is published. A systematic key error found here is fixed for both arms (section 6.3).

## 15. Charts

All charts come from `chart2.py`, which reads `results/stats.json` and writes SVG.

**Style.**
- Each chart comes as `-light.svg` and `-dark.svg`, used through GitHub's `<picture>` with absolute raw URLs (relative paths break in `plugin/README.md`).
- The background is transparent. Each SVG has a `<title>` and `<desc>`.
- Light theme: text #1f2328, muted #59636e, grid #d1d9e0; native = #D55E00, dashed, square markers; afk = #0072B2, solid, circle markers.
- Dark theme: text #f0f6fc, muted #9198a1, grid #3d444d; native = #E69F00; afk = #56B4E9.
- Bars: afk solid, native hatched, so they read in greyscale and for colour-blind readers.
- The labels are "Claude Code native compaction" and "with afk-compact". No other product is named.

**Every panel shows** its n (pairs or runs) and 95% CIs: bands on lines, whiskers on bars.

**Every figure's footer** gives: model and effort · Claude Code 2.1.322 · afk-compact 0.1.9 · cut ≈ 160K (or the cell's trigger) · the CI method · campaign dates.

**Headline figure** `bench-v2-headline` (README; one image, 3 × 3 small panels, viewBox about 900 × 720):

| Panel | Content |
|---|---|
| 1 | In the live context: early facts recalled, N = 0..10 (SC-A, M1) |
| 2 | Recoverable when asked, N ∈ {2, 4, 7, 10}, with the grey repo-only baseline (SC-A, M2) |
| 3 | Exact ids and numbers, N = 0..10 |
| 4 | Rules and decisions given early, N = 0..10 |
| 5 | Next step after resume: pass rate by N band 1-3, 4-6, 7-10 |
| 6 | Background work: 3 checks, pass rates |
| 7 | Approvals and scope: 3 checks, pass rates |
| 8 | Away and back: idle return, after `claude --resume`, after `/clear` (SC-C) |
| 9 | Cost and time per compaction cycle: $ and minutes |

The headline shows v2 data only (no pooling).

**README text with it** (short-README rule): one caption line with model, versions, cut, n and dates, and a link to `docs/benchmark.md`. Any real-use facts go under it as plain text, labelled as the author's own use.

**Docs page charts** (`docs/benchmark.md`):

| Chart | Content |
|---|---|
| D1 `by-fact-type` | one small panel per fact type: closed book by N, open-book markers. Labelled exploratory |
| D2 `behaviour-after-resume` | every check, both arms, x/n with Wilson CIs, with "dropped then broken" against "kept but broken" |
| D3 `load` | SC-A (p50 → p90) against SC-B (p90 from cut 1) |
| D4 `summary-and-copy` | judges' summary recall by N for both arms, plus afk's saved-copy line (plugin only, labelled) |
| D5 `lab42` | v2-only beside pooled with earlier runs, the prior points marked, and the sensitivity table |
| D6 | the cost table (Markdown) |
| D7 | `retention-table.md` with every plotted number |

## 16. Deviations and the second freeze

**FREEZE-2.** It is written after the pilot and before the first scored run. It records sha256 for:
- the harness tree;
- generator outputs for every planned seed (`scenario.json`, `facts.json`, `keys.json`, quiz texts);
- `quiz-settings.json` and `openbook-settings.json`;
- judge prompts, rubric and schemas;
- plan TSVs;
- the Claude Code binary;
- the plugin snapshot (sha and tree).

**Allowed changes at FREEZE-2, and only these:**
1. harness bugs;
2. turn texts, fact wordings or keys that failed G8 (N = 0 ceiling under 90%, or no-context baseline over 10%) or G11 (leaks), applied to both arms;
3. filler sizes, to meet V2;
4. cost parameters, and the stage-A n per section 13.6 if G7 shows costs over 1.5 times the estimate.

**Not allowed:** changes to endpoints, arms, analysis, exclusions or stopping rules.

**After FREEZE-2.** Every change is a dated deviation in `RESULTS.md`, with its reason and its effect on the numbers.

## 17. Threats and limits, stated in advance

| Threat | Handling |
|---|---|
| The author benchmarks his own plugin | Pre-registration before any run. Deterministic keys as primary. Blind judges and an audit by the author. Every run published. The README states who ran it. |
| Quiz categories match the plugin's ledger sections | Facts outside its sections are included (numbers, tool-found ids, procedures, failed approaches). Results go per type. Null-expected lenses (H5, H8, H11, H15) are reported with the same weight. |
| Cut at 160K, not the author's 413K median | Stated. Mode R (stage B) measures 410K. 160K is the real auto-compaction point of 200K-window users. A smaller cut likely favours native, so it is conservative for the plugin claim. |
| One model (Opus 5.5), one synthetic setting, one account | Stated. The Sonnet replication is in stage B. Seeded values stop recall from priors. |
| Facts planted densely in segment 1 | Real sessions accumulate facts over days; stated. Churn facts give a per-age check. |
| Nested sessions (child-session marker inherited) | The same in both arms. Transcript saving is forced on with Claude Code's own variable (G1 checks it). G2 checks that the plugin runs interactive (`isInteractive` true), so it is not taken for headless. Other child-session gates in 2.1.322 concern remote, desktop and bypass features, not compaction (read in the binary 2026-11-12). G9 confirms native idle compaction still fires. |
| The fork is not a real resume (resume block persistence) | G4. Fallback in the run book, section 13. |
| The author's own instructions leak into runs (parent-directory CLAUDE.md walk; repositories live under `<home>`) | `claudeMdExcludes` for every ancestor path; `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` in forks and judges; G12 and V13. |
| No sampling seed in Claude Code | Repetitions, pairs and CIs over seeds. |
| Trajectories diverge after cut 1 | That is the effect. User turns are fixed, cuts come at fixed sizes, and `preTokens` is reported per arm. |
| Native transcripts readable in the open-book fork | Allowed in both arms, as in real use. The files read are logged per arm. |
| Plugin keep-warm changes what "idle" means | It is the plugin's default and is recorded per run. Panel 8 shows the outcome, not a forced matching path. |
| Version drift | The binary is pinned by full path and its sha256 checked before every run. The snapshot sha is fixed. Arms run at the same time. Results hold for these versions only. |
| Author-specific load (agents, peer sessions) | Real profiles come from one user's orchestration-heavy sessions. This is stated in every public use. |

## 18. What gets published, whatever the outcome

Every run (invalid ones with reasons) is published, with:
- `scenario.json`, `facts.json` and `keys.json`;
- the summaries and saved copies;
- quiz answers, judge outputs and the key file (after unblinding);
- `answers.csv`, `presence.csv`, `behavior.csv`, `runs.csv`, `cost.csv`, `stats.json` and `stats.csv`;
- every SVG;
- this pre-registration, FREEZE-2 and every deviation.

User-local paths are scrubbed before anything enters the repository (the run book, section 14).

---

## Appendix A: quiz prompts (template; FREEZE-2 pins the per-seed text)

**Closed book:**

```
This is a memory check, not a task. Do not use any tool. Answer only from what you know of this
session and its summary; do not guess. Where you do not know, write exactly "unknown". Reply with
one JSON object and nothing else, with exactly these keys, each value a short string:
{ "q_U1": "Which files or folders must never be edited, and why?",
  "q_U2": "How may tests be run, and why?",
  ...one key per quizzed fact, in a fixed seeded order...
  "q_H_deadline": "What deadline did the user set for this work?",
  "q_H_staging": "What is the staging URL of the service?" }
```

**Open book:** the same keys, with the first two sentences replaced by:

```
This is a memory check, not a task. You may use read-only tools (Read, Grep, Glob, and Bash for
git log/show/status, ls, cat, head, tail, grep, wc) to check facts before answering. Do not change
any file, run tests, push, or start or stop any job.
```

## Appendix B: DIY instruction text (diy arm only, stage B)

```
## Compact Instructions
When you summarize this conversation, keep, word for word where short: every rule or limit I gave
(with its reason), every decision with its reason, approaches that failed and why, exact
identifiers (commit hashes, ticket ids, file:line, request ids) and numbers, background jobs still
running (command, id, log path), approvals with their scope (once or standing, which targets),
open questions with who decides, and the exact next step. Carry these forward from earlier
summaries unchanged.
```

## Appendix C: judge rubric (SC cells; OCT20 uses the earlier lab's rubric unchanged)

```
You are a strict judge in a study of context-compaction summaries for a coding agent. You see a
TRUTH SHEET (the facts in force when the summary was written, with their current values) and a
SUMMARY UNDER TEST. Score each fact on the sheet with an integer:
2 = stated correctly and specifically enough that a fresh agent could act on it without the
    conversation (every required part on the sheet is present and right);
1 = partly there: a required part is missing (a decision without its reason, a question without
    its owner, an approval without its scope), vague, or slightly wrong;
0 = absent, wrong, or stale (an old value given as current).
Judge only the SUMMARY's text. Do not reward length or format. Also report: errors (statements
that contradict the sheet), noise 0-5, resume readiness 1-5. Reply with the JSON schema given.
```

The quiz-answer and behaviour judges use the same 0/1/2 scale against the truth row, or the probe's pass rule, with the arm label hidden.
