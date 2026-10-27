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
import { logOutcome } from './resume'
import { showNotice } from './notice'

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
 * Mod `session.end`, any reason (IC-1 D7 (i)): cancels the boundary and pre-idle timers, drops
 * the pending resume block (`mod_outcome resume: dropped:session-end`), turns off the
 * auto-continue and closes an open handoff turn, so nothing the ended session scheduled is
 * submitted into the next conversation after a `/clear`.
 */
export async function onSessionEnd(d: Deps, endedSid: string): Promise<void> {
  const s = d.state
  cancelBoundary(d)
  cancelIdleTimer(d)
  s.resumeAfter = false
  s.lastCycle = null
  s.idleAgain = undefined
  const h = s.handoffTurn
  s.handoffTurn = undefined
  const pend = s.pending
  s.pending = undefined
  await cancelIdle(d, endedSid)
  if (h && h.ht !== null && h.phase !== 'running') await handoffTurnClose(d, endedSid, h.ht, 'cancelled')
  if (pend) await logOutcome(d, pend.sid, pend.nonce, pend.outcome, 'dropped:session-end')
}
