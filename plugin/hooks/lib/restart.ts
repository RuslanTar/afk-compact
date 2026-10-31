// Restart on update (SESSION-RESTART): at a compaction boundary (D2: right after a plugin
// compaction at a turn end, before its continue; right after an idle compaction) a session that
// opted in (`restart_on_update: on`, settings file only, D1) and passes every gate of §4.1 moves
// onto a newly installed Claude Code and keeps its session id.
// - Background sessions (`claude --bg`): the helper starts `claude respawn <job>` detached, the
//   way `/restart` does (§2.2); the new process confirms (§2.3). A refusal before the kill, or a
//   worker still alive after 60 s, is a failure, and the normal continue runs.
// - Terminal sessions started through the plugin's launcher (§3): a transcript line, a 5 s grace,
//   then the plugin's own `/exit`; the launcher relaunches `--resume` only on the launch note's
//   `go` (the launcher's file contract, protocol 1). Shipped off pending the owner's decision
//   (RS-P1 run 2, outcome (c)): the helper's gate answers `fg-not-shipped` (lib/restart.pm
//   $FG_ROUTE). The background route is shipped off too until its restriction gate and a full
//   RS-P5 on the real helper pass (`bg-not-shipped`, $BG_ROUTE).
// `shadow` runs the gates and writes one `refresh_would` row per moment, nothing else: there the
// launcher's checks and background work do not refuse, and the row says what they found (the
// trial data of the terminal route's ship decision). Every failure before the process ends runs
// the deferred continue once (§4.4). Rows are content-free (§6.3).
import type { Deps } from './deps'
import { isHuman, isOwnOrigin } from './deps'
import { autoContinue, continueDecision, submitContinue } from './cont'
import { call } from './helper'
import { agentsRunning } from './idle'
import { log } from './log'
import { randomHex } from './nonce'

export type RestartSetting = 'off' | 'shadow' | 'on'
export type RestartEnv = { kind?: string; backend?: string; jobDir?: string; launch?: string }
export type RestartReport = { short: string; to: string | null; code: string }
type Route = 'fg' | 'bg'

/** One restart from its arm to its end (LoadState.restart). */
export type RestartRun = {
  sid: string
  route: Route
  nonce: string
  from: string
  to: string
  /** The note's `continue`: the new load submits the continue (§5.3). */
  cont: boolean
  /**
   * The moment's own path runs autoContinue (a compaction at a turn end, not an idle one): a
   * failure before the process ends runs it once, as if no restart had been tried (§4.4). An
   * idle restart (D2b) never does.
   */
  contDue: boolean
  armedAt: number
  /** grace: the 5 s notice; exiting: both notes `exiting` and our /exit queued; sent: the respawn started. */
  phase: 'grace' | 'exiting' | 'sent' | 'done'
  launch?: string
  token?: string
  jobDir?: string
  short?: string
  mode: string
  effort: string
  model: string
  exitingAt?: number
  timer?: { cancel: () => void }
}

/** §3.4 step 3, §2.2 step 2: the notice before the restart. */
export const RESTART_GRACE_MS = 5000
/** §3.4 step 6: `session.end` this soon after the `exiting` write before our `/exit` is ours. */
export const EXIT_WINDOW_MS = 5000
/** §2.2 step 4: the worker still alive this long after the respawn started is a failure. */
export const RESPAWN_WATCH_MS = 60000
export const RESPAWN_POLL_MS = 2000
/** G5: `claude --version` at most once per 30 minutes per load, bounded to 5 s. */
export const DRIFT_TTL_MS = 30 * 60000
export const DRIFT_PROBE_MS = 5000
/** G13 (§4.3). */
export const RESTART_COOLDOWN_MS = 10 * 60000
export const RESTARTS_PER_DAY = 2
export const DAY_MS = 86400000
export const TRIED_KEEP = 8
/** The failures after which one more attempt at the same target follows (§4.3). */
export const RETRYABLE: readonly string[] = ['exit-not-run', 'exit-refused', 'respawn-refused', 'not-respawned']
/** §5.3: the continue in the new load, this long after the claim. */
export const CLAIM_CONTINUE_MS = 2000
/** G8 (D11): a person seen at the prompt this recently is present. */
export const RESTART_PRESENT_MS = 60000
/** The helper's gate call (§4.1: one call, 1.5 s). */
export const GATE_MS = 1500
/** The respawn call's refusals that start nothing and are skips, not failures (G3b, B9, G1, §8.4). */
export const RESPAWN_SKIPS: readonly string[] = ['bypass-left', 'restriction-lost', 'keepset-unverified', 'off', 'bg-not-shipped']

/**
 * §3.5, the launcher's file contract §4: the launcher's patterns for the note values the mod
 * supplies. A model never starts with `-` (it could read as a flag).
 */
export const MODEL_RE = /^(?!-)[A-Za-z0-9._:/[\]-]{1,100}$/
const VERSION_RE = /^[0-9]+\.[0-9]+\.[0-9]+$/

/** `x.y.z` from `claude --version` output (`2.1.311 (Claude Code)`), or undefined (a dev build, other text). */
export function parseVersion(out: string): string | undefined {
  const w = out.trim().split(/\s+/)[0] ?? ''
  return VERSION_RE.test(w) && w.length <= 32 ? w : undefined
}

/** -1, 0 or 1 for two `x.y.z` versions. */
export function vcmp(a: string, b: string): number {
  const x = a.split('.').map(Number)
  const y = b.split('.').map(Number)
  for (let i = 0; i < 3; i++) {
    const c = (x[i] ?? 0) - (y[i] ?? 0)
    if (c !== 0) return c > 0 ? 1 : -1
  }
  return 0
}

/** The text lines (§3.4 step 2, §2.2 step 2, §2.3). They name no command the model could run. */
export function noticeText(name: string, route: Route, to: string): string {
  return route === 'bg'
    ? `${name}: Claude Code ${to} is installed; restarting this background session on it in 5 s (same session). Type anything to stop.`
    : `${name}: Claude Code ${to} is installed; restarting this session on it in 5 s (same session). Type anything to stop.`
}
export function doneText(name: string, from: string, to: string): string {
  return `${name}: this session restarted on Claude Code ${to} (was ${from}); same session.`
}
export function lostText(name: string, short: string, to: string | null): string {
  return `${name}: a background session (${short}) did not come back after a restart on Claude Code ${to ?? 'the new version'}; see /${name}:status.`
}

type Tried = { targets: Record<string, { n: number; why: string | null }>; attempts: number[]; last: number | null }

function triedKey(sid: string): string {
  return `restart_tried:${sid}`
}

async function readTried(d: Deps, sid: string): Promise<Tried> {
  const v = (await d.storeGet(triedKey(sid))) as Partial<Tried> | null | undefined
  const targets: Tried['targets'] = {}
  if (v && typeof v.targets === 'object' && v.targets !== null) {
    for (const [k, t] of Object.entries(v.targets)) {
      if (t && typeof t.n === 'number') targets[k] = { n: t.n, why: typeof t.why === 'string' ? t.why : null }
    }
  }
  const attempts = Array.isArray(v?.attempts) ? v.attempts.filter((x): x is number => typeof x === 'number') : []
  return { targets, attempts, last: typeof v?.last === 'number' ? v.last : null }
}

/** One attempt at `to` begins (G13 counts it). */
async function noteAttempt(d: Deps, sid: string, to: string, now: number): Promise<void> {
  const t = await readTried(d, sid)
  const cur = t.targets[to]
  t.targets[to] = { n: (cur?.n ?? 0) + 1, why: null }
  const keys = Object.keys(t.targets)
  for (const k of keys.slice(0, Math.max(0, keys.length - TRIED_KEEP))) delete t.targets[k]
  t.attempts = [...t.attempts.filter(x => now - x < DAY_MS), now]
  t.last = now
  await d.storeSet(triedKey(sid), t)
}

/** How the attempt at `to` ended (a retryable failure allows one more). */
export async function noteOutcome(d: Deps, sid: string, to: string, why: string): Promise<void> {
  const t = await readTried(d, sid)
  const cur = t.targets[to]
  t.targets[to] = { n: Math.max(cur?.n ?? 0, why === 'same-version' || why === 'not-confirmed' ? 2 : 1), why }
  await d.storeSet(triedKey(sid), t)
}

/** G13: `tried`, `cap` or `cooldown`, else undefined. */
async function bounds(d: Deps, sid: string, to: string, now: number): Promise<string | undefined> {
  const t = await readTried(d, sid)
  const cur = t.targets[to]
  if (cur && (cur.n >= 2 || (cur.n === 1 && !RETRYABLE.includes(cur.why ?? '')))) return 'tried'
  if (t.attempts.filter(x => now - x < DAY_MS).length >= RESTARTS_PER_DAY) return 'cap'
  if (t.last !== null && now - t.last < RESTART_COOLDOWN_MS) return 'cooldown'
  return undefined
}

/**
 * G2, G6, G8, G9, G10, G11 in memory. `moment`: called from inside the compaction's own after-step,
 * where the plugin's own `busy` flag and the native compaction counter are this compaction's.
 * `items` (shadow): a running agent does not refuse; `agent` is added to the list instead.
 */
async function liveWhy(d: Deps, sid: string, route: Route, moment: boolean, items?: string[]): Promise<string | undefined> {
  const s = d.state
  if (s.headless) return 'headless'
  if (s.mainTurnRunning || s.foreignPrompts > 0 || s.handoffTurn !== undefined || s.ourSubmitPending || s.ownCompact !== undefined) return 'busy'
  if (!moment && (s.busy || s.nativeCompacting > 0)) return 'busy'
  if (!s.lastTurnAnswer) return 'aborted'
  if (s.askOpen > 0 || s.lastTurnAsksUser) return 'asks-user'
  if (s.halt.active) return 'halted'
  if ((await agentsRunning(d)) > 0) {
    if (items === undefined) return 'agents'
    items.push('agent')
  }
  const draft = await d.promptDraft()
  if (draft === undefined || draft.trim() !== '') return 'draft'
  if (s.lastInputAt !== undefined && (await d.now()) - s.lastInputAt < RESTART_PRESENT_MS) return 'present'
  const surf = await d.surfaces()
  const others = surf === undefined || surf.some(x => x !== 'terminal')
  if (route === 'bg' && (others || s.attached > 0)) return 'attached'
  if (others || s.restartBlocks.has('remote')) return 'remote'
  for (const b of ['session-rules', 'session-dirs', 'worktree']) if (s.restartBlocks.has(b)) return b
  // G11: the resume block of this compaction is on disk (resume-pending.json), or none is
  // pending: a session end keeps only a persisted block, so the new process would lose it.
  if (s.pending && s.pending.sid === sid && s.pending.persisted !== true) return 'block-not-saved'
  if (s.ending || (await d.sessionId()) !== sid) return 'busy'
  return undefined
}

/** One `refresh_skipped` (or `refresh_would`) row per (why, to) per load (§4.1). */
async function once(d: Deps, sid: string, ev: string, key: string, fields: Record<string, string | boolean | null | readonly string[]>): Promise<void> {
  const k = `${ev}|${key}`
  if (d.state.restartLogged.has(k)) return
  d.state.restartLogged.add(k)
  await log(d, sid, ev, fields)
}

/**
 * G5: the installed version from `claude --version`, cached for DRIFT_TTL_MS: null when the probe
 * failed (a timeout, a non-zero exit, no output: `version-unknown`), `dev` for a dev build or any
 * other text (never a target, no row).
 */
async function installed(d: Deps): Promise<string | null> {
  const s = d.state
  const now = await d.now()
  if (s.drift && now - s.drift.at < DRIFT_TTL_MS) return s.drift.installed
  const r = await d.run(['claude', '--version'], DRIFT_PROBE_MS)
  const out = r.ok ? r.stdout.trim() : ''
  s.drift = { at: now, installed: out === '' ? null : parseVersion(out) ?? 'dev' }
  return s.drift.installed
}

type Gate = {
  ok: boolean
  why: string | null
  /** The setting as the helper read it for this gate (the settings file now, not the load's ident). */
  setting: RestartSetting
  route: Route
  mode: string | null
  effort: string | null
  job_short: string | null
  token: string | null
  types: string[]
  /** Shadow: the background task types the newest Stop listed (items the exit dialog counts). */
  items: string[]
  /** Shadow, fg: what G3 found about the launcher (`ok`, or its why). */
  launcher: string | null
}

function parseGate(out: string): Gate | undefined {
  try {
    const j = JSON.parse(out.trim()) as Record<string, unknown>
    const str = (v: unknown): string | null => (typeof v === 'string' ? v : null)
    return {
      ok: j.ok === true, why: str(j.why), setting: j.setting === 'on' || j.setting === 'shadow' ? j.setting : 'off',
      route: j.route === 'bg' ? 'bg' : 'fg', mode: str(j.mode), effort: str(j.effort),
      job_short: str(j.job_short), token: str(j.token), types: words(j.types), items: words(j.items), launcher: str(j.launcher),
    }
  } catch {
    return undefined
  }
}

function words(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string' && /^[a-z][a-z0-9_-]{0,39}$/.test(x)) : []
}

function jsonOf(out: string): Record<string, unknown> | undefined {
  try {
    const j = JSON.parse(out.trim()) as unknown
    return j !== null && typeof j === 'object' ? (j as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

/** The route and its folder flags from the env (§2.1, §3.2). */
function routeOf(env: RestartEnv): { route: Route; flags: string[]; why?: string } {
  if (env.kind === 'bg') {
    if (env.backend !== 'daemon' || env.jobDir === undefined) return { route: 'bg', flags: [], why: 'job-unknown' }
    return { route: 'bg', flags: ['--job-dir', env.jobDir] }
  }
  return { route: 'fg', flags: env.launch !== undefined ? ['--launch', env.launch] : [] }
}

/**
 * D10 (root call 2026-10-28 00:23): a main hook input's permission_mode, observed (Stop,
 * UserPromptSubmit, PermissionRequest; PreCompact, PostCompact and SessionEnd carry none on 2.1.312).
 * The newest one goes to the gate with the start of the last main turn of this load.
 */
export function noteMode(d: Pick<Deps, 'state'>, e: { permission_mode?: unknown; agent_id?: unknown }, at: number): void {
  if (e.agent_id !== undefined && e.agent_id !== null) return
  const m = e.permission_mode
  if (typeof m !== 'string' || !MODES.includes(m)) return
  const cur = d.state.modeSeen
  if (cur === undefined || at >= cur.at) d.state.modeSeen = { mode: m, at }
}

/** The permission modes by their internal names (R6: the CLI spells `default` as `manual`). */
export const MODES: readonly string[] = ['acceptEdits', 'auto', 'bypassPermissions', 'default', 'dontAsk', 'plan']

/**
 * The restart moment (D2): called right after a plugin compaction's after-step, before its continue
 * (`cont` true when a continue may follow), or after an idle compaction (`cont` false). True when a
 * restart was armed: it now owns the continue (run once on any failure before the process ends);
 * false when the normal path goes on.
 */
export async function restartMoment(d: Deps, sid: string, o: { cont: boolean }): Promise<boolean> {
  const s = d.state
  const setting = s.ident?.restart ?? 'off'
  if (setting === 'off' || s.restart !== undefined) return false
  // §5.3: a continue that would enter halt (`cap`) does not restart; the normal path runs.
  const dec: { go: boolean; why?: string } = o.cont ? await continueDecision(d, sid) : { go: false }
  if (o.cont && dec.why === 'cap') return false
  const env = await d.restartEnv()
  const rt = routeOf(env)
  const route = rt.route
  const model = (await d.model()) ?? ''
  // Shadow: the items a restart would refuse for are recorded on the row, not refused for.
  const items: string[] | undefined = setting === 'shadow' ? [] : undefined
  let why = await liveWhy(d, sid, route, true, items)
  const now = await d.now()
  // G5 first among what the rows need: a session with nothing newer installed logs nothing.
  let from: string | undefined
  try {
    from = (await d.version()).version
  } catch {
    from = undefined
  }
  // A dev build (or any other form) is never restarted from or to (§4.3).
  if (from === undefined || !VERSION_RE.test(from)) return false
  const inst = await installed(d)
  if (inst === null) {
    await once(d, sid, 'refresh_skipped', 'version-unknown|', { why: 'version-unknown', route, to: null })
    return false
  }
  if (inst === 'dev' || vcmp(inst, from) <= 0) return false
  const to = inst
  if (!s.driftLogged.has(to)) {
    s.driftLogged.add(to)
    await log(d, sid, 'version_drift', { running: from, installed: to })
  }
  why ??= rt.why
  why ??= await bounds(d, sid, to, now)
  if (why === undefined && model !== '' && !MODEL_RE.test(model)) why = 'note-pattern'
  if (why !== undefined) {
    await once(d, sid, 'refresh_skipped', `${why}|${to}`, { why, route, to })
    return false
  }
  const seen = s.modeSeen
  // D10: the start of this load's last main turn; with none yet (an idle compaction this load
  // adopted), the load's start, so a Stop an earlier process wrote counts as older than the last
  // turn and the launch mode narrows it; with no stamp at all, this moment.
  const turnAt = s.lastMainTurnAt ?? s.sessionStartAt ?? now
  const g = await call(d, ['restart', 'gate', '--sid', sid, '--route', route, ...rt.flags, '--from', from, '--to', to, '--model', model,
    ...(seen !== undefined ? ['--seen-mode', seen.mode, '--seen-at', String(Math.round(seen.at))] : []),
    '--turn-at', String(Math.round(turnAt)), '--now-ms', String(Math.round(now))], GATE_MS)
  const gate = g.ok ? parseGate(g.stdout) : undefined
  if (!gate || !gate.ok) {
    const w = gate?.why ?? 'helper-failed'
    await once(d, sid, 'refresh_skipped', `${w}|${to}`, { why: w, route, to, ...(gate && gate.types.length > 0 ? { types: gate.types } : {}) })
    return false
  }
  // G1 as the gate read it: the load's ident is cached, so a setting lowered to `shadow` (or
  // `off`, which the gate refuses) since the load counts from the gate on.
  if (gate.setting !== 'on') {
    // One row per moment (the trial counts them), with the dialog-capable items it saw: the
    // newest Stop's background tasks and the running agents.
    if (gate.setting === 'shadow') {
      const seenItems = [...new Set([...gate.items, ...(items ?? [])])].sort()
      await log(d, sid, 'refresh_would', { route, from, to, continue: dec.go, items: seenItems, ...(route === 'fg' ? { launcher: gate.launcher ?? 'no-launcher' } : {}) })
    }
    return false
  }
  // A gate that read `on` while the load's ident said `shadow` collected items instead of refusing.
  if (items !== undefined && items.length > 0) {
    await once(d, sid, 'refresh_skipped', `agents|${to}`, { why: 'agents', route, to })
    return false
  }
  const nonce = randomHex(16)
  const mode = gate.mode ?? 'default'
  const effort = gate.effort ?? ''
  await noteAttempt(d, sid, to, now)
  const a = await call(d, ['restart', 'arm', '--sid', sid, '--route', route, ...rt.flags, '--nonce', nonce, '--from', from, '--to', to,
    '--continue', dec.go ? '1' : '0', '--mode', mode, '--effort', effort, '--model', model, '--load-id', s.loadId, '--now-ms', String(Math.round(now))])
  const armed = a.ok ? jsonOf(a.stdout) : undefined
  if (!armed || armed.ok !== true) {
    const w = typeof armed?.why === 'string' ? armed.why : 'arm-failed'
    await noteOutcome(d, sid, to, w)
    await once(d, sid, 'refresh_skipped', `${w}|${to}`, { why: w, route, to })
    return false
  }
  const run: RestartRun = {
    sid, route, nonce, from, to, cont: dec.go, contDue: o.cont, armedAt: now, phase: 'grace', mode, effort, model,
    ...(route === 'fg' && env.launch !== undefined ? { launch: env.launch } : {}),
    ...(typeof armed.token === 'string' ? { token: armed.token } : {}),
    ...(route === 'bg' && env.jobDir !== undefined ? { jobDir: env.jobDir } : {}),
    ...(gate.job_short !== null ? { short: gate.job_short } : {}),
  }
  s.restart = run
  d.uiLog(noticeText(d.name, route, to))
  await log(d, sid, 'refresh_start', { route, from, to, continue: dec.go })
  run.timer = d.after(RESTART_GRACE_MS, () => {
    s.inflight = graceEnd(d, run).catch(() => undefined)
  })
  return true
}

/**
 * `restart set` for this run's notes (the launch note first). `ok` false: the call failed (it did
 * not start, timed out or exited non-zero). Otherwise `l` and `c` say what the helper did with
 * each note: `written`, `absent`, `mismatch` (another nonce or session) or `final` (already ended).
 */
type SetReply = { ok: boolean; l: string; c: string; why?: string }

async function setNotes(d: Deps, run: RestartRun, state: string, o: { extra?: string[]; timeoutMs?: number; now?: number } = {}): Promise<SetReply> {
  const now = o.now ?? (await d.now())
  const args = ['restart', 'set', '--sid', run.sid, '--nonce', run.nonce, '--state', state, '--now-ms', String(Math.round(now)), ...(o.extra ?? []),
    ...(run.route === 'fg' && run.launch !== undefined ? ['--launch', run.launch] : [])]
  const r = o.timeoutMs === undefined ? await call(d, args) : await call(d, args, o.timeoutMs)
  const j = r.ok ? jsonOf(r.stdout) : undefined
  if (!j || j.ok !== true) return { ok: false, l: 'failed', c: 'failed', ...(typeof j?.why === 'string' ? { why: j.why } : {}) }
  return { ok: true, l: typeof j.l === 'string' ? j.l : 'absent', c: typeof j.c === 'string' ? j.c : 'absent' }
}

/**
 * `restart respawn-cancel` (§2.2 step 4): in one helper call, the carry note `state` (when it is
 * still this nonce's `armed` or `sent`), then TERM to the detached respawn's process group when its
 * record names this nonce. The note goes first, so a respawn that has not reached its own check of
 * the note yet never starts the client.
 */
async function cancelRespawn(d: Deps, run: RestartRun, state: 'cancelled' | 'failed'): Promise<void> {
  await call(d, ['restart', 'respawn-cancel', '--sid', run.sid, '--nonce', run.nonce, '--state', state])
}

/** The run ends before the process does: notes, one row, the continue once (§4.4). */
async function fail(d: Deps, run: RestartRun, ev: 'refresh_skipped' | 'refresh_failed', why: string, opts: { state?: string; code?: string; cont?: boolean } = {}): Promise<void> {
  const s = d.state
  // A turn or a prompt ended the run during the caller's last await (restartInterrupt settled
  // it): the person or the task has the session; no second row and no continue.
  if (run.phase === 'done') return
  run.timer?.cancel()
  run.phase = 'done'
  if (s.restart === run) s.restart = undefined
  await setNotes(d, run, opts.state ?? 'cancelled').catch(() => undefined)
  await noteOutcome(d, run.sid, run.to, why)
  await log(d, run.sid, ev, { route: run.route, why, to: run.to, ...(opts.code !== undefined ? { code: opts.code } : {}) })
  // Only where the moment's own path would have run it: never after an idle compaction (D2b).
  if (run.contDue && opts.cont !== false) await autoContinue(d, run.sid)
}

/** §3.4 step 3, §2.2 step 2: after the grace, the live gates once more, then the exit or the respawn. */
async function graceEnd(d: Deps, run: RestartRun): Promise<void> {
  const s = d.state
  if (s.restart !== run || run.phase !== 'grace') return
  run.timer = undefined
  const why = await liveWhy(d, run.sid, run.route, false)
  if (why !== undefined) return fail(d, run, 'refresh_skipped', why)
  if (run.route === 'fg') {
    // §3.4 step 4. Both notes become `exiting` (with `exiting_at`) before our /exit is queued:
    // our own `command.run` hook never sees a `$.command.run` of ours (RS-P1: the engine skips the
    // raising plugin's hooks), so nothing of ours can write it later or veto a stale /exit.
    if (s.restart !== run || run.phase !== 'grace') return
    const at = await d.now()
    // Our /exit follows only when both notes now say `exiting`: a launch note the helper found
    // absent, another session's or already ended would close the session with no relaunch (D9).
    const w = await setNotes(d, run, 'exiting', { extra: ['--exiting-at', String(Math.round(at))], now: at })
    if (s.restart !== run || run.phase !== 'grace') return
    // The helper's second check: the setting turned off during the grace, or the route not shipped.
    if (!w.ok && (w.why === 'off' || w.why === 'fg-not-shipped')) return fail(d, run, 'refresh_skipped', w.why)
    if (!w.ok) return fail(d, run, 'refresh_failed', 'helper-failed')
    if (w.l !== 'written' || w.c !== 'written') {
      return fail(d, run, 'refresh_failed', 'helper-failed', { code: w.l !== 'written' ? `launch-${w.l}` : `carry-${w.c}` })
    }
    run.phase = 'exiting'
    run.exitingAt = at
    // §3.4 step 7: still alive EXIT_WINDOW_MS later (an exit dialog, a detach, an /exit that never
    // ran): both notes cancelled first, then the continue.
    run.timer = d.after(EXIT_WINDOW_MS, () => {
      if (s.restart === run && run.phase === 'exiting' && !s.ending) s.inflight = fail(d, run, 'refresh_failed', 'exit-not-run').catch(() => undefined)
    })
    // Its resolution is no success signal (`{text: ''}` on a clean exit and on a kill alike):
    // only a rejection is read (F2); the outcome is `session.end` or the watchdog above.
    void d.commandRun('exit').then(
      () => undefined,
      () => {
        if (s.restart === run && run.phase === 'exiting' && !s.ending) s.inflight = fail(d, run, 'refresh_failed', 'exit-refused').catch(() => undefined)
      },
    )
    return
  }
  // The background route: the carry note `sent` and the detached respawn in one helper call. A
  // turn or a prompt during the awaits above ended the run (restartInterrupt): nothing starts.
  if (s.restart !== run || run.phase !== 'grace') return
  run.phase = 'sent'
  // The helper reads the job's respawnFlags once more right before it starts the respawn (G3b
  // `bypass-left` against the mode they hold now, a Shift+Tab during the grace included).
  const r = await call(d, ['restart', 'respawn', '--sid', run.sid, '--short', run.short ?? '', '--nonce', run.nonce, '--to', run.to,
    '--mode', run.mode, ...(run.jobDir !== undefined ? ['--job-dir', run.jobDir] : [])])
  const j = r.ok ? jsonOf(r.stdout) : undefined
  if (s.restart !== run || run.phase !== 'sent') {
    // A turn or a prompt came while the call ran: restartInterrupt cancelled the run, maybe before
    // the respawn's pid record existed. Once more now (§2.2 step 4: never a kill during that turn).
    await cancelRespawn(d, run, 'cancelled')
    return
  }
  if (!j || j.ok !== true) {
    // A refusal, or a call that failed or timed out after the helper may have started the detached
    // respawn: the respawn is cancelled (the note settled first) before the continue runs.
    const why = typeof j?.why === 'string' ? j.why : undefined
    // The job's flags read again at the respawn (G3b, B9), the setting turned off during the grace
    // or the route's ship gate: refused before anything started.
    if (why !== undefined && RESPAWN_SKIPS.includes(why)) {
      await cancelRespawn(d, run, 'cancelled')
      return fail(d, run, 'refresh_skipped', why)
    }
    await cancelRespawn(d, run, 'failed')
    return fail(d, run, 'refresh_failed', 'respawn-refused', { state: 'failed', code: why ?? 'other' })
  }
  const started = await d.now()
  const poll = (): void => {
    run.timer = d.after(RESPAWN_POLL_MS, () => {
      s.inflight = respawnWatch(d, run, started, poll).catch(() => undefined)
    })
  }
  poll()
}

/** §2.2 step 4: the worker still runs, so the respawn has not killed it yet. */
async function respawnWatch(d: Deps, run: RestartRun, started: number, again: () => void): Promise<void> {
  const s = d.state
  if (s.restart !== run || run.phase !== 'sent' || s.ending) return
  const p = await d.paths()
  const t = p ? await d.read(`${p.watch}/${run.sid}/restart-respawn.json`) : undefined
  const res = t !== undefined ? jsonOf(t) : undefined
  const late = (await d.now()) - started >= RESPAWN_WATCH_MS
  if (s.restart !== run || run.phase !== 'sent' || s.ending) return
  if (res && res.nonce === run.nonce && typeof res.rc === 'number' && res.rc !== 0) {
    return fail(d, run, 'refresh_failed', 'respawn-refused', { state: 'failed', code: typeof res.code === 'string' ? res.code : 'other' })
  }
  if (late) {
    await cancelRespawn(d, run, 'failed')
    return fail(d, run, 'refresh_failed', 'not-respawned', { state: 'failed' })
  }
  again()
}

/**
 * A main turn starts or a prompt enters while a restart is under way (§2.2 step 4, §3.4): the
 * person or a task took over. The in-flight respawn is cancelled before anything else (one helper
 * call: the carry note `cancelled`, then the kill), then the notes; no continue follows (the turn
 * is the session's next step). A respawn call still in flight is cancelled once more when it
 * returns (graceEnd).
 */
export async function restartInterrupt(d: Deps): Promise<void> {
  const s = d.state
  const run = s.restart
  if (!run || run.phase === 'done' || s.ending) return
  s.restart = undefined
  run.timer?.cancel()
  const was = run.phase
  run.phase = 'done'
  if (was === 'sent') await cancelRespawn(d, run, 'cancelled')
  await setNotes(d, run, 'cancelled')
  // The row is what `status` shows as the last restart (`last: waiting, busy`): a store that
  // cannot be read or written while the tried counts are noted still gets it, else status keeps
  // saying `restarting` for a run that ended. The failure still reaches the caller.
  try {
    await noteOutcome(d, run.sid, run.to, 'busy')
  } finally {
    await log(d, run.sid, 'refresh_skipped', { why: 'busy', route: run.route, to: run.to })
  }
}

/**
 * The `command.run` hook (§3.4 step 5, G9, G10): observe only, the command always passes on.
 * Our own `/exit` never reaches it (RS-P1: the engine runs no hook of the plugin that raised
 * `$.command.run`), so there is no own veto; one that did arrive (a later engine) passes
 * untouched. Another origin's `/exit` while armed (the person, the bridge, another plugin)
 * cancels the restart: that exit relaunches nothing.
 */
export async function onCommandRun(d: Deps, e: { command: string; origin: { kind: string; name?: string } }): Promise<undefined> {
  const s = d.state
  const c = e.command
  if (c === 'permissions' || c === 'allowed-tools' || c === 'sandbox') s.restartBlocks.add('session-rules')
  else if (c === 'add-dir') s.restartBlocks.add('session-dirs')
  else if (c === 'remote-control') s.restartBlocks.add('remote')
  if (c !== 'exit' && c !== 'quit') return undefined
  if (isOwnOrigin(e.origin, d.name)) return undefined
  const run = s.restart
  if (run && run.route === 'fg' && run.phase !== 'done') {
    s.restart = undefined
    run.timer?.cancel()
    run.phase = 'done'
    await setNotes(d, run, 'cancelled')
    // As in `restartInterrupt`: the row is written even when noting the tried count fails, so
    // status's last restart reads this cancel, not the refresh_start before it. The failure
    // still reaches the caller.
    try {
      await noteOutcome(d, run.sid, run.to, 'busy')
    } finally {
      await log(d, run.sid, 'refresh_skipped', { why: 'busy', route: 'fg', to: run.to })
    }
  }
  return undefined
}

/**
 * `session.end`, its first awaited action (§3.4 step 6): our exit within the go window writes the
 * launch note `go` first (one helper call: the launch note, then the carry note); any other end
 * cancels both. `ending` is set before any await, so the exit watchdog stands down.
 */
export async function restartOnEnd(d: Deps, reason: string | undefined): Promise<void> {
  const s = d.state
  s.ending = true
  try {
    await endRun(d, reason)
  } finally {
    // A `/clear` or a `/resume` goes on in this process under another session id.
    if (reason === 'clear' || reason === 'resume') s.ending = false
  }
}

async function endRun(d: Deps, reason: string | undefined): Promise<void> {
  const s = d.state
  const run = s.restart
  if (!run || run.phase === 'done') return
  run.timer?.cancel()
  const now = await d.now()
  if (run.route === 'bg') {
    // `other` is the respawn's kill: the new process confirms. Any other end leaves the note to
    // the after-kill scan (§2.3).
    run.phase = 'done'
    s.restart = undefined
    return
  }
  const go = run.phase === 'exiting' && reason === 'prompt_input_exit' && run.exitingAt !== undefined && now - run.exitingAt <= EXIT_WINDOW_MS
  run.phase = 'done'
  s.restart = undefined
  if (!go) {
    await setNotes(d, run, 'cancelled', { timeoutMs: 1000, now }).catch(() => undefined)
    return
  }
  // The note's `at` is this `now`, the one the go window was checked with, so the launcher's
  // window check (`at - floor(exiting_at / 1000)` 0 to 5) holds whenever ours did.
  const r = await setNotes(d, run, 'go', { extra: ['--exiting-at', String(Math.round(run.exitingAt ?? now))], timeoutMs: 1000, now })
    .catch((): SetReply => ({ ok: false, l: 'failed', c: 'failed' }))
  // The helper did not write the launch note (the call failed, or the note is gone, another
  // nonce's or already cancelled): no relaunch follows; one row says why. The mod never writes
  // the note itself: `$.fs` has no rename, and the contract's tmp-then-rename rule (§6) holds for
  // every write of it, so the launcher never reads a note cut short.
  if (!r.ok || r.l !== 'written') await log(d, run.sid, 'refresh_failed', { route: 'fg', why: 'helper-failed', to: run.to, code: `launch-${r.l}` })
}

/** `session.attach` / `session.detach` (G3b). */
export function onAttach(d: Deps, delta: 1 | -1): void {
  d.state.attached = Math.max(0, d.state.attached + delta)
}

/** `tool.call` of EnterWorktree / ExitWorktree in the main thread (G10 `worktree`). */
export function onWorktreeTool(d: Deps, tool: string): void {
  if (tool === 'EnterWorktree') d.state.restartBlocks.add('worktree')
  else if (tool === 'ExitWorktree') d.state.restartBlocks.delete('worktree')
}

/**
 * The new load (§5.2, §2.3): claims the carry note this session left, reports the version it came
 * back on, and submits the continue it carried 2 s later; reports the launcher's refusals for this
 * session and the background restarts that failed after the kill (ident). A moved session with no
 * note is a supervisor move (§2.1).
 */
export async function restartClaim(d: Deps, sid: string): Promise<void> {
  const s = d.state
  for (const r of s.ident?.restartReports ?? []) d.uiLog(lostText(d.name, r.short, r.to))
  if (s.ident) s.ident.restartReports = undefined
  const p = await d.paths()
  const env = await d.restartEnv()
  const hasNote = p !== undefined && (await d.exists(`${p.watch}/${sid}/restart.json`))
  if (!hasNote) {
    const m = s.versionMoved
    if (m && env.kind === 'bg') await log(d, sid, 'refresh_done', { route: 'supervisor', from: m.from, to: m.to, gap_s: null })
    if (env.launch === undefined) return
  }
  const now = await d.now()
  const args = ['restart', 'claim', '--sid', sid, '--load-id', s.loadId, '--now-ms', String(Math.round(now)),
    ...(env.launch !== undefined ? ['--launch', env.launch] : []), ...(env.kind === 'bg' ? ['--bg'] : [])]
  const r = await call(d, args)
  const j = r.ok ? jsonOf(r.stdout) : undefined
  if (!j) return
  const str = (v: unknown): string | null => (typeof v === 'string' ? v : null)
  for (const x of Array.isArray(j.refused) ? j.refused : []) {
    const reason = str((x as { reason?: unknown })?.reason) ?? 'other'
    await log(d, sid, 'refresh_failed', { route: 'fg', why: 'launcher-refused', to: null, code: reason })
  }
  const route = j.route === 'bg' ? 'bg' : 'fg'
  const from = str(j.from)
  const to = str(j.to)
  if (j.why === 'not-confirmed' && to !== null) {
    await noteOutcome(d, sid, to, 'not-confirmed')
    await log(d, sid, 'refresh_failed', { route, why: 'not-confirmed', to })
    return
  }
  if (j.claimed !== true || from === null || to === null) return
  let running: string | undefined
  try {
    running = (await d.version()).version
  } catch {
    running = undefined
  }
  const at = typeof j.at === 'number' && j.at > 0 ? j.at : undefined
  if (running === undefined || !VERSION_RE.test(running) || vcmp(running, to) < 0) {
    await noteOutcome(d, sid, to, 'same-version')
    await log(d, sid, 'refresh_failed', { route, why: 'same-version', to })
    return
  }
  await log(d, sid, 'refresh_done', { route, from, to, gap_s: at !== undefined ? Math.max(0, Math.round((now - at) / 1000)) : null })
  d.uiLog(doneText(d.name, from, to))
  if (j.continue !== true) return
  const turns = s.turnSeq
  d.after(CLAIM_CONTINUE_MS, () => {
    s.inflight = (async () => {
      // No prompt of a person (or any turn) in this load since; halt off; the cap free (submitContinue).
      if (s.turnSeq !== turns || s.mainTurnRunning || s.foreignPrompts > 0 || s.halt.active || isHuman(s.turnOrigin)) return
      if ((await d.sessionId()) !== sid) return
      await submitContinue(d, sid)
    })().catch(() => undefined)
  })
}
