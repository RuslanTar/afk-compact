// The turn-end scheduler and the self-call path (MOD-SPEC §4, §9), and the scheduling of the
// handoff turn and the compaction after it (§9.1). The engine skips our own `session.compact`
// hook for our `$.session.compact`, so everything happens at the call site.
import type { Deps } from './deps'
import type { ResumePref } from './compact'
import { afterStep, dispatchExists, guarded, mainText, writeDispatch } from './compact'
import { effective } from './config'
import { autoContinue, lastCycleEnd, thrashCheck } from './cont'
import type { HandoffTurn } from './handoff-turn'
import { compactsAfter, endHandoffTurn, haltWins, openAndSubmit, planHandoff } from './handoff-turn'
import type { Checkpoint } from './helper'
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
  afterHandoff?: {
    ht: string
    path: string | undefined
    stats: Record<string, string | number | null>
    /** `nativeCompactSeq` when scheduled: a native compaction since then makes it a second one. */
    seq: number
  }
  /**
   * The dispatch record already written for this compaction, when a native one started while it
   * was written: the rerun after that one's end uses it (same nonce, same text), never a second
   * record (REG-boundary-205, MOD-SPEC §3.1 step 0).
   */
  prepared?: { nonce: string; text: string; pref: ResumePref; prodConsent?: string }
  /**
   * The checkpoint already taken for this compaction, when a native compaction that was running
   * stopped it before its dispatch record was written: the rerun after that one's end reuses it
   * (same nonce, the first sweep's evidence), never a second checkpoint with the same id6, whose
   * sweep would answer `skipped: swept` with no rows (DP-30 (1)).
   */
  checked?: { nonce: string; named: string | undefined; prev: string | undefined; cp: Checkpoint | undefined }
}

/** Main `turn.complete`: bookkeeping, then the boundary guards and timer (MOD-SPEC §9, §9.1). */
export async function onTurnComplete(d: Deps, sid: string, t: TurnEnd): Promise<void> {
  const s = d.state
  s.mainTurnRunning = false
  // Prompts entering an idle session have all started their turns or were refused (a bound).
  s.foreignPrompts = 0
  // Before any await: a native compaction from here on makes the post-handoff one a second one.
  const seq = s.nativeCompactSeq
  s.lastTurnAsksUser = s.askedThisTurn || endsWithQuestion(t.answer)
  if (t.reason !== 'answer') s.resumeAfter = false
  await undeliveredCheck(d, sid)
  const end = await endHandoffTurn(d, sid, t.reason)
  if (end.kind === 'done') return
  if (end.kind === 'compact') {
    schedule(d, 500, { exemptHalt: true, afterHandoff: { ht: end.ht, path: end.path, stats: end.stats, seq } })
    return
  }
  const nudged = s.lastCycle
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
  // A thrash halt found just now outranks the cap or continue-off the nudge saw (DP-4).
  const last = nudged === null ? null : haltWins(d, nudged)
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
      if (await openAndSubmit(d, sid, h, n => dispatchExists(d, sid, n))) {
        // CR-F17: deferred for a prompt that entered and has not started its turn. That turn
        // cancels the handoff turn; a prompt dropped on its way in (now, or already while the
        // close above ran) lets the delay run again.
        if (s.handoffTurn === h && h.phase === 'delay' && !s.mainTurnRunning) {
          if (s.foreignPrompts > 0) s.afterForeign = () => startHandoffTimer(d, sid, h)
          else startHandoffTimer(d, sid, h)
        }
        return
      }
      s.handoffTurn = undefined
      if (compactsAfter(haltWins(d, h.reason))) await boundary(d, { exemptHalt: true })
    })().catch(() => undefined)
  })
}

/** A main `turn.start` cancels a pending boundary or handoff-turn timer. */
export function cancelBoundary(d: Deps): void {
  d.state.timer?.cancel()
  d.state.timer = undefined
  d.state.afterNative = undefined
  d.state.afterForeign = undefined
}

async function resumePref(d: Deps, sid: string): Promise<ResumePref> {
  if (d.state.ctxSeen) return 'prompt.context'
  const p = await d.paths()
  if (p && (await d.exists(`${p.watch}/${sid}/classic-alive.json`))) return 'sessionstart'
  return 'prompt.submit'
}

/**
 * CR-F19, §9.1 End: one compaction after the handoff turn. While a native main compaction runs
 * it waits for that one's end and is then scheduled again (500 ms): `wait`. A native one that
 * compacted since the turn ended was it (§3.1): `ran`. Synchronous, so a caller can check right
 * before an await-free call of `d.compact`.
 */
function nativeCheck(d: Deps, opts: BoundaryOpts): 'wait' | 'ran' | undefined {
  const ah = opts.afterHandoff
  if (!ah) return undefined
  if (d.state.nativeCompacting > 0) {
    d.state.afterNative = () => schedule(d, 500, opts)
    return 'wait'
  }
  return d.state.nativeCompactSeq !== ah.seq ? 'ran' : undefined
}

/**
 * The rows for a post-handoff compaction a native one made a second one: `skip why=compacted`,
 * and, when its dispatch record is already written (`prepared`), `compacted` with
 * `skip: native-ran` and that nonce, which closes the record: reconcile and the watcher then do
 * not report it unresolved (DP-29, E-M-15).
 */
async function nativeRan(d: Deps, sid: string, opts: BoundaryOpts): Promise<void> {
  const ht = opts.afterHandoff?.ht ?? null
  await log(d, sid, 'skip', { why: 'compacted', ht })
  const p = opts.prepared
  if (p === undefined) return
  await log(d, sid, 'compacted', {
    nonce: p.nonce, skip: 'native-ran', tokens_before: null, tokens_after: null, usage_present: false, ms: null,
    ...(ht !== null ? { handoff_ht: ht } : {}),
  })
}

/** `nativeCheck` with its rows; true when the compaction is not run now. */
async function stopForNative(d: Deps, sid: string, opts: BoundaryOpts): Promise<boolean> {
  const c = nativeCheck(d, opts)
  if (c === 'ran') await nativeRan(d, sid, opts)
  return c !== undefined
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
  // No await before this check, so a native compaction's end cannot slip past unseen.
  if (nativeCheck(d, opts) === 'wait') return
  const sid = await d.sessionId()
  if (await stopForNative(d, sid, opts)) return
  const eff = await effective(d, sid)
  if (eff.disabled) return
  const now = await d.now()
  if (!ah && s.lastPluginCompactAt !== undefined && now - s.lastPluginCompactAt < d.cfg.cooldown_ms) return
  const tokens = (await d.usage()).tokens
  if (!ah && (tokens === undefined || tokens < eff.target)) return
  s.busy = true
  try {
    let nonce: string
    let text: string
    let pref: ResumePref
    let prodConsent: string | undefined
    if (opts.prepared) {
      ({ nonce, text, pref, prodConsent } = opts.prepared)
    } else {
      let named: string | undefined
      let prev: string | undefined
      let cp: Checkpoint | undefined
      if (opts.checked) {
        // The rerun after a wait stop: the first checkpoint's nonce and evidence (DP-30 (1)).
        ({ nonce, named, prev, cp } = opts.checked)
        if (s.nudgeNonce === nonce) s.nudgeNonce = undefined
      } else {
        // The nonce the nudge named in `@queue_add@` belongs to this cycle's compaction.
        named = s.nudgeNonce
        s.nudgeNonce = undefined
        nonce = named !== undefined && !(await dispatchExists(d, sid, named)) ? named : await drawNonce(n => dispatchExists(d, sid, n))
        prev = await prevCopy(d, sid)
        cp = await checkpoint(d, sid, nonce, d.cfg.measured_block)
      }
      const measured = d.cfg.measured_block && cp ? cp.measured_block : null
      prodConsent = cp?.consent['unattended_prod_reads']
      const main = await mainText(d, nonce, false, prev, measured, ah?.path)
      text = main.text
      pref = await resumePref(d, sid)
      // The checkpoint above can take seconds: a native compaction may have started or run since.
      // Checked before the dispatch record is written, so a stop leaves no record behind (§3.1
      // step 0), and the nudge's nonce stays this cycle's for the rerun (REG-boundary-205), which
      // reuses this checkpoint.
      if (await stopForNative(d, sid, { ...opts, checked: { nonce, named, prev, cp } })) {
        s.nudgeNonce = named
        return
      }
      s.selfNonces.add(nonce)
      await writeDispatch(d, {
        sid, nonce, agentId: null, trigger: 'plugin', channel: 'mod-self', resumePref: pref, midturn: false, tags: main.tags, text,
        ...(ah ? { handoffHt: ah.ht } : {}),
      })
    }
    // `ms` on every path (as on the mod-hook path, compact.ts): from the dispatch record written
    // (or reused) to the compaction's answer (DP-30 (4)). Read before the check below, so no
    // await sits between that check and the call.
    const t0 = await d.now()
    // Once more after the dispatch write, with no await between this check and the call. A
    // native compaction that started during the write: the rerun after its end reuses this
    // record (`prepared`), so a skipped native one leaves no orphan and no second record.
    const withRecord: BoundaryOpts = { ...opts, prepared: { nonce, text, pref, ...(prodConsent !== undefined ? { prodConsent } : {}) } }
    const late = nativeCheck(d, withRecord)
    if (late !== undefined) {
      if (late === 'ran') await nativeRan(d, sid, withRecord)
      return
    }
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
      ...(prodConsent !== undefined ? { prodConsent } : {}),
    }))
    await guarded(d, sid, 'continue', () => autoContinue(d, sid))
    // The block not carried by a continue waits for prompt.context; the cap may have entered halt.
    if (s.pending && s.pending.nonce === nonce) s.pending.outcome.halt = s.halt.active
  } finally {
    s.busy = false
  }
}
