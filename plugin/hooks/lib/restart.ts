// Restart on update (SESSION-RESTART): at a compaction boundary (D2: right after a plugin
// compaction at a turn end, before its continue; right after an idle compaction) a session that
// opted in (`restart_on_update: on`, settings file only, D1) and passes every gate of §4.1 moves
// onto a newly installed Claude Code and keeps its session id.
// - Background sessions (`claude --bg`): the helper starts `claude respawn <job>` detached, the
//   way `/restart` does (§2.2); the new process confirms (§2.3). A refusal before the kill, or a
//   worker still alive after 60 s, is a failure, and the normal continue runs.
// - Terminal sessions started through the plugin's launcher (§3): a transcript line, a 5 s grace,
//   then the plugin's own `/exit`; the launcher relaunches `--resume` only on the launch note's
//   `go` (the launcher's file contract, protocol 1). Shipped off until live probe RS-P1 passes:
//   the helper's gate answers `fg-not-shipped` (lib/restart.pm $FG_ROUTE).
// `shadow` runs every gate and writes one `refresh_would` row, nothing else. Every failure before
// the process ends runs the deferred continue once (§4.4). Rows are content-free (§6.3).
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
  cont: boolean
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
/** §3.4 step 6: `session.end` this soon after our `/exit` passed our hook is ours. */
export const EXIT_WINDOW_MS = 5000
/** §3.4 step 5: our `/exit` passes our hook only this soon after the arm. */
export const ARMED_FRESH_MS = 30000
// (The go window bounds it more tightly: our hook passes our /exit only within EXIT_WINDOW_MS of
// the `exiting` write that comes right before it.)
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

/** §3.5: the launcher's patterns for the note values the mod supplies. */
export const MODEL_RE = /^[A-Za-z0-9._:/[\]-]{1,100}$/
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
export function cancelText(name: string): string {
  return `${name}: restart cancelled; this session stays open.`
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
 */
async function liveWhy(d: Deps, sid: string, route: Route, moment: boolean): Promise<string | undefined> {
  const s = d.state
  if (s.headless) return 'headless'
  if (s.mainTurnRunning || s.foreignPrompts > 0 || s.handoffTurn !== undefined || s.ourSubmitPending || s.ownCompact !== undefined) return 'busy'
  if (!moment && (s.busy || s.nativeCompacting > 0)) return 'busy'
  if (!s.lastTurnAnswer) return 'aborted'
  if (s.askOpen > 0 || s.lastTurnAsksUser) return 'asks-user'
  if (s.halt.active) return 'halted'
  if ((await agentsRunning(d)) > 0) return 'agents'
  const draft = await d.promptDraft()
  if (draft === undefined || draft.trim() !== '') return 'draft'
  if (s.lastInputAt !== undefined && (await d.now()) - s.lastInputAt < RESTART_PRESENT_MS) return 'present'
  const surf = await d.surfaces()
  const others = surf === undefined || surf.some(x => x !== 'terminal')
  if (route === 'bg' && (others || s.attached > 0)) return 'attached'
  if (others || s.restartBlocks.has('remote')) return 'remote'
  for (const b of ['session-rules', 'session-dirs', 'worktree']) if (s.restartBlocks.has(b)) return b
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

type Gate = { ok: boolean; why: string | null; route: Route; mode: string | null; effort: string | null; job_short: string | null; token: string | null; types: string[] }

function parseGate(out: string): Gate | undefined {
  try {
    const j = JSON.parse(out.trim()) as Record<string, unknown>
    const str = (v: unknown): string | null => (typeof v === 'string' ? v : null)
    return {
      ok: j.ok === true, why: str(j.why), route: j.route === 'bg' ? 'bg' : 'fg', mode: str(j.mode), effort: str(j.effort),
      job_short: str(j.job_short), token: str(j.token), types: Array.isArray(j.types) ? j.types.filter((x): x is string => typeof x === 'string') : [],
    }
  } catch {
    return undefined
  }
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
 * The restart moment (D2): called right after a plugin compaction's after-step, before its continue
 * (`cont` true when a continue may follow), or after an idle compaction (`cont` false); `since` is
 * when that compaction started (D10: its PostCompact gives the fresh mode). True when a restart was
 * armed: it now owns the continue (run once on any failure before the process ends); false when
 * the normal path goes on.
 */
export async function restartMoment(d: Deps, sid: string, o: { cont: boolean; since: number }): Promise<boolean> {
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
  let why = await liveWhy(d, sid, route, true)
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
  const g = await call(d, ['restart', 'gate', '--sid', sid, '--route', route, ...rt.flags, '--from', from, '--to', to, '--model', model,
    '--since', String(Math.round(o.since)), '--now-ms', String(Math.round(now))], GATE_MS)
  const gate = g.ok ? parseGate(g.stdout) : undefined
  if (!gate || !gate.ok) {
    const w = gate?.why ?? 'helper-failed'
    await once(d, sid, 'refresh_skipped', `${w}|${to}`, { why: w, route, to, ...(gate && gate.types.length > 0 ? { types: gate.types } : {}) })
    return false
  }
  if (setting === 'shadow') {
    await once(d, sid, 'refresh_would', to, { route, from, to, continue: dec.go })
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
    sid, route, nonce, from, to, cont: dec.go, armedAt: now, phase: 'grace', mode, effort, model,
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

/** `restart set` for this run's notes (the launch note first); false when the call failed. */
async function setNotes(d: Deps, run: RestartRun, state: string, extra: string[] = [], timeoutMs?: number): Promise<boolean> {
  const now = await d.now()
  const args = ['restart', 'set', '--sid', run.sid, '--nonce', run.nonce, '--state', state, '--now-ms', String(Math.round(now)), ...extra,
    ...(run.route === 'fg' && run.launch !== undefined ? ['--launch', run.launch] : [])]
  const r = timeoutMs === undefined ? await call(d, args) : await call(d, args, timeoutMs)
  return r.ok
}

/** The run ends before the process does: notes, one row, the continue once (§4.4). */
async function fail(d: Deps, run: RestartRun, ev: 'refresh_skipped' | 'refresh_failed', why: string, opts: { state?: string; code?: string; cont?: boolean } = {}): Promise<void> {
  const s = d.state
  run.timer?.cancel()
  run.phase = 'done'
  if (s.restart === run) s.restart = undefined
  await setNotes(d, run, opts.state ?? 'cancelled').catch(() => false)
  await noteOutcome(d, run.sid, run.to, why)
  await log(d, run.sid, ev, { route: run.route, why, to: run.to, ...(opts.code !== undefined ? { code: opts.code } : {}) })
  if (opts.cont !== false) await autoContinue(d, run.sid)
}

/** §3.4 step 3, §2.2 step 2: after the grace, the live gates once more, then the exit or the respawn. */
async function graceEnd(d: Deps, run: RestartRun): Promise<void> {
  const s = d.state
  if (s.restart !== run || run.phase !== 'grace') return
  run.timer = undefined
  const why = await liveWhy(d, run.sid, run.route, false)
  if (why !== undefined) return fail(d, run, 'refresh_skipped', why)
  if (run.route === 'fg') {
    // §3.4 steps 4-5. Both notes become `exiting` (with `exiting_at`) right before our /exit is
    // queued, so the go window holds whether or not our own `command.run` hook sees our call
    // (F5 is INFERRED: probe RS-P1 run 3); when it does see it, it passes only this fresh one.
    const at = await d.now()
    if (!(await setNotes(d, run, 'exiting', ['--exiting-at', String(Math.round(at))]))) return fail(d, run, 'refresh_failed', 'helper-failed')
    if (s.restart !== run || run.phase !== 'grace') return
    run.phase = 'exiting'
    run.exitingAt = at
    // §3.4 step 7: still alive EXIT_WINDOW_MS later (an exit dialog, a detach, an /exit that never
    // ran): both notes cancelled first, then the continue.
    run.timer = d.after(EXIT_WINDOW_MS, () => {
      if (s.restart === run && run.phase === 'exiting' && !s.ending) s.inflight = fail(d, run, 'refresh_failed', 'exit-not-run').catch(() => undefined)
    })
    void d.commandRun('exit').then(
      () => undefined,
      () => {
        if (s.restart === run && run.phase === 'exiting' && !s.ending) s.inflight = fail(d, run, 'refresh_failed', 'exit-refused').catch(() => undefined)
      },
    )
    return
  }
  // The background route: the carry note `sent` and the detached respawn in one helper call.
  run.phase = 'sent'
  const r = await call(d, ['restart', 'respawn', '--sid', run.sid, '--short', run.short ?? '', '--nonce', run.nonce, '--to', run.to])
  const j = r.ok ? jsonOf(r.stdout) : undefined
  if (!j || j.ok !== true) {
    return fail(d, run, 'refresh_failed', 'respawn-refused', { state: 'failed', code: typeof j?.why === 'string' ? j.why : 'other' })
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
  if (res && res.nonce === run.nonce && typeof res.rc === 'number' && res.rc !== 0) {
    return fail(d, run, 'refresh_failed', 'respawn-refused', { state: 'failed', code: typeof res.code === 'string' ? res.code : 'other' })
  }
  if ((await d.now()) - started >= RESPAWN_WATCH_MS) {
    await call(d, ['restart', 'respawn-cancel', '--sid', run.sid, '--nonce', run.nonce])
    return fail(d, run, 'refresh_failed', 'not-respawned', { state: 'failed' })
  }
  again()
}

/**
 * A main turn starts or a prompt enters while a restart is under way (§2.2 step 4, §3.4): the
 * person or a task took over. The in-flight respawn is cancelled before anything else, then the
 * notes; no continue follows (the turn is the session's next step).
 */
export async function restartInterrupt(d: Deps): Promise<void> {
  const s = d.state
  const run = s.restart
  if (!run || run.phase === 'done' || s.ending) return
  s.restart = undefined
  run.timer?.cancel()
  const was = run.phase
  run.phase = 'done'
  if (was === 'sent') await call(d, ['restart', 'respawn-cancel', '--sid', run.sid, '--nonce', run.nonce])
  await setNotes(d, run, 'cancelled')
  await noteOutcome(d, run.sid, run.to, 'busy')
  await log(d, run.sid, 'refresh_skipped', { why: 'busy', route: run.route, to: run.to })
}

/**
 * The `command.run` hook (§3.4 step 5, G9, G10). `undefined`: pass the command on (`next(e)`);
 * `{ text }`: our own answer, no command runs (F5).
 */
export async function onCommandRun(d: Deps, e: { command: string; origin: { kind: string; name?: string } }): Promise<{ text: string } | undefined> {
  const s = d.state
  const c = e.command
  if (c === 'permissions' || c === 'allowed-tools' || c === 'sandbox') s.restartBlocks.add('session-rules')
  else if (c === 'add-dir') s.restartBlocks.add('session-dirs')
  else if (c === 'remote-control') s.restartBlocks.add('remote')
  if (c !== 'exit' && c !== 'quit') return undefined
  const run = s.restart
  const own = isOwnOrigin(e.origin, d.name)
  if (!own) {
    // Another origin's /exit while armed: the person exits as usual and nothing relaunches.
    if (run && run.route === 'fg' && run.phase !== 'done') {
      s.restart = undefined
      run.timer?.cancel()
      run.phase = 'done'
      await setNotes(d, run, 'cancelled')
      await noteOutcome(d, run.sid, run.to, 'busy')
    }
    return undefined
  }
  const now = await d.now()
  const fresh = run !== undefined && run.route === 'fg' && run.phase === 'exiting' && run.exitingAt !== undefined
    && now - run.exitingAt < EXIT_WINDOW_MS && now - run.armedAt < ARMED_FRESH_MS
    && !s.mainTurnRunning && s.foreignPrompts === 0 && (await d.sessionId()) === run.sid
  if (fresh) return undefined
  // A stale /exit of ours (cancelled, a second one, or one a turn came before): no command runs.
  if (run !== undefined && run.route === 'fg' && run.phase === 'exiting') {
    s.inflight = fail(d, run, 'refresh_skipped', 'stale-exit').catch(() => undefined)
  } else {
    await log(d, await d.sessionId(), 'refresh_skipped', { why: 'stale-exit', route: 'fg', to: run?.to ?? null })
  }
  return { text: cancelText(d.name) }
}

/** The launch note in the launcher's protocol 1 form (contract §4): the fallback write of `go`. */
export function launchNote(run: RestartRun, state: string, atMs: number): string {
  const v: Record<string, string> = {
    proto: '1', state, token: run.token ?? '', sid: run.sid, nonce: run.nonce, at: String(Math.floor(atMs / 1000)),
    exiting_at: run.exitingAt !== undefined ? String(Math.round(run.exitingAt)) : '', from: run.from, to: run.to,
    model: run.model, effort: run.effort, mode: run.mode,
  }
  return ['proto', 'state', 'token', 'sid', 'nonce', 'at', 'exiting_at', 'from', 'to', 'model', 'effort', 'mode'].map(k => `${k}=${v[k]}\n`).join('')
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
    await setNotes(d, run, 'cancelled', [], 1000).catch(() => false)
    return
  }
  const ok = await setNotes(d, run, 'go', ['--exiting-at', String(Math.round(run.exitingAt ?? now))], 1000).catch(() => false)
  if (!ok && run.launch !== undefined) await d.write(`${run.launch.replace(/\/+$/, '')}/restart.note`, launchNote(run, 'go', now))
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
