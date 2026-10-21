# Self-heal background work (resume R5, steps 5b–5d)

Read from R5 of the resume skill once its 5a inventory has a row. `<store>` is the plugin's helper (`compactinue-store`), and R5's Authority line applies: for `unselected`, or a resource with an ownership conflict, inventory and report only.

**5b Probe** each row once, with its `probe` if read-only, else the default for its kind:
- `agent`, `teammate` → `ListAgents` state;
- `shell` → output mtime and end marker;
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

**Restart gate.** All must hold, else the item becomes a question:
- same session, and the class is `auto` (a missing class means `ask`);
- not a workflow, model-agent spawn, new `claude` process, terminal, kill or detach;
- local, and read-only or safe to repeat;
- not already done: no existing outputs, commits, posted comments or journal result rows;
- `<store> heal-check --origin <handoff session_id> --item <runtime id>` prints `ok <recipe>`. It refuses after 1 restart per resume or 2 per chain, or if the recipe script's sha256 differs from MANIFEST.

First run the same `heal-check` with `--bump`, so a restart that crashes still counts. Then restart from the literal recipe (after a yes, an asked spawn names model and effort). Write to a new epoch path, and run it with `run_in_background`, never `nohup`, `disown` or `setsid`. A second failure becomes a question.

**Workflow gate.** Never `SendMessage` into a workflow's agents. Offer `TaskStop` plus `Workflow({scriptPath, resumeFromRunId})`, always as a question, only when all hold:
- it is the same session;
- the class is not `never`;
- the journal and every transcript under its transcript dir are unchanged for ≥ max(15 min, 3 × the last progress gap);
- no `agent()` call is in progress.

Finished `agent()` calls are reused; in-progress ones re-run. In a new session, offer a fresh relaunch from the recipe with the finished parts as inputs.

**Lease rule** (Monitor, cron). Check the watched condition and the last fire's outcome. Met or no longer needed → don't re-arm. Unmet and needed → if the command is read-only, run it once now, then re-arm; otherwise record `classifier: untested` and ask.

**Leftovers:** report; never stop one yourself. Offer stopping as a question with the user-run `! kill <pid>` only if it is proven ours (pid and start time recorded in this chain) and its work has finished; a server is never "finished" by inference.

Report each heal action (item, state found, action, evidence). Re-probe it once when you write the R8 report; a new transcript or output write is progress. No change yet → report `woken HH:MM, not yet confirmed` and re-probe at your next turn; a question only if still unchanged then.
