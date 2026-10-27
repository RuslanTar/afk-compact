// The mod: event wiring only (BUILD-PLAN §2.6). Every handler is a lib function taking Deps.
// A hook that throws is answered by its `.catch`: `next(e)` runs the chain on (or replays what
// the hook's own `next` settled to), so a failure here never blocks the session.
import type { Register } from 'claude-code'
import { onSessionEnd, onSessionStart, onTurnStart, prepare } from './lib/alive'
import { onTurnComplete } from './lib/boundary'
import { onCompact, trackNative } from './lib/compact'
import { isOwnOrigin, newState, promptEntering, promptNotEntered, realDeps, refuseOwnSubmit } from './lib/deps'
import { countCall, limitText, onInterjection, onStep } from './lib/handoff-turn'
import { jobStart, recordJob } from './lib/jobs'
import { randomHex } from './lib/nonce'
import { ASK_TOOL, nudgeText, recordPaths, trackPaths } from './lib/nudge'
import { cancelIdle, cancelIdleTimer } from './lib/idle'
import { blockName, contextBlock } from './lib/resume'
import { shadowOwnerHandoff, shadowSelfHandoff, shadowTurnEnd } from './lib/shadow'

export const register: Register = (on, options) => {
  const state = newState(randomHex(8))

  on('session.start', async ($, e, next) => {
    const r = await next(e)
    await onSessionStart(realDeps($, options, state))
    return r
  }).catch(($, e, next) => next(e))

  // IC-1 D7: a `/clear` (or any end) cancels every timer that would submit into the next
  // conversation, drops the pending block and closes an open handoff turn.
  on('session.end', async ($, e, next) => {
    cancelIdleTimer(realDeps($, options, state))
    await onSessionEnd(realDeps($, options, state), e.sessionId)
    return next(e)
  }).catch(($, e, next) => next(e))

  // Owner xxxxxxxx-38: an agent loop's turn (a subagent, a teammate, a workflow's agent) counts as
  // a running agent for the idle check from its start to its end.
  on('turn.start', async ($, e, next) => {
    if (e.agentId !== undefined) {
      state.agentTurns.add(e.agentId)
      return next(e)
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
    // The shadow trial: started, not awaited, after the plugin's own turn end (one `fs.exists`
    // without its local config).
    shadowTurnEnd(d, sid, e.answer)
    return r
  }).catch(($, e, next) => next(e))

  // MG-3 (ratify R4 guard): the handoff turn's first request reports its cache-read share. The
  // step passes through unchanged (model, effort and all); only its result is read, after it.
  // Nothing after the stream may throw: a failure there would hand the step to `.catch`.
  on('turn.step', async function* ($, e, next) {
    const r = yield* next(e)
    try {
      if (e.agentId === undefined) onStep(realDeps($, options, state), e.turnId, e.index, r.usage)
    } catch {
      // no share for this turn (handoff_turn_end logs null)
    }
    return r
  }).catch(async function* ($, e, next) {
    return yield* next(e)
  })

  // A user's prompt delivered into the running handoff turn lifts its limits text (MOD-SPEC §9.1).
  // One the user asked to wait its turn (`wait`, ctrl+x enter) is not delivered into it.
  // A prompt entering an idle session (no `turnId`) is counted before `next`, which resolves only
  // once its turn started: that turn.start then knows a prompt other than ours entered (CR-F17).
  // Our own submits reach this hook too (the engine skips only the calling hook): they are told
  // by origin, are never counted, and a handoff-turn one is dropped if a user prompt came first.
  on('prompt.submit', async ($, e, next) => {
    const own = isOwnOrigin(e.origin, $.plugin.name)
    if (own && refuseOwnSubmit(state)) return { drop: 'a user prompt came first' }
    const entering = e.turnId === undefined && !own
    // IC-1 D6: the entering prompt's origin kind decides at its turn.start whether halt clears.
    const kind = e.origin.kind
    if (entering) {
      promptEntering(state, kind)
      // §9.4: a prompt entering cancels the pre-idle timer.
      cancelIdleTimer(realDeps($, options, state))
    }
    // The shadow trial's M1 moment for this plugin's typed handoff command, before its turn
    // starts; off (one cheap test) without the local trial config.
    if (!own && e.command?.name === $.plugin.name + ':handoff') {
      await shadowOwnerHandoff(realDeps($, options, state), e.command.args, e.text)
    }
    let r
    try {
      r = await next(e)
    } catch (err) {
      if (entering) promptNotEntered(state, kind)
      throw err
    }
    if (entering && r.drop !== undefined) promptNotEntered(state, kind)
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
    const input = e as unknown as Record<string, unknown>
    const isAsk = tool === ASK_TOOL
    if (isAsk) {
      state.askOpen++
      state.askedThisTurn = true
    }
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
    } finally {
      if (isAsk) state.askOpen--
    }
    if (r.deny !== undefined) return r
    if (job) await recordJob(d, sid, tool, input, r, job)
    const text = (await limitText(d, sid, r.text)) ?? (await nudgeText(d, sid))
    if (text === undefined) return r
    return { ...r, context: [...(r.context ?? []), text] }
  }).catch(($, e, next) => next(e))

  on('session.compact', async ($, e, next) => {
    const d = realDeps($, options, state)
    return trackNative(d, e, async () => onCompact(d, await prepare(d), e, x => next(x)))
  }).catch(($, e, next) => next(e))

  // The resume block, and the same idle block again when a person comes back after a background
  // result's turn took it (owner xxxxxxxx-37).
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
