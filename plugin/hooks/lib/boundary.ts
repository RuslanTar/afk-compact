// The turn-end scheduler and the self-call path (MOD-SPEC §4, §9), and the scheduling of the
// handoff turn and the compaction after it (§9.1). The engine skips our own `session.compact`
// hook for our `$.session.compact`, so everything happens at the call site.
import type { Deps } from './deps'
import type { ResumePref } from './compact'
import { afterStep, dispatchExists, guarded, mainText, writeDispatch } from './compact'
import { effective } from './config'
import { autoContinue, lastCycleEnd, thrashCheck } from './cont'
import type { HandoffTurn } from './handoff-turn'
import { compactsAfter, endHandoffTurn, openAndSubmit, planHandoff } from './handoff-turn'
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

/** What one plugin compaction is exempt from, and the handoff turn it follows (MOD-SPEC §9.1). */
export type BoundaryOpts = {
  /** A last cycle's compaction for `cap` or `continue-off` runs although halt is on (DP-4). */
  exemptHalt?: boolean
  /** The compaction after a handoff turn: also exempt from cooldown and the target check. */
  afterHandoff?: { ht: string; path: string | undefined; stats: Record<string, string | number | null> }
}

/** Main `turn.complete`: bookkeeping, then the boundary guards and timer (MOD-SPEC §9, §9.1). */
export async function onTurnComplete(d: Deps, sid: string, t: TurnEnd): Promise<void> {
  const s = d.state
  s.mainTurnRunning = false
  s.lastTurnAsksUser = s.askedThisTurn || endsWithQuestion(t.answer)
  if (t.reason !== 'answer') s.resumeAfter = false
  await undeliveredCheck(d, sid)
  const end = await endHandoffTurn(d, sid, t.reason)
  if (end.kind === 'done') return
  if (end.kind === 'compact') {
    schedule(d, 500, { exemptHalt: true, afterHandoff: { ht: end.ht, path: end.path, stats: end.stats } })
    return
  }
  const last = s.lastCycle
  s.lastCycle = null
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
  let exemptHalt = false
  if (last !== null) {
    // A last cycle: no continue; its handoff turn comes before the compaction (§9.1).
    await lastCycleEnd(d, sid, last)
    const h = await planHandoff(d, sid, last, eff, tokens)
    if (h) {
      startHandoffTimer(d, sid, h)
      return
    }
    exemptHalt = compactsAfter(last)
  }
  if (tokens < eff.target) return
  if (s.askOpen > 0) {
    await log(d, sid, 'skip', { why: 'asks' })
    return
  }
  if (s.halt.active && !exemptHalt) {
    await log(d, sid, 'skip', { why: 'halt' })
    return
  }
  const now = await d.now()
  if (s.lastPluginCompactAt !== undefined && now - s.lastPluginCompactAt < d.cfg.cooldown_ms) {
    await log(d, sid, 'skip', { why: 'cooldown' })
    return
  }
  if (s.busy) return
  schedule(d, s.nudgedThisTurn || tokens >= eff.soft_max ? 500 : d.cfg.boundary_delay_ms, { exemptHalt })
}

function schedule(d: Deps, delay: number, opts: BoundaryOpts): void {
  const s = d.state
  s.timer?.cancel()
  s.timer = d.after(delay, () => {
    s.timer = undefined
    s.inflight = boundary(d, opts).catch(() => undefined)
  })
}

/**
 * §9.1 step 3: after `boundary_delay_ms` the handoff turn is opened and submitted; a main
 * `turn.start` first cancels the timer (alive.ts). If it cannot start, a `cap` or
 * `continue-off` cycle gets its normal compaction now, with the full text.
 */
function startHandoffTimer(d: Deps, sid: string, h: HandoffTurn): void {
  const s = d.state
  s.handoffTurn = h
  s.timer?.cancel()
  s.timer = d.after(d.cfg.boundary_delay_ms, () => {
    s.timer = undefined
    s.inflight = (async () => {
      if (s.handoffTurn !== h || h.phase !== 'delay' || s.mainTurnRunning) return
      if (await openAndSubmit(d, sid, h, n => dispatchExists(d, sid, n))) return
      s.handoffTurn = undefined
      if (compactsAfter(h.reason)) await boundary(d, { exemptHalt: true })
    })().catch(() => undefined)
  })
}

/** A main `turn.start` cancels a pending boundary or handoff-turn timer. */
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

/**
 * MOD-SPEC §4: one plugin compaction at a clean turn end, then the after-step and continue.
 * After a handoff turn (§9.1) it runs despite halt and cooldown, with `[handoff]` when the
 * handoff was published, and no continue follows.
 */
export async function boundary(d: Deps, opts: BoundaryOpts = {}): Promise<void> {
  const s = d.state
  const ah = opts.afterHandoff
  if (s.busy || s.mainTurnRunning || s.askOpen > 0 || (s.halt.active && !opts.exemptHalt)) return
  const sid = await d.sessionId()
  const eff = await effective(d, sid)
  if (eff.disabled) return
  const now = await d.now()
  if (!ah && s.lastPluginCompactAt !== undefined && now - s.lastPluginCompactAt < d.cfg.cooldown_ms) return
  const tokens = (await d.usage()).tokens
  if (!ah && (tokens === undefined || tokens < eff.target)) return
  s.busy = true
  try {
    // The nonce the nudge named in `@queue_add@` belongs to this cycle's compaction.
    const named = s.nudgeNonce
    s.nudgeNonce = undefined
    const nonce = named !== undefined && !(await dispatchExists(d, sid, named)) ? named : await drawNonce(n => dispatchExists(d, sid, n))
    const prev = await prevCopy(d, sid)
    const cp = await checkpoint(d, sid, nonce, d.cfg.measured_block)
    const measured = d.cfg.measured_block && cp ? cp.measured_block : null
    const { text, tags } = await mainText(d, nonce, false, prev, measured, ah?.path)
    const pref = await resumePref(d, sid)
    s.selfNonces.add(nonce)
    await writeDispatch(d, {
      sid, nonce, agentId: null, trigger: 'plugin', channel: 'mod-self', resumePref: pref, midturn: false, tags, text,
      ...(ah ? { handoffHt: ah.ht } : {}),
    })
    const t0 = await d.now()
    let r
    try {
      r = await d.compact(text)
    } catch {
      await log(d, sid, 'compact_rejected', { nonce, attempt: 1 })
      return
    }
    const ht: Record<string, string> = ah ? { handoff_ht: ah.ht } : {}
    if (r.skip !== undefined) {
      await log(d, sid, 'compacted', { nonce, skip: skipClass(r.skip), tokens_before: null, tokens_after: null, usage_present: false, ms: (await d.now()) - t0, ...ht })
      return
    }
    await log(d, sid, 'compacted', {
      nonce, skip: null, tokens_before: r.tokensBefore ?? null, tokens_after: r.tokensAfter ?? null,
      usage_present: r.usage !== undefined, ms: (await d.now()) - t0, ...ht,
    })
    s.lastPluginCompactAt = await d.now()
    s.pluginCompactions.push({ turnSeq: s.turnSeq, refilled: null })
    const msgs = r.messages
    const before = r.tokensBefore
    const after = r.tokensAfter
    await guarded(d, sid, 'after-step', () => afterStep(d, {
      sid, nonce, agentId: null, midturn: false, resumePref: pref, messages: msgs, tokensBefore: before, tokensAfter: after,
      ...(ah?.path !== undefined ? { handoff: { published: ah.path } } : {}),
      ...(ah ? { stats: ah.stats } : {}),
    }))
    await guarded(d, sid, 'continue', () => autoContinue(d, sid))
    // The block not carried by a continue waits for prompt.context; the cap may have entered halt.
    if (s.pending && s.pending.nonce === nonce) s.pending.outcome.halt = s.halt.active
  } finally {
    s.busy = false
  }
}
