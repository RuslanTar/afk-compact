// Keep-warm (decision D-14, 2026-10-30; setting `keep_warm_hours`, default 6, 0 = off). While the
// main session is idle and one of its own background jobs is still open (an agent, a workflow, a
// background shell), the plugin keeps the session's one-hour prompt cache warm with a hidden
// `$.model.fork` ping, so the turn the job's result opens reads the conversation from the cache
// instead of writing it again. At the cutoff it hands over to the idle path (idle.ts: the handoff
// turn or the plugin's idle compaction) while the cache is still warm: the decision model's policy
// "warm to H, then compact while warm" (D-79: the cutoff, deadline and limit-band stops with an
// agent, a workflow or a working teammate open compact from `idle_handoff_min_tokens` up, idle.ts
// `handOverIdle`; 14 days of real sessions; live probe PASS: a fork at +50 min read 228,161 cached
// tokens and wrote 9, and the wake at +70 min read the same 228,161 from cache;
// no Stop, UserPromptSubmit or turn event fired for the fork).
//
// One gap at a time, armed at every main turn end beside the idle timer (`armKeepWarm`):
// - The first ping is due 50 minutes after the start of the last cache-refreshing request (the last
//   main request, then each warm ping), always within 55; a ping that would start more than
//   58 minutes after it is not sent (the cache may have lapsed, and a late ping would write it all
//   again): warming ends for the gap (`missed`).
// - Warming starts, at the first ping or at an idle timer's fire, only for a main, non-headless
//   session, while a background job of this session is open, on the one-hour cache (Claude Code's
//   own TTL switch, else a five-hour or seven-day plan window reported: the idle path's reading,
//   so never the five-minute cache, whose break-even is under 2 h), and with no usage window it
//   can read stopping it (limits.ts, D-80; none reported: that guard is skipped). Plain user absence never warms
//   anything (IC-1 objection: "spend usage on every absence"). Nor a gap no idle path can take
//   over (`no-idle-path`): no idle record armed or held for the session (`idle_handoff_turn` and
//   `idle_compact` both off, or no kind at this context size), or `triggers` off (every idle path
//   refuses then); warming would run to the cutoff with nothing compacting after it. That reason,
//   unlike the others, logs one stop row for a gap that never warmed (`refuse`, once per gap).
// - While it warms, the idle timer's handoff turn (49 min), its compaction (54 min) and the
//   55.5-min check wait (one `handoff_skipped {why: keep-warm}` row; idle.ts `fire`); the record
//   comes back to the idle path when warming stops with the cache still warm (`handOverIdle`).
// - Each ping reads its usage: a cache read share of the cached prefix below 0.5 is a `fork-miss`:
//   the fork read only the prefix every session shares. It means the main cache is cold (v0.1.7
//   probes on 2.1.319, 46 of 356 pings: the next main request within 55 min of a fork-miss missed
//   too, 17 of 17, reading the same count, the API naming `previous_message_not_found`; model,
//   effort and the history's shape were the same as for warm pings): warming stops for the gap
//   (`fork-miss`) with no hand-over, the held record dropped, and the idle path skips a compaction
//   or turn on that cold cache (`fork-miss`, idle.ts `compactGuards`, `laterChecks`) until the
//   session's next main request; no gap of the session warms again until then either (a new turn
//   changes the history; `blocked` turns such a gap `off` with no row, so the one stop row is the
//   reason, logged once).
//   `nothing-to-fork` with no request of the main session out (the engine keeps no snapshot to
//   fork: a host that keeps none, a `/clear`) will not change at a retry: warming stops
//   (`nothing-to-fork`) with the hand-over. While a
//   request is out (`nothing-to-fork` then), an API error or an abort cost nothing more: the ping
//   is tried again a minute later, within the 58-minute bound and never past the held record's own
//   deadline (idle.ts `heldDeadline`: the turn's 55.5 min, the compaction's 58 from the last warm
//   request): a retry that would pass it stops first (`deadline`) with the hand-over. A fork that
//   comes back past that deadline (a slow one) hands nothing over: `missed`, the record dropped.
// - It stops when a main turn starts (`turn`), the session ends or changes, a compaction ran since
//   the gap began (`compacted`, Claude Code's own idle one included), no background job is open
//   (`no-jobs`), the cache is not the one-hour one any more (`ttl-5m`), the main model or Claude
//   Code version changed since the gap began (`prefix-changed`: `/model` sends no request, and a
//   ping on the new prefix would write it all again), a usage window's rule stops it (`near-limit`:
//   90%, or a plan window's band with a job open, limits.ts),
//   or the cutoff came (`cutoff`: `keep_warm_hours` of cache hours since the gap began; a gap past
//   it before its first ping never warms), or no idle path is left (`no-idle-path`). Those but `turn`, `session-end`, `session-changed`,
//   `compacted`, `fork-miss` (the main cache is cold), `missed` (past the 58-minute bound: a sleep,
//   or the session busy to the end; or a fork back past the held record's deadline) and
//   `held-elsewhere` (another load adopted the record) hand the deferred idle record back.
// - `keepWarmGen` counts what disturbs a gap (a turn or prompt, the session's end, a new gap, a
//   stop); the ping timer's own re-arm does not bump it. Every step that awaits takes it first and
//   returns where it changed, and a gap's stop row waits for its start row. A prompt a hook drops
//   re-arms the timer (`resumeKeepWarm`), or, while a tick runs, leaves the gap to that tick; the
//   idle timer it cancelled runs again too (idle.ts `resumeIdle`), so the record `no-idle-path`
//   reads in the store still has its fire, and the hand-over a taker.
// Rows: `keep_warm_start {jobs, gap_s, hours, windows, ping_s}` (`windows`: the usage windows read;
// 0 means the near-limit guard is skipped; `ping_s`: the ping interval, which the cache state's
// `next_due_at` follows), one `keep_warm_ping {n, result, cache_read, cache_creation,
// since_s, gap_s, ms, status?}` per ping, one `keep_warm_wait {n, gap_s, next_s, windows, rule}` per
// wait for a usage window's reset (D-80; `next_s`: the seconds to the ping then), one `keep_warm_stop {why, pings, gap_s, handover, windows?}`
// per gap that warmed or that `no-idle-path` refused before warming (`windows` on a `near-limit`
// stop: each window as `kind:percent`, idle.ts `limitWindows`). The ping state lives in this load;
// the idle record it holds stays in the store (idle.ts `holdIdle`), so a load that adopts it after
// a reload ends the warming (`reload`) and fires it at the next ping's due, while the cache is
// still warm.
import type { Deps, RequestUsage } from './deps'
import type { Due } from './idle'
import { compactedSince } from './compact'
import { prefixRead } from './deps'
import { IDLE_CACHE_MS, IDLE_TICK_MS, handOverIdle, heldDeadline, heldHere, holdIdle, idleArmed, isBusy, limitFields, oneHourCache, releaseHeld, scaleOf } from './idle'
import { agentIds, notifiedTasks } from './lane'
import type { LimitNote, UsageFields } from './limits'
import { judge, limitCtx, noteOf, readingsNow, tierFields } from './limits'
import { log } from './log'

/** The next ping, after the start of the last cache-refreshing request (a share of the cache hour, D10-scaled). */
export const KEEP_WARM_PING_MS = 50 * 60000
/**
 * No ping starts later than this after it: 58 min, the idle path's lapse bound (idle.ts
 * IDLE_LAPSE_FRACTION of the cache hour; a literal here, as idle.ts and this module import each other).
 */
export const KEEP_WARM_LATEST_MS = 58 * 60000
/** A ping that found a request in flight, an API error or an abort is tried again this much later. */
export const KEEP_WARM_RETRY_MS = 60000
/** A ping whose cache read share of the cached prefix is below this missed the main prefix (`fork-miss`). */
export const KEEP_WARM_COLD_SHARE = 0.5
/** The one user message of the fork: one word back, nothing read, every tool denied by the engine. */
export const KEEP_WARM_PROMPT = 'Reply with the single word OK.'
/**
 * Background task types not read from the Stop list: an agent or a teammate (counted live from the
 * agent list and its running loops, as lane.ts `NOT_UNIT`: the Stop list is only refreshed at the
 * next main Stop, so an agent that ended with no result turn yet would stay open there, and it
 * lists a teammate as `running` under a task id of its own while it waits idle, D-82), and the
 * kinds that only watch or wake (a Monitor, a cron).
 */
const NOT_JOB = /^(?:subagent|local_agent|teammate)$|monitor|cron/i
/** A teammate's Stop-list row: counted only when the agent list cannot be read (`openJobs`). */
const TEAMMATE = /^teammate$/i
/** A background task status that has ended. */
const ENDED = /^(?:completed|failed|killed|stopped|cancell?ed)$/i
/** A background shell: it may never end (a dev server, `tail -f`), so it opens no certain result turn (D-80). */
const SHELL = /^(?:shell|bash|local_bash)$/i

/**
 * One idle gap's keep-warm: `start` is the start of the gap (the last main request's start at the
 * turn end, or the turn end), `warm` the start of the last request that refreshed the cache
 * (`start`, then each warm ping), `next` when the next ping is due. `armed` until warming starts
 * (or `off` when it never may in this gap), `warming`, then `stopped`. `deferred` is the idle
 * timer's record this gap held back (idle.ts `fire`), handed back at a stop with a warm cache.
 */
export type KeepWarm = {
  sid: string
  start: number
  warm: number
  next: number
  phase: 'armed' | 'warming' | 'off' | 'stopped'
  pings: number
  deferred: Due | undefined
  /** The Claude Code version and main model at the gap's start (null: not read; that check is skipped). */
  cc: string | null
  model: string | null
  /** The `keep_warm_start` row's write while it runs: the gap's stop row waits for it. */
  startRow?: Promise<void>
  /** A tick of this gap is under way (its clock read, a ping): a dropped prompt arms no second timer beside it. */
  running?: boolean
  /** The `keepWarmGen` a prompt a hook dropped left while a tick ran: that tick goes on with the gap. */
  resumed?: number
  /**
   * The idle timer's record while its fire asks `keepWarmHolds` (a tombstone in the store by then):
   * a ping beside that fire still finds an idle path (`blocked`).
   */
  incoming?: Due
  /**
   * D-80 with D-79: the gap turned `off` before its first ping in the limit band with a job open
   * (`near-limit`, rule `band`): the idle record that fires next goes back once as a job's
   * hand-over (a warm compaction from `idle_handoff_min_tokens` up), as at a stop of a warming gap.
   */
  bandJob?: boolean
  /** D-83: the last check's limit note (a reading at the limit that did not stop the ping), for its row. */
  note?: LimitNote
}

/**
 * The background tasks of the main session's last Stop (`background_tasks`), by id; `shells` the
 * shells among them; `teams` its teammate rows not ended, which count only while the agent list
 * cannot be read.
 */
export type BgTasks = { sid: string; ids: string[]; shells: string[]; teams?: string[] }

/**
 * Main `classic.Stop` (observe only): the in-flight background work its input lists, less the
 * kinds that only watch (a Monitor, a cron) and any ended one. A subagent's Stop is not read.
 */
export function noteBackground(s: Deps['state'], e: { session_id?: unknown; agent_id?: unknown; background_tasks?: unknown }): void {
  if (e.agent_id !== undefined && e.agent_id !== null) return
  if (!Array.isArray(e.background_tasks) || typeof e.session_id !== 'string') return
  const ids: string[] = []
  const shells: string[] = []
  const teams: string[] = []
  for (const t of e.background_tasks as unknown[]) {
    if (typeof t !== 'object' || t === null) continue
    const o = t as Record<string, unknown>
    if (typeof o.id !== 'string' || o.id === '' || ENDED.test(String(o.status ?? ''))) continue
    if (TEAMMATE.test(String(o.type ?? ''))) teams.push(o.id)
    if (NOT_JOB.test(String(o.type ?? ''))) continue
    ids.push(o.id)
    if (SHELL.test(String(o.type ?? ''))) shells.push(o.id)
  }
  s.bgTasks = { sid: e.session_id, ids, shells, teams }
}

/**
 * A prompt of another's (`prompt.submit`): the tasks a background-task notification reports ended
 * (lane.ts `notifiedTasks`) no longer count as open, whatever the last Stop's list still says.
 */
export function noteEndedTasks(s: Deps['state'], kind: string, text: string): void {
  if (kind !== 'task-notification') return
  for (const id of notifiedTasks(text)) s.endedTasks.add(id)
}

/**
 * The background jobs of this session open now: agent loops running and listed agents at work
 * (counted live; D-82: an idle teammate is no job), the last main Stop's other tasks, less any a
 * notification reported ended. With no agent list to read, the Stop list's teammates count, as
 * before D-82 (it cannot tell an idle one from one at work).
 */
export async function openJobs(d: Deps, sid: string, shells = true): Promise<number> {
  const ids = await agentIds(d, sid)
  const bg = d.state.bgTasks
  if (bg?.sid === sid) for (const id of bg.ids) if (shells || !bg.shells.includes(id)) ids.add(id)
  for (const id of d.state.endedTasks) ids.delete(id)
  return ids.size
}

/**
 * D-80: a job whose result turn is certain is open: an agent, a workflow or a teammate at work (a
 * background shell alone may never end). A read that throws counts as none.
 */
export async function resultJobOpen(d: Deps, sid: string): Promise<boolean> {
  try {
    return (await openJobs(d, sid, false)) > 0
  } catch {
    return false
  }
}

/**
 * Cancels the ping timer and bumps `keepWarmGen` (synchronous: safe before any await in a hook):
 * a step of the gap awaiting meanwhile returns, and a tick reading the clock re-arms nothing.
 */
export function cancelKeepWarmTimer(d: Deps): void {
  clearTimer(d)
  d.state.keepWarmGen++
}

/** The ping timer only (its own re-arm): the gap is not disturbed, so `keepWarmGen` stays. */
function clearTimer(d: Deps): void {
  d.state.keepWarmTimer?.cancel()
  d.state.keepWarmTimer = undefined
}

/** A turn, a prompt entering, a plugin turn or a compaction under way: no fork beside it. */
function busyNow(s: Deps['state']): boolean {
  return isBusy(s) || s.nativeCompacting > 0 || s.ownCompact !== undefined
}

const secs = (ms: number): number => Math.round(ms / 1000)

/**
 * Main `turn.complete`, after the idle timer is armed: a new gap. Nothing with `keep_warm_hours`
 * 0, in a headless load, or after the last gap handed over to the idle path until a turn not of
 * the plugin's own starts (the handoff turn that hand-over may submit opens no new warming).
 */
export async function armKeepWarm(d: Deps, sid: string, endAt: number): Promise<void> {
  const s = d.state
  cancelKeepWarmTimer(d)
  s.keepWarm = undefined
  if (d.cfg.keep_warm_hours <= 0 || s.headless || s.keepWarmSpent) return
  const gen = s.keepWarmGen
  const start = s.lastMainReqAt !== undefined && s.lastMainReqAt <= endAt ? s.lastMainReqAt : endAt
  const scale = scaleOf(await d.idleEnv())
  const kw: KeepWarm = {
    sid, start, warm: start, next: start + KEEP_WARM_PING_MS * scale, phase: 'armed', pings: 0, deferred: undefined,
    cc: (await ccVersion(d)) ?? null, model: (await d.model()) ?? null,
  }
  const now = await d.now()
  // A turn or prompt that came during these reads: no gap to arm.
  if (s.keepWarmGen !== gen) return
  s.keepWarm = kw
  tick(d, kw, now)
}

async function ccVersion(d: Deps): Promise<string | undefined> {
  try {
    return (await d.version()).version
  } catch {
    return undefined
  }
}

/**
 * A prompt entering that did not start a turn (dropped by a hook, or its submit threw): the ping
 * timer `prompt.submit` cancelled is armed again for the gap as it stands, at once (its tick reads
 * the clock; nothing awaited here). A tick under way (a ping out) goes on with the gap instead, so
 * no second timer, and no second fork, runs beside it.
 */
export async function resumeKeepWarm(d: Deps): Promise<void> {
  const s = d.state
  const kw = s.keepWarm
  if (!kw || (kw.phase !== 'armed' && kw.phase !== 'warming')) return
  if (kw.running) {
    kw.resumed = s.keepWarmGen
    return
  }
  if (s.keepWarmTimer !== undefined) return
  arm(d, kw, 0)
}

/** Ticks of at most a minute to the due, each re-reading the wall clock (as idle.ts `schedule`). */
function tick(d: Deps, kw: KeepWarm, now: number): void {
  arm(d, kw, Math.max(0, Math.min(kw.next - now, IDLE_TICK_MS)))
}

function arm(d: Deps, kw: KeepWarm, ms: number): void {
  const s = d.state
  clearTimer(d)
  const gen = s.keepWarmGen
  s.keepWarmTimer = d.after(ms, () => {
    s.keepWarmTimer = undefined
    if (s.keepWarmGen !== gen || s.keepWarm !== kw) return
    void step(d, kw, gen).catch(() => undefined)
  })
}

/**
 * One tick: the clock, then the ping when it is due. While it runs (`running`) a prompt a hook
 * dropped leaves the gap to it (`resumed`): the ping goes on as if undisturbed when nothing else
 * came since (`due`), and the tick arms the next one at its end if nothing armed one.
 */
async function step(d: Deps, kw: KeepWarm, gen: number): Promise<void> {
  const s = d.state
  kw.running = true
  kw.resumed = undefined
  try {
    const t = await d.now()
    if (s.keepWarmGen !== gen || s.keepWarm !== kw) return
    if (t < kw.next) return tick(d, kw, t)
    await due(d, kw, t, gen)
  } finally {
    kw.running = false
  }
  if (kw.resumed !== undefined && kw.resumed === s.keepWarmGen && s.keepWarm === kw && s.keepWarmTimer === undefined && (kw.phase === 'armed' || kw.phase === 'warming')) {
    arm(d, kw, 0)
  }
}

/**
 * D-80: no stop, the next ping waits for the usage windows that stop it to reset (`wait`, at that
 * moment); the windows, the rule and their readings (D-83) go on its `keep_warm_wait` row.
 */
type Wait = { wait: number; windows: string[]; rule: string; usage: UsageFields }

/** A stop's reason, and what its row and its hand-over carry beside it (`stop`). */
type Block = { why: string; handover: boolean } & StopExtra

/**
 * Why this gap may not warm now, or undefined. `handover`: the cache is still warm, so a deferred
 * idle record goes back to the idle path; `windows` and `rule`: a `near-limit` stop's (idle.ts
 * `limitWindows`, limits.ts); `job`: a job whose result turn is certain is still open (an agent, a
 * workflow or a working teammate, not a background shell alone), so the hand-over compacts from
 * `idle_handoff_min_tokens` up (D-79). `wait` (D-80): no stop, the next ping waits for the usage
 * windows that stop it to reset, at that moment.
 */
async function blocked(d: Deps, kw: KeepWarm, now: number): Promise<Block | Wait | undefined> {
  const s = d.state
  const env = await d.idleEnv()
  const scale = scaleOf(env)
  if (d.cfg.keep_warm_hours <= 0 || s.headless) return { why: 'off', handover: true }
  if ((await d.sessionId()) !== kw.sid) return { why: 'session-changed', handover: false }
  if ((await compactedSince(d, kw.sid, kw.start)) !== undefined) return { why: 'compacted', handover: false }
  if (now - kw.warm > KEEP_WARM_LATEST_MS * scale) return { why: 'missed', handover: false }
  // The record this gap holds was adopted by another load (a reload while this one runs on): that load fires it.
  if (kw.deferred !== undefined && (await heldHere(d, kw.sid)) === undefined) return { why: 'held-elsewhere', handover: false }
  // A ping on this history missed the main prefix, and no main request came since: the main cache
  // is cold, so another would miss alike and nothing goes back to the idle path.
  if (forkMissed(s, kw.sid)) return { why: 'fork-miss', handover: false }
  if ((await openJobs(d, kw.sid)) === 0) return { why: 'no-jobs', handover: true }
  // G3a's reading (idle.ts compactGuards): another version or model since the gap began; a read that throws counts as changed.
  if ((kw.cc !== null && kw.cc !== (await ccVersion(d))) || (kw.model !== null && kw.model !== (await d.model()))) {
    return { why: 'prefix-changed', handover: true }
  }
  let u: Awaited<ReturnType<Deps['usage']>> | undefined
  try {
    u = await d.usage()
  } catch {
    u = undefined
  }
  if (!(await oneHourCache(d, env, u))) return { why: 'ttl-5m', handover: true }
  // D-80 (limits.ts): a window at 90% or more stops warming, the hand-over then compacting only in
  // the band (a job with a certain result open, a fresh reading, the measured compaction change
  // fits below the cap: `rule` band, with the job flag of D-79); no more pings in the band either.
  // When every such window resets before this gap's last ping moment (and the held record's
  // deadline), the ping waits for the reset instead of spending the last points. None reported: the
  // session's own entries in the usage record (D-88, limits.ts `readingsNow`); no reading at all:
  // this guard is skipped.
  const limits = u?.rateLimits ?? []
  let wait: Wait | undefined
  kw.note = undefined
  // D-83: every reading of the windows, the session's own and the shared record's (limits.ts `judge`).
  const rs = await readingsNow(d, kw.sid, limits)
  if (rs.length > 0) {
    const c = await limitCtx(d, await resultJobOpen(d, kw.sid), now)
    const v = judge(rs, c)
    kw.note = noteOf(v)
    if (!v.ok || v.band) {
      const reset = v.reset
      const bound = Math.min(kw.warm + KEEP_WARM_LATEST_MS * scale, kw.deferred !== undefined ? heldDeadline(kw.deferred, kw.warm, scale) : Infinity)
      if (reset !== undefined && reset + retryMs(scale) <= bound) wait = { wait: reset + retryMs(scale), windows: v.windows, rule: v.rule, usage: v.usage }
      else return { why: 'near-limit', handover: true, windows: v.windows, rule: v.rule, usage: v.usage, ...(v.band ? { job: true } : {}) }
    }
  }
  // D-79: the hand-over compacts from idle_handoff_min_tokens up only with a job whose result turn is
  // certain open (D-80 `resultJobOpen`): a background shell alone (a dev server) may never end.
  if (now - kw.start >= d.cfg.keep_warm_hours * IDLE_CACHE_MS * scale) {
    return { why: 'cutoff', handover: true, ...((await resultJobOpen(d, kw.sid)) ? { job: true } : {}) }
  }
  // No idle path would take the gap over after the pings: no idle record armed or held for the
  // session (`incoming`: the one the idle timer's fire is asking about, a tombstone in the store by
  // then; `deferred`: the one this gap holds), or `triggers` off, which every idle path refuses.
  // Pings then could run to the cutoff with no compaction or handoff turn behind them (and, native
  // idle on, may keep Claude Code's own from firing).
  if (!d.cfg.triggers || ((kw.incoming ?? kw.deferred) === undefined && !(await idleArmed(d, kw.sid)))) {
    return { why: 'no-idle-path', handover: true }
  }
  return wait
}

/**
 * An `armed` gap may not warm (no row: it never warmed); in the limit band with a job open (D-80)
 * the idle record that fires next goes back as a job's hand-over (`bandJob`, `holds`).
 */
function turnOff(kw: KeepWarm, b: Block): void {
  kw.phase = 'off'
  if (b.why === 'near-limit' && b.job === true) kw.bandJob = true
}

/**
 * The gap may not warm for want of an idle path (`no-idle-path`): it turns `off` with one
 * `keep_warm_stop {why: no-idle-path, pings: 0, handover: false}` row (no start row before it),
 * once per gap (only an `armed` gap comes here, and it is `off` before the row is written), unlike
 * the other reasons, which log nothing for a gap that never warmed.
 */
async function refuse(d: Deps, kw: KeepWarm, now: number): Promise<void> {
  kw.phase = 'off'
  await log(d, kw.sid, 'keep_warm_stop', { why: 'no-idle-path', pings: 0, gap_s: secs(now - kw.start), handover: false })
}

/**
 * Warming starts for this gap: one `keep_warm_start` row (`windows` 0: no usage window read, the
 * near-limit guard is skipped; `ping_s`: the ping interval, D10-scaled). True when nothing disturbed the gap meanwhile; false, with
 * nothing more to do, when a turn, a prompt or a stop came during its reads (the gap stays `armed`
 * with no row) or during its row's write (a stop then writes its row after this one). The first
 * ping and the idle timer's fire can begin the same gap at once: the one that finds it begun
 * already writes no second row, waits for that one's row and goes on as it does; one that finds
 * it `off` (the other's checks failed) writes nothing, and its caller, reading the phase, stops.
 */
async function begin(d: Deps, kw: KeepWarm, now: number): Promise<boolean> {
  const s = d.state
  const gen = s.keepWarmGen
  const moved = (): boolean => s.keepWarmGen !== gen || s.keepWarm !== kw
  let windows = 0
  try {
    windows = (await d.usage())?.rateLimits?.length ?? 0
  } catch {
    windows = 0
  }
  const pingS = secs(KEEP_WARM_PING_MS * scaleOf(await d.idleEnv()))
  if (moved()) return false
  const jobs = await openJobs(d, kw.sid)
  if (moved()) return false
  if (kw.phase === 'armed') {
    kw.phase = 'warming'
    kw.startRow = log(d, kw.sid, 'keep_warm_start', { jobs, gap_s: secs(now - kw.start), hours: d.cfg.keep_warm_hours, windows, ping_s: pingS })
  }
  // Begun here, or by the other caller meanwhile: after its start row, while undisturbed (a gap
  // found `off`, the other's checks failing, writes nothing: the callers go on only while it warms).
  await kw.startRow?.catch(() => undefined)
  return !moved()
}

/**
 * idle.ts `fire`, after G1 and G2: true when this gap warms, so the idle timer's turn, compaction
 * or check waits (its record is kept here for the hand-over). An `armed` gap decides here when the
 * idle timer comes before the first ping (the 49-min turn). A compaction since the gap began ends
 * warming, and the idle path reads it as it does today (`native-fired`, `compacted`).
 */
export async function keepWarmHolds(d: Deps, rec: Due, now: number): Promise<boolean> {
  const kw = d.state.keepWarm
  if (!kw || kw.sid !== rec.sid) return false
  // While this decides, the record is an idle path a ping beside it sees (`no-idle-path` reads it);
  // once it returns the record is held here (`deferred`) or the idle path runs it now.
  kw.incoming = rec
  try {
    return await holds(d, kw, rec, now)
  } finally {
    if (kw.incoming === rec) kw.incoming = undefined
  }
}

async function holds(d: Deps, kw: KeepWarm, rec: Due, now: number): Promise<boolean> {
  const s = d.state
  const gen = s.keepWarmGen
  // A turn or prompt that came during a check (or a stop): nothing is held, and the idle path reads the session as it is (busy).
  const moved = (): boolean => s.keepWarmGen !== gen || s.keepWarm !== kw
  if (kw.phase === 'armed') {
    const b0 = await blocked(d, kw, now)
    // Waiting for a reset (D-80) is no stop: the gap warms and holds the record meanwhile.
    const b = b0 !== undefined && 'wait' in b0 ? undefined : b0
    if (moved()) return false
    if (b !== undefined) {
      // The first ping may have begun warming meanwhile: its own next checks stop it, with its row.
      if (kw.phase === 'armed') {
        if (b.why === 'no-idle-path') await refuse(d, kw, now)
        else turnOff(kw, b)
      }
      if (kw.bandJob !== true) return false
    } else if (!(await begin(d, kw, now))) return false
    // Begun by the first ping meanwhile: held as well (begin waits for its start row).
  }
  // D-80: the band before the first ping (here or at that ping): one hand-over, with the job flag.
  if (kw.phase === 'off' && kw.bandJob === true) {
    kw.bandJob = false
    if (moved()) return false
    await handOverIdle(d, rec, kw.warm, now, true)
    return true
  }
  if (kw.phase !== 'warming') return false
  const c = await compactedSince(d, kw.sid, kw.start)
  if (moved()) return false
  if (c !== undefined) {
    await stop(d, kw, 'compacted', false, now)
    return false
  }
  kw.deferred = rec
  await holdIdle(d, rec, { due: kw.next, warm: kw.warm, start: kw.start, pings: kw.pings })
  return true
}

/**
 * A stop row's extra fields (`windows`, `rule`: a near-limit stop's, D-76, D-80; `usage`: its
 * windows' source and age, D-83) and a hand-over's job flag (D-79).
 */
type StopExtra = { windows?: string[]; rule?: string; usage?: UsageFields; job?: boolean }

/**
 * Warming ends for this gap: one `keep_warm_stop` row (only for a gap that warmed), and, with
 * `handover` and a deferred idle record, that record goes back to the idle path at once, anchored
 * at the last warm request (idle.ts `handOverIdle`; `job`: a job whose result turn is certain still open, D-79); the next gap then warms only after a turn
 * not of the plugin's own. With no hand-over the record it held is cleared, or with `keep`
 * (SessionEnd `other`) left in the store for the process that resumes the session.
 */
async function stop(d: Deps, kw: KeepWarm, why: string, handover: boolean, now: number, keep = false, x: StopExtra = {}): Promise<void> {
  const s = d.state
  if (s.keepWarm === kw) cancelKeepWarmTimer(d)
  const was = kw.phase
  kw.phase = 'stopped'
  if (was !== 'warming') return
  const rec = kw.deferred
  kw.deferred = undefined
  const back = handover && rec !== undefined
  // A stop that came while the start row is written (a turn starting then): its row comes after that one.
  if (kw.startRow) await kw.startRow.catch(() => undefined)
  await log(d, kw.sid, 'keep_warm_stop', {
    why, pings: kw.pings, gap_s: secs(now - kw.start), handover: back || (keep && rec !== undefined), ...(x.windows !== undefined ? { windows: x.windows } : {}),
    ...(x.rule !== undefined ? { rule: x.rule, ...(await tierFields(d)) } : {}), ...x.usage,
  })
  if (back && rec) {
    s.keepWarmSpent = true
    await handOverIdle(d, rec, kw.warm, now, x.job === true)
  } else if (rec) await releaseHeld(d, kw.sid, keep)
}

/**
 * A main turn starts (alive.ts `onTurnStart`) or the session ends (`session-end`): the gap's
 * warming stops with no hand-over (the idle timer is cancelled there too). A turn not of the
 * plugin's own lets the next gap warm again. `keep`: SessionEnd `other`, which keeps the idle
 * record for the next process (onSessionEnd), keeps the one this gap held too.
 */
export async function stopKeepWarm(d: Deps, why: 'turn' | 'session-end', ours = false, keep = false): Promise<void> {
  const s = d.state
  const kw = s.keepWarm
  cancelKeepWarmTimer(d)
  s.keepWarm = undefined
  if (why === 'session-end' || !ours) s.keepWarmSpent = false
  if (kw) await stop(d, kw, why, false, await d.now(), keep)
}

/** A ping's outcome from the fork's result (content-free: counts, a class, an HTTP status). */
type Outcome = { result: 'warm' | 'fork-miss' | 'nothing-to-fork' | 'api-error' | 'aborted' | 'error'; read: number | null; created: number | null; status?: number }

const count = (x: unknown): number | null => (typeof x === 'number' && Number.isFinite(x) && x >= 0 ? x : null)

export function forkOutcome(r: unknown): Outcome {
  if (typeof r !== 'object' || r === null) return { result: 'error', read: null, created: null }
  const o = r as { isAnswered?: unknown; reason?: unknown; usage?: unknown; status?: unknown }
  const u = (typeof o.usage === 'object' && o.usage !== null ? o.usage : undefined) as Partial<RequestUsage> | undefined
  const read = count(u?.cache_read_input_tokens)
  const created = count(u?.cache_creation_input_tokens)
  if (o.isAnswered !== true) {
    if (o.reason === 'nothing-to-fork') return { result: 'nothing-to-fork', read, created }
    if (o.reason === 'aborted') return { result: 'aborted', read, created }
    if (o.reason === 'api-error') return { result: 'api-error', read, created, ...(typeof o.status === 'number' ? { status: o.status } : {}) }
    if (o.reason !== 'empty-reply') return { result: 'error', read, created }
  }
  const share = prefixRead(u as RequestUsage | undefined)
  return { result: share !== null && share >= KEEP_WARM_COLD_SHARE ? 'warm' : 'fork-miss', read, created }
}

/**
 * A ping is due: the checks, then one fork, its row, and the next due or the stop. `ours`: still
 * this gap's tick, undisturbed, or disturbed only by prompts a hook dropped meanwhile (step).
 */
async function due(d: Deps, kw: KeepWarm, now: number, gen0: number): Promise<void> {
  const s = d.state
  let gen = gen0
  const ours = (): boolean => {
    if (s.keepWarm !== kw) return false
    if (s.keepWarmGen !== gen && kw.resumed === s.keepWarmGen) gen = s.keepWarmGen
    return s.keepWarmGen === gen
  }
  const b = await blocked(d, kw, now)
  const scale = scaleOf(await d.idleEnv())
  // A turn that started meanwhile ends the gap as `turn` (alive.ts): no stop row or hand-over here.
  if (!ours()) return
  // A turn, a prompt arriving, a plugin turn or compaction under way: no fork, and no stop that
  // hands the record back beside it (the idle path would skip it as busy); a minute later. A stop
  // without a hand-over (`missed` at the 58-minute bound, among others) still ends the gap.
  const busy = busyNow(s)
  if (busy && (b === undefined || 'wait' in b || b.handover)) return again(d, kw, now, scale)
  if (b !== undefined && 'wait' in b) {
    // D-80: the usage windows that stop the ping reset before its last moment: the gap warms (or
    // goes on warming) and the ping comes then, the held record due with it.
    if (kw.phase === 'armed' && !(await begin(d, kw, now))) return
    if (kw.phase !== 'warming' || !ours()) return
    kw.next = b.wait
    // 0.1.8: the row says when the next ping is due, so the cache state (`cache`, helper
    // lib/cachestate.pm) shows the reset wait, not 50 minutes after the last warm request.
    await log(d, kw.sid, 'keep_warm_wait', {
      n: kw.pings, gap_s: secs(now - kw.start), next_s: secs(kw.next - now), windows: b.windows, rule: b.rule, ...(await tierFields(d)), ...b.usage,
    })
    if (!ours()) return
    if (kw.deferred !== undefined && (await heldHere(d, kw.sid)) !== undefined && ours()) {
      await holdIdle(d, kw.deferred, { due: kw.next, warm: kw.warm, start: kw.start, pings: kw.pings })
    }
    if (ours()) tick(d, kw, now)
    return
  }
  if (kw.phase === 'armed') {
    if (b !== undefined) {
      if (b.why === 'no-idle-path') return refuse(d, kw, now)
      turnOff(kw, b)
      return
    }
    // False when the gap moved meanwhile: nothing more here.
    if (!(await begin(d, kw, now))) return
  } else if (b !== undefined) return stop(d, kw, b.why, b.handover, now, false, b)
  if (kw.phase !== 'warming') return
  // The main requests before the fork: one that comes while it runs already changed the history.
  const reqs = s.mainReqs
  let r: unknown
  try {
    r = await d.fork(KEEP_WARM_PROMPT)
  } catch {
    r = undefined
  }
  const t1 = await d.now()
  const o = forkOutcome(r)
  // Set even when the gap moved meanwhile (a prompt a hook then drops resumes this gap): its next check stops it.
  if (o.result === 'fork-miss') s.keepWarmForkMiss = { sid: kw.sid, reqs }
  const live = ours() && kw.phase === 'warming'
  const since = now - kw.warm
  // A warm ping into the gap undisturbed: the gap counts from it at once (a turn starting during
  // its row stops the gap with it counted).
  if (o.result === 'warm' && live) {
    kw.pings++
    kw.warm = now
    kw.next = now + KEEP_WARM_PING_MS * scale
  }
  await log(d, kw.sid, 'keep_warm_ping', {
    n: kw.pings, result: o.result, cache_read: o.read, cache_creation: o.created,
    since_s: secs(since), gap_s: secs(now - kw.start), ms: t1 - now, ...(o.status !== undefined ? { status: o.status } : {}),
    ...(await limitFields(d, kw.note)),
  })
  // Disturbed during the row (a prompt entering and still pending): no next step here, nor a retry
  // or a stop; the prompt's turn, or `resumeKeepWarm` once a hook drops it, takes the gap on.
  if (!live || !ours()) return
  if (o.result === 'warm') {
    // The held record follows: due at the next ping, anchored at this one (a reload fires it then).
    if (kw.deferred !== undefined && (await heldHere(d, kw.sid)) !== undefined && ours()) {
      await holdIdle(d, kw.deferred, { due: kw.next, warm: kw.warm, start: kw.start, pings: kw.pings })
    }
    if (!ours()) return
    tick(d, kw, t1)
    return
  }
  // A hand-over only while the held record can still fire on a warm cache: a fork that came back
  // past its deadline (a slow one) ends the gap `missed`, with the record dropped.
  const late = kw.deferred !== undefined && t1 > heldDeadline(kw.deferred, kw.warm, scale)
  const handOver = (why: string, job = false): Promise<void> => (late ? stop(d, kw, 'missed', false, t1) : stop(d, kw, why, true, t1, false, { job }))
  // No more pings in this gap: `fork-miss`, the main cache is cold (the fork read only the shared
  // prefix), so nothing goes back to the idle path, whose compaction or turn would read it cold too
  // (it skips `fork-miss` until the next main request, `forkMissed`); `error`, a fork the engine
  // refused (a hook's deny), with the hand-over.
  if (o.result === 'fork-miss') return stop(d, kw, 'fork-miss', false, t1)
  if (o.result === 'error') return handOver('error')
  if (!busyNow(s)) {
    // No request of the main session out: there is no snapshot to fork, and a retry finds none either.
    if (o.result === 'nothing-to-fork') return handOver('nothing-to-fork')
    // The held record goes back while it can still fire, rather than be dropped at `missed`; the
    // job flag (D-79) only with a job whose result turn is certain open, as at the cutoff.
    if (kw.deferred !== undefined && t1 + retryMs(scale) > heldDeadline(kw.deferred, kw.warm, scale)) {
      const job = await resultJobOpen(d, kw.sid)
      if (!ours()) return
      return handOver('deadline', job)
    }
  }
  return again(d, kw, t1, scale)
}

/**
 * A fork-miss of this session with no main request since (`mainReqs` unchanged from before that
 * fork): the main cache is cold until the next main request writes it again.
 */
export function forkMissed(s: Deps['state'], sid: string): boolean {
  const m = s.keepWarmForkMiss
  return m !== undefined && m.sid === sid && m.reqs === s.mainReqs
}

const retryMs = (scale: number): number => Math.max(1000, KEEP_WARM_RETRY_MS * scale)

/** Try the ping again a minute later (D10-scaled); past the 58-minute bound the next tick stops `missed`. */
function again(d: Deps, kw: KeepWarm, now: number, scale: number): void {
  kw.next = now + retryMs(scale)
  tick(d, kw, now)
}
