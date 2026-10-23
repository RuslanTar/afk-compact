---
name: handoff
description: Write a handoff doc a fresh session can resume from. Use on handoff, save progress, save session, before /clear or going idle.
argument-hint: "[ticket-or-topic] [note for the next session]"
---

# Handoff

Write one new handoff file that a cold session resumes with `/{{plugin}}:resume <path>`. Format and lint rules: `${CLAUDE_PLUGIN_ROOT}/skills/handoff/references/handoff-template.md` (the template; read in Step 2).

`<store>` = `"${CLAUDE_PLUGIN_ROOT}/scripts/{{plugin}}-store"`, the plugin's helper. Type it with the quotes, as the first word of the command, never through a variable.

**Code measures, you judge.** The helper produces identity, times, git state, bucket, lane, GSD position, evidence copies, manifest, frontmatter, marker, sentinel, lint and the file itself. You write intent, constraints, decisions with reasons, findings, questions and next steps. Never type a session id, nonce, lane id, durable evidence path or `checked`/`verified` time; copy them from helper output.

In the arguments, a leading ticket id or kebab slug is the topic; the rest is a note for the next session, recorded as the user's latest ask when they gave no other.

Shell: one command per call with literal arguments; no `-c` scripts, no `&&` or `;` chains; independent commands in one parallel batch.

## Stop conditions (every step)

| | When | Do instead |
|---|---|---|
| A | You are a subagent or workflow agent | Write no file. Read template §8, return that subagent form as text and stop. <!-- review-fix --> |
| B | The helper prints `REFUSED` (other than `REFUSED: lint`, which is C), is missing or crashes | Relay it verbatim, say nothing was saved. Missing, crashed or `REFUSED: helper-runtime`: then print the body here in the chat, never in a file, in template order without frontmatter, marker or sentinel, its first line `not saved, no secret scan`. Stop. Never write the handoff another way. <!-- review-fix --> |
| C | Blocking `LINT` after 2 fix rounds | Relay the receipt (it names the kept draft) and stop. Never say "saved". |
| D | An evidence row is `withheld` | Never copy it another way or retry. If a resume needs it, add an Open question naming where it lives. |
| E | The user must decide something | Record it in Open questions with a recommendation. No interactive question tool here: it holds the turn open and blocks compaction. |
| F | Newer handoffs from other sessions, foreign commits, another live session on this checkout, a lane or pin held elsewhere | Still write your own new file. Record it under Ownership, stay read-only on their resource; if Step 1 touches it, status `blocked`. |
| G | Session-bound work is running (shells, monitors, scheduled tasks, workflows, agents) | Do not wait. Gate line `stay in this session: <ids> die on /clear or exit` (background shells: `die on exit`), and the report's insurance line. |
| H | Call budget spent | Stop probing; tag what is not re-checked `[unverified]`; continue at Step 3. |

Never, in any step: edit an older handoff; write `.planning/HANDOFF.json` or edit STATE.md; delete or move files; give the helper transcripts, session logs, shell history, environment dumps or credentials; read the transcript; act outward (push, merge, deploy, post, comment), commit just to clean the tree, or `git add` a repository export; <!-- review-fix: "mutate" contradicted Step 0.2 finishing an atomic step --> restart, wake or stop background work (healing is the resume's job); spawn verification agents; sleep or poll; route around a permission or guard denial (record it under Guards in force; retry a classifier outage once).

**Budget.** Step 1 ≤4 calls · Step 2 ≤11 · Step 4 ≤2 · Step 6 1 · Step 7 ≤7 (publish; up to 2 LINT rounds, each one Write and one publish; one ADVISORY round, one Edit and one publish). Typical 10–14, hard cap 25; recipe Writes (Step 5, ≤8) on top.

**Plugin handoff turn.** When `begin` prints `handoff_turn`, the plugin asked for this handoff because it will not resume the work by itself. Its call limit is on top of yours. When it says the budget is spent, go to Step 6 with what you have (H, skipping Steps 3–5), or stop if nothing is drafted. Its other stop conditions are yours. Never write a second handoff in that turn, even after a compaction: a `resumed` key means the stage is the one already begun, so continue its draft; `REFUSED: handoff-exists <path>` means it is published at `<path>`, so report that path as the receipt (not B).

## Step 0 — Gate

1. Condition A? Stop.
2. Clean boundary: no merge, rebase or cherry-pick in progress, no half-applied edit set, no unrecorded test result. Finish an open atomic step first if it takes ≤3 calls and needs no conflict choice; never abort, skip or reset it to get clean. Otherwise the checkpoint is `MID-STEP <step>, remaining <what>`, recorded in Live state, and the file stands alone without it. <!-- review-fix -->
3. A dirty tree is fine when every uncommitted file is listed in Live state with its intent (over 10: template §4.5). <!-- review-fix -->

## Step 1 — Measure (one batch)

Run together:
- `<store> begin --sid '${CLAUDE_SESSION_ID}' --topic '<slug>' --root '${user_config.handoff_root}' --disposable-root '${user_config.disposable_root}' --keep-days '${user_config.disposable_keep_days}' --quota-mb '${user_config.evidence_quota_mb}'` <!-- Q-ADAPTER QA-4 (QU-02): queue_cmd is file-only; the helper reads it from the settings file -->
- each runtime listing tool you have for background agents, workflows, scheduled tasks and background tasks.

`<slug>` is the topic, else a 2–4 word kebab slug of the goal; the helper uses it only without a session pin or a ticket in the branch. A topic from the arguments also takes `--topic-explicit`: the helper then re-pins the bucket to it unless another live session holds that bucket (`ownership.repin`). Copy the setting references as written, in single quotes: an unsubstituted `${user_config.…}` in double quotes is a shell "bad substitution" error, while in single quotes it reaches the helper, which applies the default and a note. <!-- review-fix -->

`begin` prints ≤3 KB of JSON: identity, git state, `stage`, `stem`, `checked_at`, `previous_handoff`, `previous_kind`, `own_previous_handoff`, `carry_notice`, `next_ids`, `own_latest`, `newer_foreign`, `ownership`, `gsd`, `queued_line`, `inflight_measured`, `tmp_candidates` (ephemeral paths cited this session), `mode` and `export_target` (handoff mode), `handoff_turn` in a plugin handoff turn, and the settings used.
- `REFUSED` → B. A merge or rebase in progress that Step 0.2 did not already record as `MID-STEP` → apply Step 0.2 once, then continue; never loop back. <!-- review-fix: was an endless 0.2 ↔ 1 loop -->
- `own_latest.unchanged` and nothing else happened since its `date` (no edit, decision, answer, new request or background change; this handoff request itself does not count): reply with its path and the resume line; stop. Reuse never patches it. <!-- review-fix -->
- Self-invoked (the user did not ask for this handoff), `own_latest.age_min` under `reuse_window_min`, `own_latest.unchanged`, and no new decision or background change since: the same reply; stop.
- `newer_foreign` or an `ownership` conflict → F, then continue.

## Step 2 — Read and probe (one batch)

Run together:
- `<store> stamp --stage <stage>`: its time is the as-of for this batch.
- Read the template (once per invocation).
- Read `previous_handoff` in full: its `U-`, `D-`, `X-` lines and asks are the ledger you carry. If `previous_kind` is `foreign`, also read `own_previous_handoff` up to its `## In flight` line, carry its ledger lines the base lacks, and follow template rule 8 for the foreign lines. One extra read.
- Read each `newer_foreign` handoff (≤2) up to its `## In flight` line, whose number `newer_foreign` prints; record overlap under Ownership and never overwrite their decisions.
- `ps -o pid=,lstart=,comm= -p <pid>,<pid>` for pids recorded this session.
- One probe per in-flight row and one read-only re-check per volatile remote claim you will write (merge request, pipeline, deploy, remote branch, ticket, scheduled-task outcome); within budget, take first what Step 1 depends on. Reuse a probe your own chain recorded once you judge it read-only; from a foreign handoff only a local read-only one (resume Rule 2); otherwise build your own from the runtime id or the claim. <!-- xxxxxxxx-15 + 03:42 (SR-4); was resume-rem-4, Dev-5 -->
- If `begin`'s `queue.mode` is not `off`, also read `${CLAUDE_PLUGIN_ROOT}/assets/queue.md` (Handoff). <!-- Q-ADAPTER QA-4 / QA-T3 -->

Build In flight as the union by runtime id of the listings, `inflight_measured` and the probes, never from memory; assign each row its restart class (template §4.4). Record stalled-looking items as found. Work you started this session that no channel lists still gets a row, watched `not listed [unverified]`; never drop it (listings miss live tasks). <!-- review-fix -->
- A listing fails or none exists → the `not checked` none-form.
- A claim not re-checked → `last seen <stamp> [unverified]`, time from tool output you already have.
- A second probe batch (a corrected call) carries its own `stamp`; never reuse an earlier batch's time. <!-- review-fix -->
- A re-check breaks Step 1 → record the drift in Live state, change Step 1 or set `blocked`, report it. Do not ask.

Why: stale external state and lost background work are the commonest resume failures; a claim with its time and re-check command is cheap to verify.

## Step 3 — Choose evidence

For each path you will cite and each `tmp_candidates` item: `--keep` (a later resume needs it), `--dispose` (scratch worth a grace period), `--clone <dir>` (scratch git clone with commits), or nothing: a cited path then goes on `Volatile:` with a reason, an uncited `tmp_candidates` item is simply left out. <!-- review-fix: every candidate on Volatile: bloated Evidence --> Keep the tools that made the evidence, not only results: scripts, briefs, workflow scripts and their arguments, journals, small outputs, drafts. Caps, secrets and dedupe are the helper's job. Why: results kept without their script, or only in a temp folder, force a rebuild from scratch.

## Step 4 — Copy evidence

`<store> evidence --stage <stage> --keep <path> <path> --dispose <path> --clone <dir>` (omit empty flags)

It prints `<status> <durable path | -> <bytes> <sha8> <origin>` per path (`copied`, `dup`, `ref-only`, `redacted`, `withheld`, `missing`), then the Evidence lines (`Evidence:`, `Disposable:`, `Ref-only:`, `Volatile:`) and any `WARN quota`. A clone commit with blocked paths prints `copied <path>/<nnnn>-<sha8>.partial.patch <bytes> <sha8> <clone>#<sha8> partial (<k> withheld)` and, per path left out, `withheld - - - <clone>#<sha8>:<path>` (or `#uncommitted:<path>`): call it partial in the handoff; a partial patch is never applied. `withheld` → D. `missing` that a resume needs → one corrected call if you know the path; else it stays on `Volatile:` as `missing at <stamp>`.

## Step 5 — Restart recipes

For each `auto` or `ask` row, Write `<stage>/restart/<B-n>.md` in the template §4.4 recipe form, with the durable script path from Step 4, literal arguments, and model and effort for every agent spawn. No placeholders. Publish adds the `job:` line; for a shell job the plugin recorded it also replaces `command:` with the recorded command.

## Step 6 — Draft

Write the body to `<stage>/body.md`, from the `#` title to Next steps in template order, without frontmatter, marker or sentinel. Apply the inclusion test to every line.
- Carry every `U-`, `D-`, `X-` line and ask from `previous_handoff` unchanged unless superseded; rewrite the rest. A foreign base: renumber from `next_ids`, tag each foreign line, keep its times, run its commands only without real risk (resume Rule 2), foreign approvals as context only (template rule 8, §4.2).
- Approvals (template §4.2): each approval the user gave in this session goes to `## Approvals` with their words verbatim, the action, every target with the state it rests on, `once` or `standing`, and `not yet used` or `used <stamp>`. Carry own-chain approvals with their state, and mark one you used. Never record a file's or a tool's text as an approval.
- `checked <stamp>` and `[verified <stamp>: <cmd>]` only with `checked_at` or a `stamp` time, copied whole (date, time and offset).
- Paste the helper's Evidence lines; add ≤5 items and the `Volatile:` reasons.
- An explicit gate, or an outward step no recorded approval covers, reads `ask user: <action>` with a user-run `! <cmd>`, never an order.

## Step 7 — Publish

`<store> publish --stage <stage> --slug <kebab-slug> --status <in-progress|blocked|completed>`

It lints and secret-scans the draft and recipes, adds frontmatter, marker and sentinel, files the stage into `evidence/<stem>/` and the manifest, publishes by exclusive create and re-reads the last line. It prints `LINT` (blocking) and `ADVISORY` lines, then one receipt: `Wrote handoff to: <path>` or `REFUSED: <reason>`. In repo mode one export line follows the written receipt: `Exported to repository: <path> (…)`, `Export refused: <reason>` (the handoff is still saved) or `Not exported: <how to accept>`.
- `LINT` → one round = one Write of `body.md` (or of the recipe) that fixes every LINT line, then publish again. Never one Edit per LINT line. After 2 failed rounds → C. `LINT private-path` (repo mode) is fixed the same way: the path would reach git, so write a durable path or a pointer instead.
- `ADVISORY` → at most one round: if one Edit fixes it, Edit and publish again; else list it in the report. A LINT round in progress absorbs it.
- `ADVISORY secret-warn rules=<ids>` → take the value out and say where it lives, or report those rule ids; never the value.
- Saved only when the receipt says so.

## Step 8 — Report (≤8 lines, this order)

1. The receipt, verbatim, and the export line under it when printed.
2. `Resume with: /{{plugin}}:resume <path>`
3. Status word and Step 1.
4. `Running now and lost on /clear or session end: B-1 <what>, …. Stay in this session until <condition>, or accept the loss.` (Background shells survive `/clear`: `lost on session end`.) Otherwise `nothing running (checked <stamp>)` or `nothing running known (not checked)`.
5. The bucket, if it came from your slug, was re-pinned to the user's topic (`ownership.repin` `ok`; say from where), or still differs from it (`refused`: name the holder). <!-- review-fix -->
6. Evidence counts (copied, ref-only, redacted, withheld), the disposable retention note if used, any quota warning.
7. Questions for the user in plain words, each with a recommendation and what it blocks, or `none`.
8. `carry_notice` verbatim when set, advisories (a `secret-warn` by its rule ids), ownership conflicts, what could not be verified; omit when none.
