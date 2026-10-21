// The mod: event wiring only (BUILD-PLAN §2.6). Every handler is a lib function taking Deps.
// A hook that throws is answered by its `.catch`: `next(e)` runs the chain on (or replays what
// the hook's own `next` settled to), so a failure here never blocks the session.
import type { Register } from 'claude-code'
import { onSessionStart, onTurnStart, prepare } from './lib/alive'
import { onTurnComplete } from './lib/boundary'
import { onCompact } from './lib/compact'
import { newState, realDeps } from './lib/deps'
import { randomHex } from './lib/nonce'
import { ASK_TOOL, nudgeText, recordPaths } from './lib/nudge'
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
    await onTurnStart(realDeps($, options, state), e.turnId)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (e.agentId !== undefined) return r
    const d = realDeps($, options, state)
    await onTurnComplete(d, await prepare(d), { reason: e.reason, answer: e.answer })
    return r
  }).catch(($, e, next) => next(e))

  on('tool.call', async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)
    const d = realDeps($, options, state)
    const sid = await prepare(d)
    const isAsk = String(e.tool) === ASK_TOOL
    if (isAsk) {
      state.askOpen++
      state.askedThisTurn = true
    }
    let r
    try {
      await recordPaths(d, sid, String(e.tool), e as unknown as Record<string, unknown>)
      r = await next(e)
    } finally {
      if (isAsk) state.askOpen--
    }
    if (r.deny !== undefined) return r
    const text = await nudgeText(d, sid)
    if (text === undefined) return r
    return { ...r, context: [...(r.context ?? []), text] }
  }).catch(($, e, next) => next(e))

  on('session.compact', async ($, e, next) => {
    const d = realDeps($, options, state)
    return onCompact(d, await prepare(d), e, x => next(x))
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
