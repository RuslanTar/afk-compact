// The turn-end scheduler and the self-call path (MOD-SPEC §4, §9). The engine skips our own
// `session.compact` hook for our `$.session.compact`, so everything happens at the call site.
import type { Deps } from './deps'
import type { ResumePref } from './compact'
import { afterStep, dispatchExists, guarded, mainText, writeDispatch } from './compact'
import { effective } from './config'
import { autoContinue, thrashCheck } from './cont'
import { checkpoint, prevCopy } from './helper'
import { log, skipClass } from './log'
import { drawNonce } from './nonce'
import { undeliveredCheck } from './resume'

/** MOD-SPEC §9: the nudged turn ended on a user-owned question (`?` on the last non-blank line). */
export function endsWithQuestion(answer: string): boolean {
  const lines = answer.split('\n').map(l => l.trim()).filter(l => l !== '')
  const last = lines[lines.length - 1]
  return last !== undefined && last.endsWith('?')
}

export type TurnEnd = { reason: string; answer: string }

/** Main `turn.complete`: bookkeeping, then the boundary guards and timer (MOD-SPEC §9). */
export async function onTurnComplete(d: Deps, sid: string, t: TurnEnd): Promise<void> {
  const s = d.state
  s.mainTurnRunning = false
  s.lastTurnAsksUser = s.askedThisTurn || endsWithQuestion(t.answer)
  if (t.reason !== 'answer') s.resumeAfter = false
  await undeliveredCheck(d, sid)
  const eff = await effective(d, sid)
  if (eff.disabled) return
  if (t.reason !== 'answer') return
  let tokens: number | undefined
  try {
    tokens = (await d.usage()).tokens
  } catch {
    tokens = undefined
  }
  if (tokens === undefined) return
  await thrashCheck(d, sid, tokens >= eff.target)
  if (tokens < eff.target) return
  if (s.askOpen > 0) {
    await log(d, sid, 'skip', { why: 'asks' })
    return
  }
  if (s.halt.active) {
    await log(d, sid, 'skip', { why: 'halt' })
    return
  }
  const now = await d.now()
  if (s.lastPluginCompactAt !== undefined && now - s.lastPluginCompactAt < d.cfg.cooldown_ms) {
    await log(d, sid, 'skip', { why: 'cooldown' })
    return
  }
  if (s.busy) return
  const delay = s.nudgedThisTurn || tokens >= eff.soft_max ? 500 : d.cfg.boundary_delay_ms
  s.timer?.cancel()
  s.timer = d.after(delay, () => {
    s.timer = undefined
    s.inflight = boundary(d).catch(() => undefined)
  })
}

/** A main `turn.start` cancels a pending boundary timer. */
export function cancelBoundary(d: Deps): void {
  d.state.timer?.cancel()
  d.state.timer = undefined
}

async function resumePref(d: Deps, sid: string): Promise<ResumePref> {
  if (d.state.ctxSeen) return 'prompt.context'
  const p = await d.paths()
  if (p && (await d.exists(`${p.watch}/${sid}/classic-alive.json`))) return 'sessionstart'
  return 'prompt.submit'
}

/** MOD-SPEC §4: one plugin compaction at a clean turn end, then the after-step and continue. */
export async function boundary(d: Deps): Promise<void> {
  const s = d.state
  if (s.busy || s.mainTurnRunning || s.askOpen > 0 || s.halt.active) return
  const sid = await d.sessionId()
  const eff = await effective(d, sid)
  if (eff.disabled) return
  const now = await d.now()
  if (s.lastPluginCompactAt !== undefined && now - s.lastPluginCompactAt < d.cfg.cooldown_ms) return
  const tokens = (await d.usage()).tokens
  if (tokens === undefined || tokens < eff.target) return
  s.busy = true
  try {
    const nonce = await drawNonce(n => dispatchExists(d, sid, n))
    const prev = await prevCopy(d, sid)
    const cp = await checkpoint(d, sid, nonce, d.cfg.measured_block)
    const measured = d.cfg.measured_block && cp ? cp.measured_block : null
    const { text, tags } = await mainText(d, nonce, false, prev, measured)
    const pref = await resumePref(d, sid)
    s.selfNonces.add(nonce)
    await writeDispatch(d, { sid, nonce, agentId: null, trigger: 'plugin', channel: 'mod-self', resumePref: pref, midturn: false, tags, text })
    const t0 = await d.now()
    let r
    try {
      r = await d.compact(text)
    } catch {
      await log(d, sid, 'compact_rejected', { nonce, attempt: 1 })
      return
    }
    if (r.skip !== undefined) {
      await log(d, sid, 'compacted', { nonce, skip: skipClass(r.skip), tokens_before: null, tokens_after: null, usage_present: false, ms: (await d.now()) - t0 })
      return
    }
    await log(d, sid, 'compacted', {
      nonce, skip: null, tokens_before: r.tokensBefore ?? null, tokens_after: r.tokensAfter ?? null,
      usage_present: r.usage !== undefined, ms: (await d.now()) - t0,
    })
    s.lastPluginCompactAt = await d.now()
    s.pluginCompactions.push({ turnSeq: s.turnSeq, refilled: null })
    await guarded(d, sid, 'after-step', () => afterStep(d, {
      sid, nonce, agentId: null, midturn: false, resumePref: pref, messages: r.messages, tokensBefore: r.tokensBefore, tokensAfter: r.tokensAfter,
    }))
    await guarded(d, sid, 'continue', () => autoContinue(d, sid))
  } finally {
    s.busy = false
  }
}
