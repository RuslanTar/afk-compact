// Auto-continue, the hourly cap, halt mode and the thrash rule (MOD-SPEC §9, S-14).
import type { Deps } from './deps'
import { submitPending, submitSettled } from './deps'
import type { HaltReason } from './handoff-turn'
import { claimBy } from './helper'
import { escalate, helperMissing, isoLocal, log } from './log'
import { logOutcome } from './resume'
import { submitDropped } from './idle'

export const HOUR_MS = 3600000

/** MOD-SPEC §9: the continue text's fixed line (the resume block follows when §3.4 requires it). */
export function continueLine(name: string): string {
  return `Note from the user's ${name} plugin: the session was compacted at the checkpoint you reached. Continue from Step 1 of the summary; questions the user owns stay open.`
}

async function haltPath(d: Deps, sid: string): Promise<string | undefined> {
  const p = await d.paths()
  return p ? `${p.watch}/${sid}/halt.json` : undefined
}

/** Reads `<watch>/<sid>/halt.json` into the load state (a reload keeps halt mode). */
export async function loadHalt(d: Deps, sid: string): Promise<void> {
  const path = await haltPath(d, sid)
  if (!path) return
  const t = await d.read(path)
  if (t === undefined) return
  try {
    const j = JSON.parse(t) as { active?: unknown; reason?: unknown }
    if (j.active === true) d.state.halt = { active: true, reason: typeof j.reason === 'string' ? j.reason : null }
  } catch {
    // an unreadable file leaves halt mode off
  }
}

export async function enterHalt(d: Deps, sid: string, reason: '2-nonok' | 'thrash' | 'cap'): Promise<void> {
  const s = d.state
  if (s.halt.active) return
  s.halt = { active: true, reason }
  const path = await haltPath(d, sid)
  if (path) await d.write(path, JSON.stringify({ active: true, reason, since: isoLocal(await d.now(), false) }) + '\n')
  await log(d, sid, 'halt', { reason, active: true })
  escalate(d, 'halt')
}

/** A user-originated main turn clears halt mode and resets the counters. */
export async function clearHalt(d: Deps, sid: string): Promise<void> {
  const s = d.state
  if (!s.halt.active) return
  const was = s.halt.reason
  s.halt = { active: false, reason: null }
  s.consecutiveNonOk = 0
  s.pluginCompactions = []
  s.toasted.delete('halt')
  await d.storeSet(`cont:${sid}`, [])
  const path = await haltPath(d, sid)
  if (path) await d.write(path, JSON.stringify({ active: false, reason: null, since: isoLocal(await d.now(), false) }) + '\n')
  await log(d, sid, 'halt', { reason: was, active: false })
}

/** Counts a main verdict for the 2-consecutive-non-ok rule. */
export async function countVerdict(d: Deps, sid: string, ok: boolean): Promise<void> {
  const s = d.state
  s.consecutiveNonOk = ok ? 0 : s.consecutiveNonOk + 1
  if (s.consecutiveNonOk >= 2) await enterHalt(d, sid, '2-nonok')
}

/**
 * Thrash: two consecutive plugin compactions, each followed by tokens at or above `target`
 * again within fewer than 3 main turns. Called at every main `turn.complete`.
 */
export async function thrashCheck(d: Deps, sid: string, atTarget: boolean): Promise<void> {
  const s = d.state
  const last = s.pluginCompactions[s.pluginCompactions.length - 1]
  if (last && last.refilled === null) {
    const turns = s.turnSeq - last.turnSeq
    if (turns >= 1 && turns < 3 && atTarget) last.refilled = true
    else if (turns >= 3) last.refilled = false
  }
  const n = s.pluginCompactions.length
  const a = s.pluginCompactions[n - 2]
  const b = s.pluginCompactions[n - 1]
  if (!s.halt.active && a?.refilled === true && b?.refilled === true) {
    await log(d, sid, 'thrash', { compactions: 2 })
    escalate(d, 'thrash')
    await enterHalt(d, sid, 'thrash')
  }
}

/** Auto-continue stamps of the last 60 min (`$.store` key `cont:<sid>`, survives reloads). */
export async function contStamps(d: Deps, sid: string, now: number): Promise<number[]> {
  const raw = await d.storeGet(`cont:${sid}`)
  return (Array.isArray(raw) ? raw : []).filter((t): t is number => typeof t === 'number' && now - t < HOUR_MS)
}

/**
 * MOD-SPEC §9.1 last cycle, computed at the nudge: halt mode (`2-nonok`, `thrash`, `cap`), the
 * hourly cap already reached (`cap`, checked now, not after the compaction), or
 * `max_auto_continues_per_hour` 0 (`continue-off`); null for a cycle that will auto-continue.
 */
export async function lastCycleOf(d: Deps, sid: string): Promise<HaltReason | null> {
  const s = d.state
  if (s.halt.active) return s.halt.reason === 'thrash' || s.halt.reason === 'cap' ? s.halt.reason : '2-nonok'
  const max = d.cfg.max_auto_continues_per_hour
  if (max === 0) return 'continue-off'
  return (await contStamps(d, sid, await d.now())).length >= max ? 'cap' : null
}

/**
 * The nudged turn of a last cycle ended with `answer`: no auto-continue follows. A capped cycle
 * enters halt `cap` now, before its handoff turn and compaction (DP-13); the `continue` row says
 * why this cycle does not continue.
 */
export async function lastCycleEnd(d: Deps, sid: string, last: HaltReason): Promise<void> {
  d.state.resumeAfter = false
  if (last === 'cap') {
    await log(d, sid, 'continue_capped', { continues_last_hour: (await contStamps(d, sid, await d.now())).length })
    escalate(d, 'continue-capped')
    await enterHalt(d, sid, 'cap')
  }
  await log(d, sid, 'continue', { result: last === 'continue-off' ? 'skipped:disabled' : `halt:${last}`, continues_last_hour: null })
}

/**
 * After a plugin compaction: auto-continue only after a nudge-driven one, not in halt mode,
 * not when the nudged turn ended on a user-owned question, under the hourly cap. The resume
 * block rides along when the `prompt.submit` claim is still free.
 */
export async function autoContinue(d: Deps, sid: string): Promise<void> {
  const s = d.state
  if (!s.resumeAfter) return
  s.resumeAfter = false
  if (s.halt.active) {
    await log(d, sid, 'continue', { result: `halt:${s.halt.reason ?? 'unknown'}`, continues_last_hour: null })
    return
  }
  if (s.lastTurnAsksUser) {
    await log(d, sid, 'skip', { why: 'asks-user' })
    return
  }
  const max = d.cfg.max_auto_continues_per_hour
  if (max === 0) {
    await log(d, sid, 'continue', { result: 'skipped:disabled', continues_last_hour: null })
    return
  }
  const now = await d.now()
  const key = `cont:${sid}`
  const stamps = await contStamps(d, sid, now)
  // The nudge already called a capped cycle a last cycle (lastCycleOf); this is the backstop.
  if (stamps.length >= max) {
    await log(d, sid, 'continue_capped', { continues_last_hour: stamps.length })
    escalate(d, 'continue-capped')
    await enterHalt(d, sid, 'cap')
    return
  }
  let text = continueLine(d.name)
  const pend = s.pending && s.pending.sid === sid ? s.pending : undefined
  /** Where this continue leaves the pending block (F2-3 `resume`). */
  let resume: string | undefined
  if (pend) {
    const c = await claimBy(d, sid, pend.nonce, 'prompt.submit')
    if (c.result === 'failed') await helperMissing(d, sid, 'claim')
    if (c.result !== 'TAKEN') {
      text += '\n\n' + pend.block
      resume = 'delivered:prompt.submit'
    } else resume = 'delivered:' + (c.by ?? 'unknown')
    s.pending = undefined
  }
  // IC-1 D7 (ii): a `/clear` since the compaction: the old session's continue (and its block)
  // never reaches the new conversation.
  if ((await d.sessionId()) !== sid) {
    await submitDropped(d, sid, 'continue')
    if (pend && resume !== undefined) await logOutcome(d, sid, pend.nonce, pend.outcome, resume === 'delivered:prompt.submit' ? 'dropped:session-end' : resume)
    return
  }
  stamps.push(now)
  await d.storeSet(key, stamps)
  await log(d, sid, 'continue', { result: 'submitted', continues_last_hour: stamps.length })
  submitPending(s, text)
  let submitted = true
  try {
    await d.submit(text)
  } catch {
    submitted = false
    submitSettled(s)
    await log(d, sid, 'continue', { result: 'skipped:submit-failed', continues_last_hour: stamps.length })
  }
  if (pend && resume !== undefined) {
    pend.outcome.continued = submitted
    pend.outcome.halt = s.halt.active
    await logOutcome(d, sid, pend.nonce, pend.outcome, submitted || resume !== 'delivered:prompt.submit' ? resume : 'undelivered')
  }
}
