# Handoffs and resume

A **handoff** is a file that a fresh session can resume from. The plugin asks for the same form in two places: the compaction summary it shapes, and the file `/afk-compact:handoff` writes. After a compaction it gives the next turn one short **resume block**. This page covers what a handoff holds, what the first reply after a compaction looks like, and the two extra turns in which the plugin asks for a handoff.

## What a handoff contains

Each handoff is a set of short sections, in this order. A section with nothing in it is left out.

- **Resume here:** status, how stable the state is, the next step (**Step 1**: one exact command or edit), the **Gate** (what blocks it, or none), the likeliest mistake to avoid, and what is running now.
- **User constraints:** your own words and asks, each with its state (open, partly done, done, superseded). Lines carry the id `U-` and a number.
- **Approvals:** what you approved, for which targets, once or standing. Deploys, production writes and pushes to a protected branch are asked again.
- **Decisions and do-not-re-raise:** the choices made and why (`D-`), and the options rejected, refuted or failed (`X-`).
- **In flight:** background work still running (`B-`), with a command to check it and whether it may restart by itself, asks first or never restarts.
- **Live state:** claims about the outside world, each with when it was last seen and a command to re-check it.
- **Open questions:** questions only you can answer (`Q-`), with options and a recommendation.
- **Location, if changed:** the worktree, branch and working folder.
- **Work done and findings:** what was done, how far it went and the proof for it, plus findings and follow-ups.
- **Evidence:** the temporary files the work cites.
- **Next steps:** a numbered list that starts with Step 1.

Every item has one id, ids are never written as a range or renumbered, and a secret is never written, even quoted: the handoff says where it lives. The full format, with every rule, is in [the handoff spec](../plugin/assets/handoff-spec.md); for how the ids carry from one handoff to the next, see [The ledger stays (from 0.1.5)](usage.md#the-ledger-stays-from-015).

## The first reply after a compaction

- The first reply after a compaction opens with one status line, before any tool call: `Resumed · step 1: <the summary's Step 1>`, or `Resumed after compaction` when no Step 1 can be read; after a handoff whose report was cut off, its `✓ Handoff saved: <path>` line takes that place (when the cut-off handoff can still be finished, after the one call that finishes it).
- When a script reads the reply (`claude -p`, the Agent SDK) the line is left out, so the output a script reads does not start with it; a terminal session, the desktop app, the IDE extensions and Claude Code's other apps where you read the reply (mobile, Slack, Cowork, an SSH remote) keep it.
- The plugin tells them apart by the `CLAUDE_CODE_ENTRYPOINT` value Claude Code sets and by whether the session draws on any surface; where its classic hooks deliver the block, by `CLAUDE_CODE_ENTRYPOINT` alone, or, when that is not set, by whether the mod has recorded this session as headless.
- A question whose dialog timed out is not asked again in a dialog until you write: it is listed at the end of the turn instead (after a compaction, the same holds for one whose dialog closed with no answer).



## Delivery after a restart

If the session exits or restarts before its next turn, the block waits on disk and goes to the first turn after `claude --resume` of the same session, built again by the running version and measured again when it is more than 10 minutes old. Only that first turn gets it, and only once the earlier process has ended; a newer compaction replaces it, `/clear` drops it, and a forked session never gets it.

## The handoff turn of a last cycle

A **last cycle** is a nudged cycle that will not be followed by an automatic continue. That is the case when halt mode is on, when the hourly cap would refuse this cycle's continue, or when `max_auto_continues_per_hour` is `0`.

The nudge of a last cycle tells the model that the plugin will not resume the work by itself. It does not ask for a handoff in the middle of the task. With `handoff_turn` set to `true` (the default), the plugin acts when the nudged turn has ended normally:

1. It checks that the turn did not end on a question to you, that no native compaction ran meanwhile, and that the handoff turn would get at least 20,000 tokens. The plugin keeps a 15,000-token margin below the native trigger, so this needs at least 35,000 tokens of room there. If not, it skips the handoff turn. After a cap or auto-continue-off halt it then compacts as usual; after a halt for failed verdicts or a loop it runs no compaction.
2. After `boundary_delay_ms` it submits one turn of its own to the same session. That turn has the full context, runs on your model and effort, and starts from a warm prompt cache. The plugin names no model, effort or agent in any turn or compaction it starts; the watcher warns in `/afk-compact:status` when a compaction or a handoff turn read its context cold from the cache, which is the sign that it ran on another model. It asks the model to run `/afk-compact:handoff` and to put one plain line above the report that says auto-continue paused and why; unless the task is done, the first thing the report says it needs from you is any message, to resume the work. You see this turn in the chat like any other.
3. If the handoff is published after a cap or auto-continue-off halt, the plugin runs one compaction and submits no continue. A toast says `afk-compact: auto-continue paused (<reason>); handoff saved: <path>`. After a halt for failed verdicts or a loop, it runs no compaction: native auto-compaction stays the backstop, and the toast says why.

**The limits are advice.** The plugin counts tool calls and tokens in the handoff turn. It adds a note to a tool result when the budget is nearly spent, when it is spent, and when native compaction is close. Each note tells the model what to do next, for example to publish the draft now or to end the turn with the report. The plugin denies no call and stops nothing.

Edge cases:

- A message you type during the delay cancels the handoff turn. If the plugin's prompt was already queued behind your message, the plugin ends that leftover turn as it starts, before anything runs in it. A message you type during the turn lifts the plugin's limits, and you lead from there.
- If native compaction fires during the turn, the summary is complete anyway. The resume block says a draft exists and gives the exact command that publishes it.
- A handoff the session wrote in the last 15 minutes is reused only when nothing has changed since: the same commit, the same working-tree state, and no new decision or background change. Then nothing new is published, and the compaction uses the full summary text. Otherwise the turn writes and publishes a new handoff.
- There are at most two handoff turns per session in a rolling hour. The turn before a planned compaction (below) and the optional idle handoff turn (see [Idle compaction](idle-compaction.md#idle-compaction)) only run when no handoff turn ran in the last hour, so the second one stays free for a last cycle.
- There is no last-cycle handoff turn on the turn-end compaction at `compact_target_tokens` (that compaction has its own turn, below), for subagents, or in a cycle that will auto-continue.
- Windows too small for plugin compactions get no nudge, so no handoff turn.

Set `handoff_turn` to `false` to turn this off. `handoff_turn_max_tokens` sets how much the turn may use.

## The handoff turn before a planned compaction

Before each planned compaction the model gets one extra turn to write a handoff (up to `handoff_turn_max_tokens`, 64K by default, and 34 tool calls). Set `precompact_turn` to `false` to save usage: code then records the checkpoint alone. The planned evaluation run measures this turn; if its cost is not worth it, the default becomes `false` and this page says why.

A planned compaction is the one at a clean turn end once the context passes `compact_target_tokens`, in a turn that had no nudge (a nudged turn follows the rules of the last cycle above). With `precompact_turn` set to `true`, the plugin submits one turn of its own before it compacts. It uses the same machinery and limits as the last-cycle handoff turn, and asks for a handoff while the context is still there; the turn ends with the skill's report and does not continue the task.

- If the handoff is published, the plugin runs one compaction that points to the handoff, and submits no continue: your next message leads.
- If nothing is published, the plugin runs the usual compaction with the full summary.
- The turn is skipped, and the usual compaction runs as with `code`, when the turn ended on a question to you, when the turn would get less than 20,000 tokens, when any handoff turn ran in the last hour, or when this turn already ran since the session's last compaction. A message you type during the delay cancels both the turn and the compaction.
