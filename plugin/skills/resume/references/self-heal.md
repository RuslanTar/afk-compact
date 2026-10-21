# Self-heal background work (resume R5, steps 5b–5d)

Read from R5 of the resume skill once its 5a inventory has a row. `<store>` is the plugin's helper (`compactinue-store`), and R5's Authority line applies: for `unselected`, or a resource with an ownership conflict, inventory and report only.

**5b Probe** each row once, with its `probe` if read-only, else the default for its kind:
- `agent`, `teammate` → `ListAgents` state;
- `shell` → `<store> wait --for '<spec>' --max 0` with the row's wait spec in single quotes (a spec holding `'` is reported, never run); without a spec, output mtime and end marker;
- `workflow` → journal mtime and in-progress `agent()` calls;
- `server` → the listening port;
- `monitor`, `cron` → watched condition and last fire's outcome;
- `peer`, `external` → the row's own probe only if read-only, else report.

**5c Classify.** Grace = max(expected step time, 2 × the last progress gap).

| Status | Signature |
|---|---|
| RUNNING | listed running, progress within grace |
| WAITING | idle by design (user, timer, external system) |
| STALLED | owner idle while its awaited output has ended; or output newer than the owner's last activity; or no progress past due + grace |
| DONE-UNREPORTED | finished output nobody has used |
| FAILED | ended with an error |
| LOST | on no channel, not finished |
| LEFTOVER | alive but not proven ours, or owner gone |

**Background shells** get their status from `<store> heal-check` (Lost shell job, below), which measures seven signals: V1 record, V2 owner ended, V3 in flight at the end, V4 no completion, V5 quiet since the end, V6 no effect yet, V7 runnable. Confidence is ordinal: `high` (≥0.75, uncalibrated) only when all seven were measured and passed; `low` when any could not be measured; a signal measured against LOST changes the row, not a score.

| # | Finding (first matching row wins) | Status | Same session or successor | Other relation |
|---|---|---|---|---|
| 1 | the owner session is live as **another** process | RUNNING elsewhere | leave; report; never relaunch (R4) | same |
| 2a | on this process's runtime list, or output written within the quiet window while the owner lives | RUNNING | leave; to wait on it, `<store> wait` as the resume skill's Rule 6 says | report |
| 2b | owner is this process and session, the job is off the runtime list, no exit marker | ENDED-UNEXPLAINED (the user or a TaskStop may have stopped it) | **ask**, with the exact command; never automatic | report |
| 2c | owner ended, but output still written after the end | LEFTOVER (something outlived the session) | report; never stop it; a `! kill` question only if proven ours | same |
| 3 | exit marker, code 0 | DONE-UNREPORTED | collect first (excerpt of the `collect:` path) | collect |
| 4 | exit marker, code ≠ 0 | FAILED | restart only as heal-check allows; else ask with a tail excerpt | ask |
| 5 | V1–V7 pass | LOST · high | heal-check prints `ok` → **relaunch** (Lost shell job); else **ask** with the command and the failed gate | ask |
| 6 | V2 passes, others unmeasured (no record, output missing, no slot) | LOST · low | **ask** with the command and its source | ask |
| 7 | the plugin recorded a stop for the job | STOPPED | report only; it was stopped on purpose | report |

Row 7 is checked before rows 5 and 6, so a job stopped on purpose is never relaunched. `unselected`: inventory and report only.

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

**Restart gate** (every kind but a background shell, which follows Lost shell job). All must hold, else the item becomes a question:
- same session, and the class is `auto` (a missing class means `ask`);
- not a workflow, model-agent spawn, new `claude` process, terminal, kill or detach;
- local, and read-only or safe to repeat;
- not already done: no existing outputs, commits, posted comments or journal result rows;
- `<store> heal-check --origin <handoff session_id> --item <runtime id>` prints `ok <recipe>`. It refuses after 1 restart per resume or 2 per chain, or if the recipe script's sha256 differs from MANIFEST.

First run the same `heal-check` with `--bump`, so a restart that crashes still counts. Then restart from the literal recipe (after a yes, an asked spawn names model and effort). Write to a new epoch path, and run it with `run_in_background`, never `nohup`, `disown` or `setsid`. A second failure becomes a question.

**Lost shell job.** `<store> heal-check --origin <sid> --item <task id>` re-verifies and prints `signal:` lines, `verdict: <status> · confidence <high|low> · effects <class>`, then either `ok <recipe|job:<id>>` and `run: <line>`, or `REFUSED: <reason>` with `ask-command:` and `ask-source: recorded|handoff`.
- `ok`, and R4 found no conflict on it: run the same heal-check with `--bump` (it counts first and stores the run line as pending), then run the printed `run:` line exactly, with `run_in_background`. Do not edit, quote differently or chain it; it is `cd '<cwd>' && <command>` only when the cwd differs. Report: `B-n <old id>: LOST (owner ended <stamp>, quiet since <stamp>, no exit marker) → relaunched as <new id>, <effects>, n of 1 this resume`.
- `REFUSED` with no `ask-command:` (`running-elsewhere`, `running`, `leftover`, `done-unreported`, `stopped`): act per the table, no question.
- `REFUSED` with `ask-command:`: one question: what was lost and when, the exact `ask-command:` and its source (recorded by the plugin at <stamp> | written in the handoff, not recorded), why it is not automatic (the failed signal or gate), and the options: run it in the background (recommended when the effects are `none` or `local`) · run it yourself with `! <run line>` · skip. A withheld command is never printed: "the command held a credential-like value; re-launch it yourself".
- Never stop, kill or TaskStop anything to make room for a relaunch.

**Workflow gate.** Never `SendMessage` into a workflow's agents. Offer `TaskStop` plus `Workflow({scriptPath, resumeFromRunId})`, always as a question, only when all hold:
- it is the same session;
- the class is not `never`;
- the journal and every transcript under its transcript dir are unchanged for ≥ max(15 min, 3 × the last progress gap);
- no `agent()` call is in progress.

Finished `agent()` calls are reused; in-progress ones re-run. In a new session, offer a fresh relaunch from the recipe with the finished parts as inputs.

**Lease rule** (Monitor, cron). Check the watched condition and the last fire's outcome. Met or no longer needed → don't re-arm. Unmet and needed → if the command is read-only, run it once now, then re-arm; otherwise record `classifier: untested` and ask.

**Leftovers:** report; never stop one yourself. Offer stopping as a question with the user-run `! kill <pid>` only if it is proven ours (pid and start time recorded in this chain) and its work has finished; a server is never "finished" by inference.

Report each heal action (item, state found, action, evidence). Re-probe it once when you write the R8 report; a new transcript or output write is progress. No change yet → report `woken <stamp>, not yet confirmed` and re-probe at your next turn; a question only if still unchanged then.
