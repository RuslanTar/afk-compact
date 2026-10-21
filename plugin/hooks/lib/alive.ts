// mod-alive.json (MOD-SPEC §3.3): plugin core, whole-file write at `session.start` and at every
// main `turn.start`, under the current session id, whatever the `watcher` setting. pid and its
// start time come from one helper call (`ident`), cached for the load.
import type { Deps } from './deps'
import { cancelBoundary } from './boundary'
import { versionCanary } from './canary'
import { effective } from './config'
import { clearHalt, loadHalt } from './cont'
import { ident } from './helper'
import { helperMissing, isoLocal, log } from './log'

export async function ensureIdent(d: Deps, sid: string): Promise<void> {
  if (d.state.ident) return
  const id = await ident(d, sid)
  if (id) d.state.ident = id
  else {
    d.state.ident = { pid: null, pid_lstart: null }
    await helperMissing(d, sid, 'ident')
  }
}

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
  }
  return sid
}

/** Mod `session.start`: pid cache, liveness, C1, the policy and session rows (MOD-SPEC §3.3). */
export async function onSessionStart(d: Deps): Promise<void> {
  await ensureIdent(d, await d.sessionId())
  const sid = await prepare(d)
  await writeAlive(d, sid, null)
  await versionCanary(d, sid)
  const pol = await d.policy()
  await log(d, sid, 'policy', { mods_managed_only: pol.mods_managed_only, hooks_managed_only: pol.hooks_managed_only })
  await log(d, sid, 'session', { phase: 'start', source: null, mod_loaded: true })
}

/** Main `turn.start`: cancels the boundary timer, clears halt on a user turn, writes liveness. */
export async function onTurnStart(d: Deps, turnId: string): Promise<void> {
  await ensureIdent(d, await d.sessionId())
  const sid = await prepare(d)
  const s = d.state
  cancelBoundary(d)
  s.mainTurnRunning = true
  s.turnSeq++
  s.turnId = turnId
  s.nudgedThisTurn = false
  s.askedThisTurn = false
  s.resumeAfter = false
  if (s.ourSubmitPending) s.ourSubmitPending = false
  else await clearHalt(d, sid)
  await writeAlive(d, sid, turnId)
}
