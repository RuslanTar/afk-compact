// The mod: event wiring only (BUILD-PLAN §2.6). Every handler is a lib function taking Deps.
// A hook that throws is answered by its `.catch`: `next(e)` runs the chain on (or replays what
// the hook's own `next` settled to), so a failure here never blocks the session.
import type { Register } from 'claude-code'
import { onSessionStart, onTurnStart, prepare } from './lib/alive'
import { onTurnComplete } from './lib/boundary'
import { onCompact, trackNative } from './lib/compact'
import { isOwnOrigin, newState, promptEntering, promptNotEntered, realDeps, refuseOwnSubmit } from './lib/deps'
import { countCall, limitText, onInterjection } from './lib/handoff-turn'
import { jobStart, recordJob } from './lib/jobs'
import { randomHex } from './lib/nonce'
import { ASK_TOOL, nudgeText, recordPaths, trackPaths } from './lib/nudge'
import { blockName, contextBlock } from './lib/resume'

export const register: Register = (on, options) => {
  const state = newState(randomHex(8))

  on('session.start', async ($, e, next) => {
    const r = await next(e)
    await onSessionStart(realDeps($, options, state))
    return r
  }).catch(($, e, next) => next(e))

  on('turn.start', async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)
    await onTurnStart(realDeps($, options, state), e.turnId, e.text)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined) return r
    const d = realDeps($, options, state)
    await onTurnComplete(d, await prepare(d), { reason: e.reason, answer: e.answer })
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
    const entering = e.turnId === undefined && !own
    if (entering) promptEntering(state)
    let r
    try {
      r = await next(e)
    } catch (err) {
      if (entering) promptNotEntered(state)
      throw err
    }
    if (entering && r.drop !== undefined) promptNotEntered(state)
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

  on('prompt.context', async ($, e, next) => {
    const r = await next(e)
    const d = realDeps($, options, state)
    const block = await contextBlock(d, await prepare(d))
    if (block === undefined) return r
    const name = blockName($.plugin.name)
    return { ...r, blocks: [...r.blocks.filter(b => b.name !== name), { name, text: block }] }
  }).catch(($, e, next) => next(e))
}
