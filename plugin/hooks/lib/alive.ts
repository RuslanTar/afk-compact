// mod-alive.json (MOD-SPEC §3.3): plugin core, whole-file write at `session.start` and at every
// main `turn.start`, under the current session id, whatever the `watcher` setting. pid and its
// start time come from one helper call (`ident`), cached for the load.
import type { Deps } from './deps'
import { claimTurn, isHuman } from './deps'
import { cancelBoundary } from './boundary'
import { versionCanary } from './canary'
import { effective } from './config'
import { clearHalt, loadHalt } from './cont'
import { onHandoffTurnStart } from './handoff-turn'
import { handoffTurnClose } from './helper'
import { cancelIdle, cancelIdleTimer, loadIdle } from './idle'
import { ensureIdent, isoLocal, log, markHeadless } from './log'
import { claimedElsewhere, logOutcome, settleRecords } from './resume'
import { showNotice } from './notice'
import { shadowPluginSide } from './shadow'
import { restartClaim, restartInterrupt, restartOnEnd } from './restart'

export async function writeAlive(d: Deps, sid: string, turnId: string | null): Promise<void> {
  const p = await d.paths()
  if (!p) return
  const id = d.state.ident ?? { pid: null, pid_lstart: null }
  const rec = { pid: id.pid, pid_lstart: id.pid_lstart, load_id: d.state.loadId, turn_id: turnId, ts: isoLocal(await d.now(), false) }
  await d.write(`${p.watch}/${sid}/mod-alive.json`, JSON.stringify(rec) + '\n')
}

/**
 * Once per load, before any handler acts: the Claude Code version, the effective thresholds
 * (`config_effective` and its rows) and a halt mode persisted by an earlier load.
 */
export async function prepare(d: Deps): Promise<string> {
  const sid = await d.sessionId()
  const s = d.state
  if (!s.initDone) {
    s.initDone = true
    try {
      s.ccVersion = (await d.version()).version
    } catch {
      s.ccVersion = null
    }
    await effective(d, sid)
    await loadHalt(d, sid)
    await loadIdle(d, sid)
  }
  return sid
}

/**
 * Mod `session.start`: pid cache, liveness, C1, the policy and session rows (MOD-SPEC §3.3).
 * `interactive` is the event's `isInteractive`: false (`claude -p`, the Agent SDK) marks the load
 * headless before anything is armed, with its `headless` row after the `session` row.
 */
export async function onSessionStart(d: Deps, interactive?: boolean): Promise<void> {
  if (interactive === false) d.state.headless = true
  await ensureIdent(d, await d.sessionId())
  const sid = await prepare(d)
  await writeAlive(d, sid, null)
  await versionCanary(d, sid)
  const pol = await d.policy()
  await log(d, sid, 'policy', { mods_managed_only: pol.mods_managed_only, hooks_managed_only: pol.hooks_managed_only })
  // WATCHER-SPEC §8 item 8: the first-run notice, once per install (the helper's O_EXCL marker).
  await showNotice(d, sid)
  // WATCHER-SPEC §6.3 `session` fields; unknown values are null, never omitted (§6.2).
  await log(d, sid, 'session', {
    phase: 'start', source: null, reason: null, mod_loaded: true, previous_session_id: null, lineage_reason: null,
    pid_lstart: d.state.ident?.pid_lstart ?? null,
  })
  if (d.state.headless) await markHeadless(d, sid, 'session-start')
  // SESSION-RESTART §5.2, §2.3: the carry note of a restart this session made, and the reports.
  try {
    await restartClaim(d, sid)
  } catch {
    // no claim: the note stays for a later load (or ages into not-confirmed)
  }
}

/**
 * Main `turn.start`: cancels the boundary and pre-idle timers, clears halt on a human-origin
 * turn, starts or cancels the handoff turn (MOD-SPEC §9.1), writes liveness.
 */
export async function onTurnStart(d: Deps, turnId: string, text = ''): Promise<void> {
  const s = d.state
  // Before any await: a handoff-turn timer that is awaiting the helper must see this turn, and
  // our pending submit is claimed by its own turn (§9.1 step 3; CR-F17: a user prompt that
  // entered beside it starts a turn of the user's, which leaves our submit pending).
  cancelBoundary(d)
  cancelIdleTimer(d)
  s.mainTurnRunning = true
  // Claude Code may run our headless `/compact` inside a turn: that turn's end is not a turn end
  // to compact at (boundary.ts), or a /compact that did not compact would repeat on its own.
  s.ownCompactTurn = s.ownCompact !== undefined && /^\/compact\b/.test(text.trim())
  // OT-1 (REVIEW-NIGHT-3 R3-07): with another prompt entering beside ours, a turn whose text is
  // more than ours may carry that prompt too; such a turn is never aborted.
  const otherEntering = s.foreignPrompts > 0
  const sent = s.ourSubmitText
  const ours = claimTurn(s, text)
  const alone = ours && (!otherEntering || text.trim() === (sent ?? '').trim())
  const human = !ours && isHuman(s.turnOrigin)
  // SESSION-RESTART §2.2 step 4, §3.4: a turn took over; an in-flight respawn is cancelled first.
  if (s.restart !== undefined) await restartInterrupt(d)
  await ensureIdent(d, await d.sessionId())
  const sid = await prepare(d)
  // A new session id in a headless load (after a `/clear`): its own `headless` row.
  if (s.headless && s.headlessSid !== sid) await markHeadless(d, sid, 'same-load')
  s.turnSeq++
  s.turnId = turnId
  s.nudgedThisTurn = false
  s.askedThisTurn = false
  s.resumeAfter = false
  s.lastCycle = null
  // A published handoff names only a compaction before the next main turn (§3.1).
  s.published = undefined
  await cancelIdle(d, sid)
  if (!ours) s.nudgeNonce = undefined
  // IC-1 D6: only a person's prompt clears halt; a task notification, a scheduled trigger, a
  // peer or another plugin does not (our own submits never did). It also ends the idle episode.
  if (human) {
    await clearHalt(d, sid)
    s.idleEpisode = undefined
    s.publishedSinceHuman = false
  }
  await onHandoffTurnStart(d, sid, ours, turnId, alone)
  await writeAlive(d, sid, turnId)
}

/**
 * Mod `session.end`, any reason (IC-1 D7 (i)): cancels the boundary and pre-idle timers, takes
 * the pending resume block out of the load, turns off the auto-continue and closes an open
 * handoff turn, so nothing the ended session scheduled is submitted into the next conversation
 * after a `/clear`. The block is dropped (`mod_outcome resume: dropped:session-end`) on a `/clear`
 * or when it has no record on disk, and a `/clear` drops a record an earlier process left for
 * the ended session id too; any other end keeps its record for a `claude --resume` of the same
 * session id (AT-RP-01: no row yet, the block has not settled) unless another channel already
 * delivered it (its `delivered:<channel>` row settles the record). The persisted idle due is
 * forgotten too, except at reason `other` (a `claude respawn`, a signal, a `-p` run done; probe
 * 2026-10-27 P12): no `/exit`, `/clear`, resume or logout ended it, so a process that resumes it
 * under its id before the due re-arms it (loadIdle), as after a supervisor move.
 */
export async function onSessionEnd(d: Deps, endedSid: string, reason?: string): Promise<void> {
  const s = d.state
  cancelBoundary(d)
  cancelIdleTimer(d)
  // SESSION-RESTART §3.4 step 6: the launch note's `go` (or cancel) is the first awaited action.
  await restartOnEnd(d, reason)
  s.resumeAfter = false
  s.lastCycle = null
  s.idleAgain = undefined
  const h = s.handoffTurn
  s.handoffTurn = undefined
  if (h && h.phase !== 'running') shadowPluginSide(d, h, 'cancelled')
  const pend = s.pending
  s.pending = undefined
  // A later `/resume` of a session id in this process looks for its armed record again.
  s.restoreChecked = undefined
  s.restoreClosed = undefined
  if (reason === 'other') d.state.idleDueSid = undefined
  else await cancelIdle(d, endedSid)
  if (h && h.ht !== null && h.phase !== 'running') await handoffTurnClose(d, endedSid, h.ht, 'cancelled')
  if (pend && (reason === 'clear' || pend.persisted !== true)) await logOutcome(d, pend.sid, pend.nonce, pend.outcome, 'dropped:session-end')
  else if (pend) {
    // Kept for a resume unless another channel (the classic SessionStart) already delivered it.
    const where = await claimedElsewhere(d, pend)
    if (where !== 'undelivered') await logOutcome(d, pend.sid, pend.nonce, pend.outcome, where)
  }
  // A `/clear` also drops a block an earlier process left for this session id (armed, not yet taken).
  if (reason === 'clear') await settleRecords(d, endedSid, async () => 'dropped:session-end')
}
