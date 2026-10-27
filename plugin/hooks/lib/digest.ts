// Away digest phase 1, the digest turn (owner 2026-10-27 12:5x, xxxxxxxx-09: "Pointer on return.
// default setting: submit right away"; AWAY-DIGEST §11). After an idle compaction whose work lane
// reads finished, hard-blocked or soft-blocked, with nothing running (no agent, and no background
// task the measure lists: nothing would open a turn before the person comes back), `idle_digest: submit` (the default) submits one turn right away:
// the digest line with the resume block, whose `[idle-done]` line asks for the full digest.
// `idle_digest: return` submits nothing: the block waits for the next turn, and a person's own
// message gets the at most 5-line pointer of the same line before its answer.
// One `digest_submit {nonce, lane, result}` row per idle compaction of a finished or blocked lane.
import type { Deps } from './deps'
import { submitPending, submitSettled } from './deps'
import { contStamps } from './cont'
import { claimBy } from './helper'
import { digestLine, runningUnits, showsDigest } from './lane'
import { helperMissing, log } from './log'
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
  if (d.cfg.idle_digest !== 'submit') return row(d, sid, nonce, lane, 'skipped:return')
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
  if ((await d.sessionId()) !== sid) return row(d, sid, nonce, lane, 'skipped:session-changed')
  if (s.mainTurnRunning || s.foreignPrompts > 0 || s.busy || s.handoffTurn !== undefined || s.ourSubmitPending) {
    return row(d, sid, nonce, lane, 'skipped:busy')
  }
  if (s.halt.active) return row(d, sid, nonce, lane, 'skipped:halt')
  if (s.headless) return row(d, sid, nonce, lane, 'skipped:headless')
  const max = d.cfg.max_auto_continues_per_hour
  const now = await d.now()
  const stamps = await contStamps(d, sid, now)
  if (max === 0) return row(d, sid, nonce, lane, 'skipped:disabled')
  if (stamps.length >= max) return row(d, sid, nonce, lane, 'skipped:cap')
  const c = await claimBy(d, sid, nonce, 'prompt.submit')
  if (c.result === 'failed') await helperMissing(d, sid, 'claim')
  s.pending = undefined
  if (c.result === 'TAKEN') {
    await row(d, sid, nonce, lane, 'skipped:claimed')
    await logOutcome(d, sid, nonce, pend.outcome, await claimedElsewhere(d, pend))
    return
  }
  const text = digestLine(d.name) + '\n\n' + pend.block
  stamps.push(now)
  await d.storeSet(`cont:${sid}`, stamps)
  submitPending(s, text)
  let submitted = true
  try {
    await d.submit(text)
  } catch {
    submitted = false
    submitSettled(s)
  }
  await row(d, sid, nonce, lane, submitted ? 'submitted' : 'skipped:submit-failed')
  if (submitted) {
    if (pend.lane !== undefined) await logLane(d, sid, nonce, pend.args.lane, pend.lane, 'submit', await runningUnits(d, pend.remeasure, new Set()))
    if (s.idleLane && s.idleLane.nonce === nonce) s.idleLane.shown = lane
  }
  pend.outcome.halt = s.halt.active
  await logOutcome(d, sid, nonce, pend.outcome, submitted ? 'delivered:prompt.submit' : 'undelivered')
}
