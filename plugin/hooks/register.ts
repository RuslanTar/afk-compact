// The mod: event wiring only (BUILD-PLAN §2.6). Every handler is a lib function taking Deps.
// A hook that throws is answered by its `.catch`: `next(e)` runs the chain on (or replays what
// the hook's own `next` settled to), so a failure here never blocks the session.
import type { Register } from 'claude-code'
import { onSessionEnd, onSessionStart, onTurnStart, prepare } from './lib/alive'
import { onOwnCompact, onTurnComplete } from './lib/boundary'
import { onCompact, trackNative } from './lib/compact'
import { claimOwnCompact, isHuman, isOwnOrigin, newState, promptEntering, promptNotEntered, promptQueued, realDeps, refuseOwnSubmit } from './lib/deps'
import { laneTurnEnd } from './lib/digest'
import { countCall, limitText, onInterjection, onStep } from './lib/handoff-turn'
import { jobStart, recordJob } from './lib/jobs'
import { randomHex } from './lib/nonce'
import { noteDialog, personAnswered, personTyped, timeoutNote } from './lib/question'
import { ASK_TOOL, nudgeText, recordPaths, trackPaths } from './lib/nudge'
import { cancelIdle, cancelIdleTimer, resumeIdle } from './lib/idle'
import { cancelKeepWarmTimer, noteBackground, noteEndedTasks, resumeKeepWarm } from './lib/keepwarm'
import { startsWork } from './lib/lane'
import { againFor, againLost, againSent, blockName, contextBlock, contextPassedOn, laneAgentStarted, laneNoteLost, laneRecheck, laneWorkStarted, passedBlockFor, passedLost, pendingNotified } from './lib/resume'
import { shadowOwnerHandoff, shadowSelfHandoff, shadowStep, shadowTurnEnd } from './lib/shadow'
import { noteMode, onAttach, onCommandRun, onWorktreeTool, restartInterrupt } from './lib/restart'

export const register: Register = (on, options) => {
  const state = newState(randomHex(8))

  on('session.start', async ($, e, next) => {
    const r = await next(e)
    // SESSION-RESTART D10: a permission mode read before the load's start (an earlier process's
    // Stop) is older than any turn of this load.
    try {
      state.sessionStartAt = await $.clock.now()
    } catch {
      // no stamp: the restart moment uses its own time (every read counts as older)
    }
    // D11, §3.4: a person launched or resumed this session: present for the next minute, so an
    // idle compaction the load adopts does not run in front of them (stamped before loadIdle).
    if (e.isInteractive === true) {
      try {
        state.lastInputAt = await $.clock.now()
      } catch {
        // no stamp: presence is not known
      }
    }
    await onSessionStart(realDeps($, options, state), e.isInteractive)
    return r
  }).catch(($, e, next) => next(e))

  // IC-1 D7: a `/clear` (or any end) cancels every timer that would submit into the next
  // conversation, takes the pending block out of the load (dropped on a `/clear`, else kept on
  // disk for a resume of the same session id) and closes an open handoff turn.
  on('session.end', async ($, e, next) => {
    cancelIdleTimer(realDeps($, options, state))
    cancelKeepWarmTimer(realDeps($, options, state))
    await onSessionEnd(realDeps($, options, state), e.sessionId, e.reason)
    return next(e)
  }).catch(($, e, next) => next(e))

  // Owner xxxxxxxx-38: an agent loop's turn (a subagent, a teammate, a workflow's agent) counts as
  // a running agent for the idle check from its start to its end.
  on('turn.start', async ($, e, next) => {
    if (e.agentId !== undefined) {
      state.agentTurns.add(e.agentId)
      laneAgentStarted(state, e.agentId)
      return next(e)
    }
    // 0.1.5 D-1: a block another loop's prompt.context call passed over, which no prompt carried,
    // has the context read again.
    contextPassedOn(realDeps($, options, state))
    // SESSION-RESTART D10: a permission mode read before this turn's start is older than the last turn.
    try {
      state.lastMainTurnAt = await $.clock.now()
    } catch {
      // no stamp: the last one stands (or the load's start)
    }
    await onTurnStart(realDeps($, options, state), e.turnId, e.text)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    if (e.agentId !== undefined) state.agentTurns.delete(e.agentId)
    const r = await next(e)
    if (e.agentId !== undefined) return r
    const d = realDeps($, options, state)
    const sid = await prepare(d)
    await onTurnComplete(d, sid, { reason: e.reason, answer: e.answer })
    // Owner 2026-10-28 digest rules (b): the end of a turn whose job result unblocked a step reads
    // the work lane again; a lane now finished or hard-blocked still gets its digest, once, with
    // idle_digest: submit or return; with off, the one-line note.
    await laneTurnEnd(d, sid, e.reason, e.answer)
    // The shadow trial: started, not awaited, after the plugin's own turn end (one `fs.exists`
    // without its local config).
    shadowTurnEnd(d, sid, e.answer)
    return r
  }).catch(($, e, next) => next(e))

  // MG-3 (ratify R4 guard): the handoff turn's first request reports its cache-read share. The
  // step passes through unchanged (model, effort and all); only its result is read, after it.
  // Nothing after the stream may throw: a failure there would hand the step to `.catch`.
  // The shadow trial stamps a main step's start for its cold rule (nothing without its config).
  // The start of every main-thread request anchors the idle compaction (D3): the prompt cache is
  // refreshed when a request reads it, not at the turn end. Its count lets keep-warm ping again
  // after a fork-miss (keepwarm.ts).
  on('turn.step', async function* ($, e, next) {
    if (e.agentId === undefined) {
      state.mainReqs++
      try {
        state.lastMainReqAt = await $.clock.now()
      } catch {
        // the anchor stays the last one (or the turn end)
      }
      try {
        shadowStep(state, () => realDeps($, options, state))
      } catch {
        // the trial never changes a step
      }
    }
    const r = yield* next(e)
    try {
      if (e.agentId === undefined) onStep(realDeps($, options, state), e.turnId, e.index, r.usage)
    } catch {
      // no share for this turn (handoff_turn_end logs null)
    }
    // D-80: a main response refreshed the usage windows (limits.ts reads how fresh they are).
    if (e.agentId === undefined) void $.clock.now().then(t => { state.usageAt = t }, () => undefined)
    return r
  }).catch(async function* ($, e, next) {
    return yield* next(e)
  })

  // D-80: the engine measured the session (after a main turn, or a usage window moved a whole
  // point, a keep-warm ping's response too): the usage windows are fresh now. Observe only.
  on('session.measure', async ($, e, next) => {
    const r = await next(e)
    void $.clock.now().then(t => { state.usageAt = t }, () => undefined)
    return r
  }).catch(($, e, next) => next(e))

  // D11 (G7): a person editing the prompt box is present. Observe only, in the keystroke path:
  // nothing before `next` and nothing awaited after it.
  on('prompt.edit', async ($, e, next) => {
    const r = await next(e)
    void $.clock.now().then(t => { state.lastInputAt = t }, () => undefined)
    return r
  }).catch(($, e, next) => next(e))

  // D11: a recall, an undo, a clear or another write of the box is a person's too; a plugin's
  // fill and a remote app's own write are not.
  on('prompt.change', async ($, e, next) => {
    const r = await next(e)
    if (e.origin.kind !== 'plugin' && e.origin.kind !== 'app') void $.clock.now().then(t => { state.lastInputAt = t }, () => undefined)
    return r
  }).catch(($, e, next) => next(e))

  // A user's prompt delivered into the running handoff turn lifts its limits text (MOD-SPEC §9.1).
  // One the user asked to wait its turn (`wait`, ctrl+x enter) is not delivered into it.
  // A prompt entering an idle session (no `turnId`) is counted before `next`, which resolves only
  // once its turn started: that turn.start then knows a prompt other than ours entered (CR-F17).
  // Our own submits reach this hook too (the engine skips only the calling hook): they are told
  // by origin, are never counted, and a handoff-turn one is dropped if a user prompt came first.
  on('prompt.submit', async ($, e, next) => {
    const own = isOwnOrigin(e.origin, $.plugin.name)
    if (own && refuseOwnSubmit(state)) return { drop: 'a user prompt came first' }
    // 0.1.5 D-1: our own prompt does not carry a block another loop's prompt.context call passed
    // over (any other prompt does, below): the turn it opens or joins reads the context again.
    if (own) contextPassedOn(realDeps($, options, state))
    const entering = e.turnId === undefined && !own
    // IC-1 D6: the entering prompt's origin kind decides at its turn.start whether halt clears.
    const kind = e.origin.kind
    // Keep-warm (D-14): a task a notification reports ended is not an open job any more.
    if (!own) noteEndedTasks(state, kind, e.text)
    // 0.1.6: and a waiting resume block shows that task's in-flight row ended.
    if (!own) pendingNotified(state, kind, e.text)
    if (entering) {
      promptEntering(state, kind, e.text)
      // §9.4: a prompt entering cancels the pre-idle timer, and keep-warm's ping timer (D-14).
      cancelIdleTimer(realDeps($, options, state))
      cancelKeepWarmTimer(realDeps($, options, state))
      // SESSION-RESTART §2.2 step 4, §3.4 step 3: a prompt entering stops a restart under way.
      // Guarded: the run is ended before its first await, and a failure in its notes or rows
      // must not skip `next` below, nor the resumes there for a prompt that then does not enter.
      if (state.restart !== undefined) await restartInterrupt(realDeps($, options, state)).catch(() => undefined)
    }
    // The shadow trial's M1 moment for this plugin's typed handoff command, before its turn
    // starts; off (one cheap test) without the local trial config. Never throws (as againFor).
    if (!own && e.command?.name === $.plugin.name + ':handoff') {
      await shadowOwnerHandoff(realDeps($, options, state), e.command.args, e.text)
    }
    // Away digest phase 1: a later prompt of an open idle episode, not a person's, carries the lane
    // note beside it when the lane turned finished or hard-blocked (prompt.context is asked once per
    // conversation, so it cannot carry one); a person's prompt closes the episode. A note whose
    // prompt does not enter goes back to the episode for the next turn. A recheck that fails (the
    // session id, a row) adds no note, and the prompt goes on as the restart's does above.
    const note = own ? undefined : await laneRecheck(realDeps($, options, state), kind, e.text).catch(() => undefined)
    // Owner xxxxxxxx-37: a person back after a background result's turn took an idle block gets
    // the whole block again beside their prompt, for the same reason; one that does not enter
    // hands it back for their next prompt.
    const again = own ? undefined : await againFor(realDeps($, options, state), kind, entering)
    // 0.1.5 D-1: a block another loop's prompt.context call passed over goes beside this prompt,
    // after the recheck counted its results (prompt.context may not be asked again for its turn).
    const passed = own ? undefined : await passedBlockFor(realDeps($, options, state), kind, entering).catch(() => undefined)
    const extra = [note?.text, passed?.text, again?.text].filter((t): t is string => t !== undefined)
    if (extra.length > 0) e = { ...e, context: [...(e.context ?? []), ...extra] }
    let r
    try {
      r = await next(e)
    } catch (err) {
      if (note !== undefined) laneNoteLost(state, note)
      if (again !== undefined) againLost(state, again)
      if (passed !== undefined) passedLost(state, passed)
      if (entering) {
        promptNotEntered(state, kind)
        await resumeIdle(realDeps($, options, state)).catch(() => undefined)
        await resumeKeepWarm(realDeps($, options, state)).catch(() => undefined)
      }
      throw err
    }
    if (note !== undefined && r.drop !== undefined) laneNoteLost(state, note)
    if (passed !== undefined) {
      if (r.drop !== undefined) passedLost(state, passed)
      else await passed.sent()
    }
    if (again !== undefined) {
      if (r.drop !== undefined) againLost(state, again)
      else await againSent(realDeps($, options, state), again)
    }
    if (entering && r.drop !== undefined) {
      promptNotEntered(state, kind)
      // No turn starts, so the idle timer (§9.4) and keep-warm's ping timer (D-14) cancelled above
      // run again: the idle record stays in the store, and keep-warm hands over to it. Each is
      // guarded as on the throw path: resumeIdle's store read that fails still lets keep-warm's run.
      await resumeIdle(realDeps($, options, state)).catch(() => undefined)
      await resumeKeepWarm(realDeps($, options, state)).catch(() => undefined)
    }
    // A prompt queued while a turn runs may start its own turn after it: its origin kind decides
    // there whether halt clears, as for one entering an idle session.
    if (!own && e.turnId !== undefined && r.drop === undefined) promptQueued(state, kind, r.text, e.turnId)
    // 0.1.4 R-7: a person's prompt typed into the running turn: they wrote since a dialog timed out.
    if (!own && e.turnId !== undefined && e.wait !== true && r.drop === undefined && isHuman(kind)) personTyped(state)
    if (entering && r.drop === undefined) {
      const d = realDeps($, options, state)
      await cancelIdle(d, await d.sessionId())
    }
    if (e.turnId !== undefined && e.wait !== true && (e.origin.kind === 'composer' || e.origin.kind === 'bridge')) {
      const d = realDeps($, options, state)
      await onInterjection(d, await prepare(d), e.turnId)
    }
    return r
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)
    const d = realDeps($, options, state)
    const sid = await prepare(d)
    const tool = String(e.tool)
    // SESSION-RESTART G10: a worktree entered in this load is a restriction a resume cannot carry.
    onWorktreeTool(d, tool)
    const input = e as unknown as Record<string, unknown>
    const isAsk = tool === ASK_TOOL
    // An open dialog counts through askOpen; once it settles, only one left unanswered marks the
    // turn as asking the user (an answered dialog blocks nothing after it).
    if (isAsk) state.askOpen++
    // Dev-1: the session's directory as the job will see it is read before the call runs.
    const job = await jobStart(d, tool)
    // The temp paths of this call are recorded beside it, never before it: the tool does not
    // wait for the helper (one spawn per new path), and nothing is recorded with auto_evidence off.
    if (d.cfg.auto_evidence) trackPaths(state, recordPaths(d, sid, tool, input))
    countCall(d)
    // The shadow trial's M1 moment for a model-called handoff skill (a name test first; off
    // without the local trial config).
    if (tool === 'Skill') await shadowSelfHandoff(d, sid, tool, input)
    let r
    try {
      r = await next(e)
    } catch (err) {
      if (isAsk) state.askedThisTurn = true
      throw err
    } finally {
      if (isAsk) state.askOpen--
    }
    if (isAsk && !personAnswered(r)) state.askedThisTurn = true
    if (r.deny !== undefined) return r
    // Question carry: a dialog that closed on the AFK timeout leaves its questions open.
    if (isAsk) noteDialog(state, input, r)
    // 0.1.4 R-5: the no-dialog rule beside the timed-out result itself, compaction or not.
    const asked = isAsk ? timeoutNote(d.name, r) : undefined
    // Away digest phase 1: work the model starts after an idle block went out supersedes its lane.
    if (r.isError !== true && startsWork(tool, r.result)) laneWorkStarted(state)
    if (job) await recordJob(d, sid, tool, input, r, job)
    const text = (await limitText(d, sid, r.text)) ?? (await nudgeText(d, sid))
    const notes = [asked, text].filter((t): t is string => t !== undefined)
    if (notes.length === 0) return r
    return { ...r, context: [...(r.context ?? []), ...notes] }
  }).catch(($, e, next) => next(e))

  // A headless session's own `/compact` (boundary.ts) is claimed before any await and shaped
  // with the text the boundary prepared; every other compaction is handled as usual.
  on('session.compact', async ($, e, next) => {
    const d = realDeps($, options, state)
    const own = claimOwnCompact(state, e)
    if (own) return onOwnCompact(d, await prepare(d), e, own, x => next(x))
    return trackNative(d, e, async () => onCompact(d, await prepare(d), e, x => next(x)))
  }).catch(($, e, next) => next(e))

  // SESSION-RESTART §3.4 step 5, G9, G10 (observe only): another origin's `/exit` while armed
  // cancels the restart; the commands a restart cannot carry block it for the rest of the load.
  // Our own `/exit` never reaches this hook (the engine skips the raising plugin's hooks).
  on('command.run', async ($, e, next) => {
    await onCommandRun(realDeps($, options, state), e)
    return next(e)
  }).catch(($, e, next) => next(e))

  // SESSION-RESTART D10: the permission mode of every main Stop, UserPromptSubmit and
  // PermissionRequest input (observe only; nothing awaited before `next`).
  // Keep-warm (D-14): the main Stop's in-flight background tasks (`background_tasks`), read at its ping.
  on('classic.Stop', async ($, e, next) => {
    void $.clock.now().then(t => noteMode({ state }, e, t), () => undefined)
    try {
      noteBackground(state, e)
    } catch {
      // no list: keep-warm counts the agents only
    }
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.UserPromptSubmit', async ($, e, next) => {
    void $.clock.now().then(t => noteMode({ state }, e, t), () => undefined)
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.PermissionRequest', async ($, e, next) => {
    void $.clock.now().then(t => noteMode({ state }, e, t), () => undefined)
    return next(e)
  }).catch(($, e, next) => next(e))

  // SESSION-RESTART G3b: remote clients attached in this load (observe only).
  on('session.attach', async ($, e, next) => {
    const r = await next(e)
    onAttach(realDeps($, options, state), 1)
    return r
  }).catch(($, e, next) => next(e))

  on('session.detach', async ($, e, next) => {
    const r = await next(e)
    onAttach(realDeps($, options, state), -1)
    return r
  }).catch(($, e, next) => next(e))

  // The resume block (the same idle block again for a person back after a background result's turn
  // took it goes beside their prompt, in prompt.submit: this is asked once per conversation).
  on('prompt.context', async ($, e, next) => {
    const r = await next(e)
    const d = realDeps($, options, state)
    const sid = await prepare(d)
    const block = await contextBlock(d, sid)
    if (block === undefined) return r
    const name = blockName($.plugin.name)
    return { ...r, blocks: [...r.blocks.filter(b => b.name !== name), { name, text: block }] }
  }).catch(($, e, next) => next(e))
}
