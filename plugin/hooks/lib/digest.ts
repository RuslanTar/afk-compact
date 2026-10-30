// Away digest phase 1, the digest turn (owner 2026-10-27 12:5x, xxxxxxxx-09: "Pointer on return.
// default setting: submit right away"; AWAY-DIGEST §11). After an idle compaction whose work lane
// reads finished, hard-blocked or soft-blocked, with nothing running (no agent, and no background
// task the measure lists: nothing would open a turn before the person comes back), `idle_digest: submit` submits one turn right away:
// the digest line with the resume block, whose `[idle-done]` line asks for the full digest.
// `idle_digest: return` submits nothing: the block waits for the next turn, and a person's own
// message gets the at most 5-line pointer of the same line before its answer.
// `idle_digest: off` (the default of this version; owner rule (c), 2026-10-28: the digest ships on
// only after a live PASS) submits nothing either, and no text asks for the full digest: the block's
// `[idle-done-off]` line, and every note, ask for one line on the lane state with its Basis, then
// Needs you or Nothing needed from you.
// One `digest_submit {nonce, lane, result}` row per idle compaction of a finished or blocked lane.
// Owner 2026-10-28 digest rules (b): after a background result's turn did the step that result
// unblocked, the lane is read again at that turn's end (`laneTurnEnd`); finished or hard-blocked
// now gets one digest turn too (`submitResultDigest`), or the person's return gets it.
import type { Deps, IdleLane } from './deps'
import { submitPending, submitSettled } from './deps'
import { contStamps } from './cont'
import { claimBy } from './helper'
import type { LaneResult } from './lane'
import { DIGEST_END_RE, OFF_LINE_END_RE, digestLine, laneBasis, laneOf, resultDigestLine, runningUnits, showsDigest } from './lane'
import { helperMissing, log, stamp } from './log'
import { claimedElsewhere, logLane, logOutcome } from './resume'

/** The digest turn waits this long after the compaction (the hook returns first; a person may type). */
export function digestDelayMs(d: Deps): number {
  return Math.max(0, d.cfg.boundary_delay_ms)
}

async function row(d: Deps, sid: string, nonce: string, lane: string, result: string): Promise<void> {
  await log(d, sid, 'digest_submit', { nonce, lane, result })
}

/**
 * Right after the idle compaction's after-step: arms the digest turn when its pending block reads
 * the lane as finished or blocked, the setting is `submit` and nothing runs (an agent's or a
 * background task's result opens a turn of its own, which gets the block).
 */
export async function armDigest(d: Deps, sid: string, nonce: string): Promise<void> {
  const s = d.state
  const pend = s.pending
  if (!pend || pend.nonce !== nonce || pend.sid !== sid || pend.lane === undefined || !showsDigest(pend.lane.lane)) return
  const lane = pend.lane.lane
  if (d.cfg.idle_digest !== 'submit') return row(d, sid, nonce, lane, `skipped:${d.cfg.idle_digest}`)
  if ((await runningUnits(d, pend.remeasure, new Set())) > 0) return row(d, sid, nonce, lane, 'skipped:running')
  d.after(digestDelayMs(d), () => {
    s.inflight = submitDigest(d, sid, nonce).catch(() => undefined)
  })
}

/**
 * The timer fired: the digest turn, unless the block went elsewhere, the session changed, a turn
 * runs or a prompt is entering (that turn gets the block), halt mode is on, the session is
 * headless, auto-continue is off (`max_auto_continues_per_hour` 0) or at its hourly cap (the digest
 * turn counts against it, as a continue does). The block rides along under the `prompt.submit`
 * claim; a block another channel claimed first keeps that channel.
 */
export async function submitDigest(d: Deps, sid: string, nonce: string): Promise<void> {
  const s = d.state
  const pend = s.pending
  if (!pend || pend.nonce !== nonce || pend.sid !== sid) return row(d, sid, nonce, 'unknown', 'skipped:taken')
  const lane = pend.lane?.lane ?? 'working'
  if (d.cfg.idle_digest !== 'submit') return row(d, sid, nonce, lane, `skipped:${d.cfg.idle_digest}`)
  const g = await canSubmit(d, sid)
  if (typeof g === 'string') return row(d, sid, nonce, lane, g)
  const c = await claimBy(d, sid, nonce, 'prompt.submit')
  if (c.result === 'failed') await helperMissing(d, sid, 'claim')
  s.pending = undefined
  if (c.result === 'TAKEN') {
    await row(d, sid, nonce, lane, 'skipped:claimed')
    await logOutcome(d, sid, nonce, pend.outcome, await claimedElsewhere(d, pend))
    return
  }
  const submitted = await send(d, sid, digestLine(d.name) + '\n\n' + pend.block, g)
  await row(d, sid, nonce, lane, submitted ? 'submitted' : 'skipped:submit-failed')
  if (submitted) {
    if (pend.lane !== undefined) await logLane(d, sid, nonce, pend.args.lane, pend.lane, 'submit', await runningUnits(d, pend.remeasure, new Set()))
    if (s.idleLane && s.idleLane.nonce === nonce) {
      s.idleLane.shown = lane
      if (showsDigest(lane)) s.idleLane.digested = true
    }
  }
  pend.outcome.halt = s.halt.active
  await logOutcome(d, sid, nonce, pend.outcome, submitted ? 'delivered:prompt.submit' : 'undelivered')
}

/**
 * Whether a digest turn may be submitted now: the `digest_submit` result that says why not (the
 * session changed, a turn runs or a prompt is entering, halt mode, a headless session,
 * auto-continue off or at its hourly cap), else the continue stamps it counts against.
 */
async function canSubmit(d: Deps, sid: string): Promise<string | { stamps: number[]; now: number }> {
  const s = d.state
  if ((await d.sessionId()) !== sid) return 'skipped:session-changed'
  if (s.mainTurnRunning || s.foreignPrompts > 0 || s.busy || s.handoffTurn !== undefined || s.ourSubmitPending) return 'skipped:busy'
  if (s.halt.active) return 'skipped:halt'
  if (s.headless) return 'skipped:headless'
  const max = d.cfg.max_auto_continues_per_hour
  const now = await d.now()
  const stamps = await contStamps(d, sid, now)
  if (max === 0) return 'skipped:disabled'
  if (stamps.length >= max) return 'skipped:cap'
  return { stamps, now }
}

/** Submits a digest turn's text (counted against the hourly continue cap); false when the submit failed. */
async function send(d: Deps, sid: string, text: string, g: { stamps: number[]; now: number }): Promise<boolean> {
  const s = d.state
  g.stamps.push(g.now)
  await d.storeSet(`cont:${sid}`, g.stamps)
  submitPending(s, text)
  try {
    await d.submit(text)
    return true
  } catch {
    submitSettled(s)
    return false
  }
}

/**
 * Owner 2026-10-28 digest rules (b): at the end of a main turn whose job result unblocked a step
 * held on that job (the lane read working for that turn only: rule (a), lane.ts `laneOf`
 * `byResult`), the lane is read again without that result, so the step the turn did no longer
 * counts. When it now reads finished or hard-blocked, the user still gets the blocked digest,
 * once: with `idle_digest: submit` one digest turn is submitted right away (the
 * same checks and hourly cap as the digest turn after the compaction); with `return` the
 * person's return gets it (the `[idle-again]` block, read again then, carries `[idle-done]`);
 * with `off` no turn either, and that block carries `[idle-done-off]` (one line, no digest).
 * No turn is submitted when this turn's answer already ends with the digest (the `[idle]` block's
 * step 5 asks for it when all left waits on the user; under `off`, the one line, `OFF_LINE_END_RE`), or when a turn of this episode was already
 * told a finished or blocked lane (one digest per episode): then the next turn not of a person's
 * gets the one-line note on the new state, as after any change (`laneRecheck`), and the person's
 * return the block read again. Something still running: no change (its result opens a turn,
 * re-checked as before).
 */
export async function laneTurnEnd(d: Deps, sid: string, reason: string, answer: string): Promise<void> {
  const s = d.state
  const l = s.idleLane
  if (!l || l.sid !== sid) return
  const unblocked = l.unblocked
  l.result = false
  l.unblocked = false
  if (!unblocked || l.closed || l.shown === undefined || s.halt.active || reason !== 'answer') return
  const r = await laneNow(d, l)
  if (r === undefined) return
  await logLane(d, sid, l.nonce, l.facts, r.lane, 'recheck', r.running)
  if (DIGEST_END_RE.test(answer) || (d.cfg.idle_digest === 'off' && OFF_LINE_END_RE.test(answer))) {
    l.shown = r.lane.lane
    l.digested = true
    return
  }
  // A digest went out earlier in the episode: no second one. The lane told stays as it was (this
  // turn's working), so the next turn not of a person's gets the one-line note on the new state
  // (`laneRecheck`), and the person's return the block read again.
  if (l.digested) return
  if (d.cfg.idle_digest !== 'submit') return row(d, sid, l.nonce, r.lane.lane, `skipped:${d.cfg.idle_digest}`)
  const nonce = l.nonce
  d.after(digestDelayMs(d), () => {
    s.inflight = submitResultDigest(d, sid, nonce).catch(() => undefined)
  })
}

/** The episode's lane read now with no result in (finished or hard-blocked only), and the units running. */
async function laneNow(d: Deps, l: IdleLane): Promise<{ lane: LaneResult; running: number } | undefined> {
  const running = await runningUnits(d, l.restored ? undefined : l.remeasure, l.ended)
  const lane = laneOf(l.facts, { running, midturn: false, nonok: l.nonok, driver: l.driver, superseded: l.superseded })
  return lane.lane === 'finished' || lane.lane === 'hard-blocked' ? { lane, running } : undefined
}

/**
 * The timer `laneTurnEnd` armed fired: the digest turn of rule (b), unless the episode ended or
 * changed (a person's prompt, a newer compaction, a digest already told), the lane no longer reads
 * finished or hard-blocked (work started, a unit runs), or `canSubmit` says no. A turn of the
 * episode not told the lane yet still gets it from `laneRecheck`.
 */
export async function submitResultDigest(d: Deps, sid: string, nonce: string): Promise<void> {
  const s = d.state
  const l = s.idleLane
  if (!l || l.nonce !== nonce || l.sid !== sid || l.closed || l.digested || s.halt.active) return row(d, sid, nonce, 'unknown', 'skipped:taken')
  const r = await laneNow(d, l)
  if (r === undefined) return
  const lane = r.lane.lane
  if (d.cfg.idle_digest !== 'submit') return row(d, sid, nonce, lane, `skipped:${d.cfg.idle_digest}`)
  // The git facts are the stored measure's (no helper call here): the Basis says when it was taken.
  // Stamped before `canSubmit`, so the zone lookup's file check does not widen its gap to `send`.
  const asOf = l.measuredAt !== undefined ? (await stamp(d, l.measuredAt, false)).slice(11, 16) : undefined
  const g = await canSubmit(d, sid)
  if (typeof g === 'string') return row(d, sid, nonce, lane, g)
  const submitted = await send(d, sid, resultDigestLine(d.name, r.lane, laneBasis(l.facts, r.running, l.remeasure, asOf)), g)
  await row(d, sid, nonce, lane, submitted ? 'submitted' : 'skipped:submit-failed')
  if (!submitted) return
  l.shown = lane
  l.digested = true
  await logLane(d, sid, nonce, l.facts, r.lane, 'submit', r.running)
}
