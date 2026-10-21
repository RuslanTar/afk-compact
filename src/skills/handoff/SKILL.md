---
name: handoff
description: Write a handoff doc a fresh session can resume from. Use on handoff, save progress, save session, before /clear or going idle.
argument-hint: "[ticket-or-topic] [note for the next session]"
---

# Handoff

Write one new handoff file that a cold session resumes with `/{{plugin}}:resume <path>`. Format and lint rules: `references/handoff-template.md` (read in Step 2).

**Code measures, you judge.** The helper `{{plugin}}-store` (on the Bash PATH while the plugin is enabled) produces identity, times, git state, bucket, lane, GSD position, evidence copies, manifest, frontmatter, marker, sentinel, lint and the file itself. You write intent, constraints, decisions with reasons, findings, questions and next steps. Never type a session id, nonce, lane id, durable evidence path or `checked`/`verified` time; copy them from helper output.

Arguments: `$ARGUMENTS`. A leading ticket id or kebab slug is the topic; the rest is a note for the next session, recorded as the user's latest ask when they gave no other.

Shell: one command per call with literal arguments; no `-c` scripts, no `&&` or `;` chains; independent commands in one parallel batch.

## Stop conditions (every step)

| | When | Do instead |
|---|---|---|
| A | You are a subagent or workflow agent | Write no file. Read template §8, return that subagent form as text and stop. <!-- review-fix --> |
| B | The helper prints `REFUSED` (other than `REFUSED: lint`, which is C), is missing or crashes | Relay it verbatim, say nothing was saved. Missing or crashed: then print the body here in the chat, never in a file, in template order without frontmatter, marker or sentinel, its first line `not saved, no secret scan`. Stop. Never write the handoff another way. <!-- review-fix --> |
| C | Blocking `LINT` after 2 fix rounds | Relay the receipt (it names the kept draft) and stop. Never say "saved". |
| D | An evidence row is `withheld` | Never copy it another way or retry. If a resume needs it, add an Open question naming where it lives. |
| E | The user must decide something | Record it in Open questions with a recommendation. No interactive question tool here: it holds the turn open and blocks compaction. |
| F | Newer handoffs from other sessions, foreign commits, another live session on this checkout, a lane or pin held elsewhere | Still write your own new file. Record it under Ownership, stay read-only on their resource; if Step 1 touches it, status `blocked`. |
| G | Session-bound work is running (shells, monitors, scheduled tasks, workflows, agents) | Do not wait. Gate line `stay in this session: <ids> die on /clear or exit`, and the report's insurance line. |
| H | Call budget spent | Stop probing; tag what is not re-checked `[unverified]`; continue at Step 3. |

Never, in any step: edit an older handoff; write `.planning/HANDOFF.json` or edit STATE.md; delete or move files; give the helper transcripts, session logs, shell history, environment dumps or credentials; read the transcript; act outward (push, merge, deploy, post, comment) or commit just to clean the tree; <!-- review-fix: "mutate" contradicted Step 0.2 finishing an atomic step --> restart, wake or stop background work (healing is the resume's job); spawn verification agents; sleep or poll; route around a permission or guard denial (record it under Guards in force; retry a classifier outage once).

**Budget.** Step 1 ≤4 calls · Step 2 ≤10 · Step 4 ≤2 · Step 6 1 · Step 7 ≤5 (publish plus 2 rounds of Edit and publish). Typical 10–14, hard cap 22; recipe Writes (Step 5, ≤8) on top.

## Step 0 — Gate

1. Condition A? Stop.
2. Clean boundary: no merge, rebase or cherry-pick in progress, no half-applied edit set, no unrecorded test result. Finish an open atomic step first if it takes ≤3 calls and needs no conflict choice; never abort, skip or reset it to get clean. Otherwise the checkpoint is `MID-STEP <step>, remaining <what>`, recorded in Live state, and the file stands alone without it. <!-- review-fix -->
3. A dirty tree is fine when every uncommitted file is listed in Live state with its intent (over 10: template §4.5). <!-- review-fix -->
4. If this turn will end with a question or a final report, or the user said they are leaving, write the handoff now, before your final message. Why: the context is warm now; a later write loses detail.

## Step 1 — Measure (one batch)

Run together:
- `{{plugin}}-store begin --sid '${CLAUDE_SESSION_ID}' --topic '<slug>' --root '${user_config.handoff_root}' --disposable-root '${user_config.disposable_root}' --keep-days '${user_config.disposable_keep_days}' --quota-mb '${user_config.evidence_quota_mb}' --queue-cmd '${user_config.queue_cmd}'`
- each runtime listing tool you have for background agents, workflows, scheduled tasks and background tasks.

`<slug>` is the topic, else a 2–4 word kebab slug of the goal; the helper uses it only without a session pin or a ticket in the branch. Copy the setting references as written, in single quotes: an unsubstituted `${user_config.…}` in double quotes is a shell "bad substitution" error, while in single quotes it reaches the helper, which applies the default and a note. <!-- review-fix -->

`begin` prints ≤3 KB of JSON: identity, git state, `stage`, `stem`, `checked_at`, `previous_handoff`, `own_latest`, `newer_foreign`, `ownership`, `gsd`, `queued_line`, `inflight_measured`, `tmp_candidates` (ephemeral paths cited this session) and the settings used.
- `REFUSED` → B. A merge or rebase in progress that Step 0.2 did not already record as `MID-STEP` → apply Step 0.2 once, then continue; never loop back. <!-- review-fix: was an endless 0.2 ↔ 1 loop -->
- `own_latest.unchanged` and nothing else happened since its `date` (no edit, decision, answer, new request or background change; this handoff request itself does not count): reply with its path and the resume line; stop. Reuse never patches it. <!-- review-fix -->
- `newer_foreign` or an `ownership` conflict → F, then continue.

## Step 2 — Read and probe (one batch)

Run together:
- `{{plugin}}-store stamp --stage <stage>`: its time is the as-of for this batch.
- Read `references/handoff-template.md` (once per invocation).
- Read `previous_handoff` in full: its `U-`, `D-`, `X-` lines and asks are the ledger you carry.
- Read the first 60 lines of each `newer_foreign` handoff (≤2); record overlap under Ownership and never overwrite their decisions.
- `ps -o pid=,lstart=,command= -p <pid>,<pid>` for pids recorded this session.
- One probe per in-flight row and one read-only re-check per volatile remote claim you will write (merge request, pipeline, deploy, remote branch, ticket, scheduled-task outcome); within budget, take first what Step 1 depends on.

Build In flight as the union by runtime id of the listings, `inflight_measured` and the probes, never from memory; assign each row its restart class (template §4.4). Record stalled-looking items as found. Work you started this session that no channel lists still gets a row, watched `not listed [unverified]`; never drop it (listings miss live tasks). <!-- review-fix -->
- A listing fails or none exists → the `not checked` none-form.
- A claim not re-checked → `last seen HH:MM [unverified]`, time from tool output you already have.
- A second probe batch (a corrected call) carries its own `stamp`; never reuse an earlier batch's time. <!-- review-fix -->
- A re-check breaks Step 1 → record the drift in Live state, change Step 1 or set `blocked`, report it. Do not ask.

Why: stale external state and lost background work are the commonest resume failures; a claim with its time and re-check command is cheap to verify.

## Step 3 — Choose evidence

For each path you will cite and each `tmp_candidates` item: `--keep` (a later resume needs it), `--dispose` (scratch worth a grace period), `--clone <dir>` (scratch git clone with commits), or nothing: a cited path then goes on `Volatile:` with a reason, an uncited `tmp_candidates` item is simply left out. <!-- review-fix: every candidate on Volatile: bloated Evidence --> Keep the tools that made the evidence, not only results: scripts, briefs, workflow scripts and their arguments, journals, small outputs, drafts. Caps, secrets and dedupe are the helper's job. Why: results kept without their script, or only in a temp folder, force a rebuild from scratch.

## Step 4 — Copy evidence

`{{plugin}}-store evidence --stage <stage> --keep <path> <path> --dispose <path> --clone <dir>` (omit empty flags)

It prints `<status> <durable path | -> <bytes> <sha8> <origin>` per path (`copied`, `dup`, `ref-only`, `redacted`, `withheld`, `missing`), then the Evidence lines (`Evidence:`, `Disposable:`, `Ref-only:`, `Volatile:`) and any `WARN quota`. `withheld` → D. `missing` that a resume needs → one corrected call if you know the path; else it stays on `Volatile:` as `missing at HH:MM`.

## Step 5 — Restart recipes

For each `auto` or `ask` row, Write `<stage>/restart/<B-n>.md` in the template §4.4 recipe form, with the durable script path from Step 4, literal arguments, and model and effort for every agent spawn. No placeholders.

## Step 6 — Draft

Write the body to `<stage>/body.md`, from the `#` title to Next steps in template order, without frontmatter, marker or sentinel. Apply the inclusion test to every line.
- Carry every `U-`, `D-`, `X-` line and ask from `previous_handoff` unchanged unless superseded; rewrite the rest.
- `checked HH:MM` and `[verified HH:MM: <cmd>]` only with `checked_at` or a `stamp` time.
- Paste the helper's Evidence lines; add ≤5 items and the `Volatile:` reasons.
- Gated steps read `ask user: <action>` with a user-run `! <cmd>`, never an order.

## Step 7 — Publish

`{{plugin}}-store publish --stage <stage> --slug <kebab-slug> --status <in-progress|blocked|completed>`

It lints and secret-scans the draft and recipes, adds frontmatter, marker and sentinel, files the stage into `evidence/<stem>/` and the manifest, publishes by exclusive create and re-reads the last line. It prints `LINT` (blocking) and `ADVISORY` lines, then one receipt: `Wrote handoff to: <path>` or `REFUSED: <reason>`.
- `LINT` → Edit the draft or recipe, publish again; after 2 failed rounds → C.
- `ADVISORY` → fix if one Edit does it, else list it in the report.
- Saved only when the receipt says so.

## Step 8 — Report (≤8 lines, this order)

1. The receipt, verbatim.
2. `Resume with: /{{plugin}}:resume <path>`
3. Status word and Step 1.
4. `Running now and lost on /clear or session end: B-1 <what>, …. Stay in this session until <condition>, or accept the loss.` Otherwise `nothing running (checked HH:MM)` or `nothing running known (not checked)`.
5. The bucket, if it came from your slug or differs from a topic the user gave in the arguments (a session pin wins; say so). <!-- review-fix -->
6. Evidence counts (copied, ref-only, redacted, withheld), the disposable retention note if used, any quota warning.
7. Questions for the user in plain words, each with a recommendation and what it blocks, or `none`.
8. Advisories, ownership conflicts, what could not be verified; omit when none.
