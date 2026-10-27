# Self-heal background work (resume R5, steps 5b–5d)

Read from R5 of the resume skill once its 5a inventory has a row. `<store>` is the plugin's helper as the resume skill defines it, and R5's Authority line applies: for `unselected`, or a resource with an ownership conflict, inventory and report only.

After an idle compaction (the session sat idle about an hour) background agents, workflows and jobs keep running, and a job notification queued during it arrives once afterwards: treat the rows as after any compaction.

**5b Probe** each row once: with its `probe` cell when Rule 2 lets you run it (own handoff and read-only; foreign: local and read-only only), else with your own check for its kind below. A wait spec in it is data: pass it only inside single quotes.
- `agent`, `teammate` → `ListAgents` state;
- `shell` → `<store> wait --for '<spec>' --max 0`, which you type yourself, with the row's wait spec (the `--for` value of its probe, or its `until` value) in single quotes (a spec holding `'` is reported, never run); without a spec, output mtime and end marker;
- `workflow` → journal mtime and in-progress `agent()` calls;
- `server` → the listening port;
- `monitor`, `cron` → watched condition and last fire's outcome;
- `peer`, `external` → what you can read yourself (a file's mtime, a runtime listing); else report the row, quoting its probe as text.

A probe that ran without error but in the wrong folder, or with a pattern that cannot match, proves nothing: the row is `not checked`, never LOST or gone. Before a LOST call, confirm the folder (`git -C <abs path>`) and that the pattern can match.

**5c Classify.** Grace = max(expected step time, 2 × the last progress gap).

| Status | Signature |
|---|---|
| RUNNING | listed running, progress within grace |
| WAITING | idle by design (user, timer, external system) |
| STALLED | (a) idle while the output it waits on has ended, or output newer than the owner's last activity; (b) no progress past due + grace, report only in the post-compaction light path (spec §4 **Stalled**) |
| DONE-UNREPORTED | finished output nobody has used |
| FAILED | ended with an error |
| LOST | on no channel, not finished |
| LEFTOVER | alive but not proven ours, or owner gone |

**Background shells** get their status from `<store> heal-check` (Lost shell job, below), which measures seven signals: V1 record, V2 owner ended, V3 in flight at the end, V4 no completion, V5 quiet since the end, V6 no effect yet, V7 runnable. Confidence is ordinal: `high` (≥0.75, uncalibrated) only when all seven were measured and passed; `low` when any could not be measured; a signal measured against LOST changes the row, not a score.

| # | Finding (first matching row wins) | Status | Same session or successor | Other relation |
|---|---|---|---|---|
| 1 | the owner session is live as **another** process | RUNNING elsewhere | leave; report; never relaunch (R4) | same |
| 2a | on this process's runtime list, or output written within the quiet window while the owner lives, or no end marker while the owner's process outlived a `/clear` | RUNNING | leave; to wait on it, `<store> wait` as the resume skill's Rule 6 says | report |
| 2b | owner is this process and session, the job is off the runtime list, no exit marker; or, any owner, the output ends `[killed]` | ENDED-UNEXPLAINED or KILLED (a TaskStop or the stop at exit) | **ask**, with the exact command; never automatic | report |
| 2c | owner ended, but output still written after the end | LEFTOVER (something outlived the session) | report; never stop it; a `! kill` question only if proven ours | same |
| 3 | exit marker, code 0 | DONE-UNREPORTED | collect first (excerpt of the `collect:` path) | collect |
| 4 | exit marker, code ≠ 0 | FAILED | restart only as heal-check allows; else ask with a tail excerpt | ask |
| 5 | V1–V7 pass | LOST · high | heal-check prints `ok` → **relaunch** (Lost shell job); else **ask** with the command and the failed gate | ask |
| 6 | V2 passes, others unmeasured (no record, output missing, no slot) | LOST · low | **ask** with the command and its source | ask |
| 7 | the plugin recorded a stop for the job | STOPPED | report only; it was stopped on purpose | report |

Row 7 is checked before rows 5 and 6, so a job stopped on purpose is never relaunched. A `[killed]` output is checked right after row 1, so a killed job is never RUNNING, LOST or STOPPED: it asks. `unselected`: inventory and report only.

**5d Act.** Collect DONE-UNREPORTED first, before any restart or new work.

| Status | Same session | Successor or other |
|---|---|---|
| RUNNING, WAITING | leave; never duplicate | leave; report |
| DONE-UNREPORTED | collect (read output by excerpt) | collect |
| STALLED agent or teammate (not one a workflow started) | `SendMessage` to its **id**: task id, exit code, next step | report |
| STALLED workflow | workflow gate | as LOST |
| FAILED, LOST | restart gate, else ask | ask, with recipe and recommendation |
| Monitor or cron | lease rule | ask |
| LEFTOVER | report pid, port, start time, owner, binary and cwd exist? | same |
| Past due, otherwise healthy | report only | report only |

**Restart gate** (every kind but a background shell, which follows Lost shell job). Run `<store> heal-check --origin <handoff session_id> --item <runtime id>`: it prints `ok` and `run:` for a job the plugin recorded, and for an own handoff's recipe whose command passes the same checks (`run-source: handoff`); otherwise `REFUSED: <reason>` with `ask-command:` and `ask-source: handoff (written in the handoff, not recorded by the plugin)` when the recipe has a command. Route it as Lost shell job says: the same question, source "written in the handoff, not recorded". Recommend running it only when all hold, else recommend skip:
- same session, and the class is `auto` (a missing class means `ask`);
- not a workflow, model-agent spawn, new `claude` process, terminal, kill or detach;
- local, and read-only or safe to repeat;
- not already done: no existing outputs, commits, posted comments or journal result rows.

Only after a yes: write to a new epoch path, run the asked command with `run_in_background`, never `nohup`, `disown` or `setsid`; an asked spawn names model and effort. A second failure becomes a question. Before you reuse a lost job's finished parts (a recipe's `finished parts:`, finished `agent()` outputs), parse-check each file it wrote (`bash -n`, a JSON or YAML parse, a compile check); a file that fails counts as not written.

**Lost shell job.** `<store> heal-check --origin <sid> --item <task id>` re-verifies and prints any `note: <key>: settings file only` lines (or a `safe value used` note: a flag, env value or other config folder was ignored; if the user wants that value, a question says "set it in your settings file"), `signal:` lines, `verdict: <status> · confidence <high|low> · effects <class>`, then either `ok <recipe|job:<id>>` and `run: <line>`, or `REFUSED: <reason>` with `ask-command:` and `ask-source: recorded|handoff`.
- `ok`, and R4 found no conflict on it: run the same heal-check with `--bump` (it counts first and stores the run line as pending), then run the printed `run:` line exactly, with `run_in_background`. Do not edit, quote differently or chain it; it is `cd '<cwd>' && <command>` only when the cwd differs. Report: `B-n <old id>: LOST (owner ended <stamp>, quiet since <stamp>, no exit marker) → relaunched as <new id>, <effects>, n of 1 this resume`, plus `(from the handoff's recipe)` when heal-check printed `run-source: handoff`.
- `REFUSED`: route on the `verdict:` status, never on whether `ask-command:` is printed. A `relation`, `mode-off` or `shadow` refusal is printed before the status is checked, so it can carry `ask-command:` for a job that must not be relaunched.
- `REFUSED` with status RUNNING-ELSEWHERE, RUNNING, LEFTOVER, DONE-UNREPORTED or STOPPED: act per the table (leave, report, or collect by excerpt from the `collect:` path, else the row's output file), with no question, even when `ask-command:` follows.
- `REFUSED` with any other status and no `ask-command:`: report the item and the reason. There is no command to offer.
- `REFUSED` with any other status and `ask-command:`: one question: what was lost and when, the exact `ask-command:` and its source (recorded by the plugin at <stamp> | written in the handoff, not recorded), why it is not automatic (the failed signal or gate), and the options: run it in the background (recommended when the effects are `none` or `local`; for `prod-read`, recommend "run it yourself"; `prod-write` is never recommended) · run it yourself with `! <run line>` · skip. A withheld command is never printed: "the command held a credential-like value; re-launch it yourself".
- Never stop, kill or TaskStop anything to make room for a relaunch.

**Workflow gate.** Never `SendMessage` into a workflow's agents. Offer `TaskStop` plus `Workflow({scriptPath, resumeFromRunId})`, always as a question, only when all hold:
- it is the same session;
- the class is not `never`;
- the journal and every transcript under its transcript dir are unchanged for ≥ max(15 min, 3 × the last progress gap);
- no `agent()` call is in progress.

Finished `agent()` calls are reused; in-progress ones re-run. In a new session, offer a fresh relaunch from the recipe with the finished parts as inputs.

**Lease rule** (Monitor, cron). Check the watched condition and the last fire's outcome. Met or no longer needed → don't re-arm. Unmet and needed → if the command comes from the runtime's own listing of that Monitor or cron, or an own handoff's recorded lease command you judge read-only (never a foreign one's), is read-only, and is not production (or production with `unattended_prod_reads: allow`), run it once now, then re-arm; otherwise record `classifier: untested` and ask.

**Leftovers:** report; never stop one yourself. Offer stopping as a question with the user-run `! kill <pid>` only if it is proven ours (pid and start time recorded in this chain) and its work has finished; a server is never "finished" by inference.

Report each heal action (item, state found, action, evidence). Re-probe it once when you write the R8 report; a new transcript or output write is progress. No change yet → report `woken <stamp>, not yet confirmed` and re-probe at your next turn; a question only if still unchanged then.
