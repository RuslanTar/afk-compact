// Keep-warm (decision D-14, 2026-10-30; setting `keep_warm_hours`, default 6, 0 = off). While the
// main session is idle and one of its own background jobs is still open (an agent, a workflow, a
// background shell), the plugin keeps the session's one-hour prompt cache warm with a hidden
// `$.model.fork` ping, so the turn the job's result opens reads the conversation from the cache
// instead of writing it again. At the cutoff it hands over to the idle path (idle.ts: the handoff
// turn or the plugin's idle compaction) while the cache is still warm: the decision model's policy
// "warm to H, then compact while warm" (14 days of real sessions; live probe PASS: a fork at +50 min
// read 228,161 cached tokens and wrote 9, and the wake at +70 min read the same 228,161 from cache;
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
//   so never the five-minute cache, whose break-even is under 2 h), and below 90% of every usage
//   window it can read (none reported: that guard is skipped). Plain user absence never warms
//   anything (IC-1 objection: "spend usage on every absence").
// - While it warms, the idle timer's handoff turn (49 min), its compaction (54 min) and the
//   55.5-min check wait (one `handoff_skipped {why: keep-warm}` row; idle.ts `fire`); the record
//   comes back to the idle path when warming stops with the cache still warm (`handOverIdle`).
// - Each ping reads its usage: a cache read share of the cached prefix below 0.5 means the cache
//   had lapsed: warming stops for the gap (`lapsed`). That ping wrote the cache again, so the rule
//   is the same at the first ping and later ones: the idle record goes on by the idle path's own
//   checks (a record held by then is handed back, anchored at the last warm request; at the first
//   ping none is held yet and the idle timer fires as armed). `nothing-to-fork` with no request of
//   the main session out (the engine keeps no snapshot to fork: a host that keeps none, a `/clear`)
//   will not change at a retry: warming stops (`nothing-to-fork`) with the hand-over. While a
//   request is out (`nothing-to-fork` then), an API error or an abort cost nothing more: the ping
//   is tried again a minute later, within the 58-minute bound and never past the held record's own
//   deadline (idle.ts `heldDeadline`: the turn's 55.5 min, the compaction's 58 from the last warm
//   request): a retry that would pass it stops first (`deadline`) with the hand-over.
// - It stops when a main turn starts (`turn`), the session ends or changes, a compaction ran since
//   the gap began (`compacted`, Claude Code's own idle one included), no background job is open
//   (`no-jobs`), the cache is not the one-hour one any more (`ttl-5m`), the main model or Claude
//   Code version changed since the gap began (`prefix-changed`: `/model` sends no request, and a
//   ping on the new prefix would write it all again), a usage window reached 90% (`near-limit`),
//   or the cutoff came (`cutoff`: `keep_warm_hours` of cache hours since the gap began; a gap past
//   it before its first ping never warms). Those but `turn`, `session-end`, `session-changed`,
//   `compacted`, `missed` (past the 58-minute bound: a sleep, or the session busy to the end) and
//   `held-elsewhere` (another load adopted the record) hand the deferred idle record back.
// - `keepWarmGen` counts what disturbs a gap (a turn or prompt, the session's end, a new gap, a
//   stop); the ping timer's own re-arm does not bump it. Every step that awaits takes it first and
//   returns where it changed, and a gap's stop row waits for its start row.
// Rows: `keep_warm_start {jobs, gap_s, hours, windows}` (`windows`: the usage windows read; 0 means
// the near-limit guard is skipped), one `keep_warm_ping {n, result, cache_read, cache_creation,
// since_s, gap_s, ms, status?}` per ping, one `keep_warm_stop {why, pings, gap_s, handover}` per gap
// that warmed. The ping state lives in this load; the idle record it holds stays in the store
// (idle.ts `holdIdle`), so a load that adopts it after a reload ends the warming (`reload`) and
// fires it at the next ping's due, while the cache is still warm.
import type { Deps, RequestUsage } from './deps'
import type { Due } from './idle'
import { compactedSince } from './compact'
import { prefixRead } from './deps'
import { IDLE_CACHE_MS, IDLE_TICK_MS, NEAR_LIMIT_PCT, handOverIdle, heldDeadline, heldHere, holdIdle, isBusy, oneHourCache, releaseHeld, scaleOf } from './idle'
import { notifiedTasks } from './lane'
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
/** A ping whose cache read share of the cached prefix is below this found the cache lapsed. */
export const KEEP_WARM_COLD_SHARE = 0.5
/** The one user message of the fork: one word back, nothing read, every tool denied by the engine. */
export const KEEP_WARM_PROMPT = 'Reply with the single word OK.'
/**
 * Background task types not read from the Stop list: an agent (counted live from the agent list
 * and its running loops, as lane.ts `NOT_UNIT`: the Stop list is only refreshed at the next main
 * Stop, so an agent that ended with no result turn yet would stay open there), and the kinds that
 * only watch or wake (a Monitor, a cron).
 */
const NOT_JOB = /^(?:subagent|local_agent)$|monitor|cron/i
/** A background task status that has ended. */
const ENDED = /^(?:completed|failed|killed|stopped|cancell?ed)$/i

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
}

/** The background tasks of the main session's last Stop (`background_tasks`), by id. */
export type BgTasks = { sid: string; ids: string[] }

/**
 * Main `classic.Stop` (observe only): the in-flight background work its input lists, less the
 * kinds that only watch (a Monitor, a cron) and any ended one. A subagent's Stop is not read.
 */
export function noteBackground(s: Deps['state'], e: { session_id?: unknown; agent_id?: unknown; background_tasks?: unknown }): void {
  if (e.agent_id !== undefined && e.agent_id !== null) return
  if (!Array.isArray(e.background_tasks) || typeof e.session_id !== 'string') return
  const ids: string[] = []
  for (const t of e.background_tasks as unknown[]) {
    if (typeof t !== 'object' || t === null) continue
    const o = t as Record<string, unknown>
    if (typeof o.id !== 'string' || o.id === '') continue
    if (NOT_JOB.test(String(o.type ?? '')) || ENDED.test(String(o.status ?? ''))) continue
    ids.push(o.id)
  }
  s.bgTasks = { sid: e.session_id, ids }
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
 * The background jobs of this session open now: agent loops running and listed agents not ended
 * (counted live), the last main Stop's other tasks, less any a notification reported ended.
 */
export async function openJobs(d: Deps, sid: string): Promise<number> {
  const ids = new Set<string>(d.state.agentTurns)
  for (const id of (await d.agentsAlive()) ?? []) ids.add(id)
  if (d.state.bgTasks?.sid === sid) for (const id of d.state.bgTasks.ids) ids.add(id)
  for (const id of d.state.endedTasks) ids.delete(id)
  return ids.size
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
 * timer `prompt.submit` cancelled is armed again for the gap as it stands.
 */
export async function resumeKeepWarm(d: Deps): Promise<void> {
  const s = d.state
  const kw = s.keepWarm
  if (!kw || s.keepWarmTimer !== undefined || (kw.phase !== 'armed' && kw.phase !== 'warming')) return
  const gen = s.keepWarmGen
  const now = await d.now()
  if (s.keepWarmGen !== gen || s.keepWarm !== kw || s.keepWarmTimer !== undefined) return
  tick(d, kw, now)
}

/** Ticks of at most a minute to the due, each re-reading the wall clock (as idle.ts `schedule`). */
function tick(d: Deps, kw: KeepWarm, now: number): void {
  const s = d.state
  clearTimer(d)
  const gen = s.keepWarmGen
  s.keepWarmTimer = d.after(Math.max(0, Math.min(kw.next - now, IDLE_TICK_MS)), () => {
    s.keepWarmTimer = undefined
    void (async () => {
      const t = await d.now()
      if (s.keepWarmGen !== gen || s.keepWarm !== kw) return
      if (t < kw.next) return tick(d, kw, t)
      await due(d, kw, t, gen)
    })().catch(() => undefined)
  })
}

/**
 * Why this gap may not warm now, or undefined. `handover`: the cache is still warm, so a deferred
 * idle record goes back to the idle path.
 */
async function blocked(d: Deps, kw: KeepWarm, now: number): Promise<{ why: string; handover: boolean } | undefined> {
  const s = d.state
  const env = await d.idleEnv()
  const scale = scaleOf(env)
  if (d.cfg.keep_warm_hours <= 0 || s.headless) return { why: 'off', handover: true }
  if ((await d.sessionId()) !== kw.sid) return { why: 'session-changed', handover: false }
  if ((await compactedSince(d, kw.sid, kw.start)) !== undefined) return { why: 'compacted', handover: false }
  if (now - kw.warm > KEEP_WARM_LATEST_MS * scale) return { why: 'missed', handover: false }
  // The record this gap holds was adopted by another load (a reload while this one runs on): that load fires it.
  if (kw.deferred !== undefined && (await heldHere(d, kw.sid)) === undefined) return { why: 'held-elsewhere', handover: false }
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
  // A window at the limit share or more; none reported (or no reading): this guard is skipped.
  if ((u?.rateLimits ?? []).some(l => !(l.percentUsed < NEAR_LIMIT_PCT))) return { why: 'near-limit', handover: true }
  if (now - kw.start >= d.cfg.keep_warm_hours * IDLE_CACHE_MS * scale) return { why: 'cutoff', handover: true }
  return undefined
}

/**
 * Warming starts for this gap: one `keep_warm_start` row (`windows` 0: no usage window read, the
 * near-limit guard is skipped). True when the gap still warms undisturbed after it; false, with
 * nothing more to do, when a turn, a prompt or a stop came during its reads (the gap stays `armed`
 * with no row) or during its row's write (a stop then writes its row after this one).
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
  if (moved()) return false
  const jobs = await openJobs(d, kw.sid)
  if (moved() || kw.phase !== 'armed') return false
  kw.phase = 'warming'
  const row = log(d, kw.sid, 'keep_warm_start', { jobs, gap_s: secs(now - kw.start), hours: d.cfg.keep_warm_hours, windows })
  kw.startRow = row
  await row
  return !moved() && kw.phase === 'warming'
}

/**
 * idle.ts `fire`, after G1 and G2: true when this gap warms, so the idle timer's turn, compaction
 * or check waits (its record is kept here for the hand-over). An `armed` gap decides here when the
 * idle timer comes before the first ping (the 49-min turn). A compaction since the gap began ends
 * warming, and the idle path reads it as it does today (`native-fired`, `compacted`).
 */
export async function keepWarmHolds(d: Deps, rec: Due, now: number): Promise<boolean> {
  const s = d.state
  const gen = s.keepWarmGen
  const kw = s.keepWarm
  if (!kw || kw.sid !== rec.sid) return false
  // A turn or prompt that came during a check (or a stop): nothing is held, and the idle path reads the session as it is (busy).
  const moved = (): boolean => s.keepWarmGen !== gen || s.keepWarm !== kw
  if (kw.phase === 'armed') {
    const b = await blocked(d, kw, now)
    if (moved()) return false
    if (b !== undefined) {
      kw.phase = 'off'
      return false
    }
    if (!(await begin(d, kw, now))) return false
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
 * Warming ends for this gap: one `keep_warm_stop` row (only for a gap that warmed), and, with
 * `handover` and a deferred idle record, that record goes back to the idle path at once, anchored
 * at the last warm request (idle.ts `handOverIdle`); the next gap then warms only after a turn
 * not of the plugin's own. With no hand-over the record it held is cleared, or with `keep`
 * (SessionEnd `other`) left in the store for the process that resumes the session.
 */
async function stop(d: Deps, kw: KeepWarm, why: string, handover: boolean, now: number, keep = false): Promise<void> {
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
  await log(d, kw.sid, 'keep_warm_stop', { why, pings: kw.pings, gap_s: secs(now - kw.start), handover: back || (keep && rec !== undefined) })
  if (back && rec) {
    s.keepWarmSpent = true
    await handOverIdle(d, rec, kw.warm, now)
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
type Outcome = { result: 'warm' | 'lapsed' | 'nothing-to-fork' | 'api-error' | 'aborted' | 'error'; read: number | null; created: number | null; status?: number }

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
  return { result: share !== null && share >= KEEP_WARM_COLD_SHARE ? 'warm' : 'lapsed', read, created }
}

/** A ping is due: the checks, then one fork, its row, and the next due or the stop. */
async function due(d: Deps, kw: KeepWarm, now: number, gen: number): Promise<void> {
  const s = d.state
  const b = await blocked(d, kw, now)
  const scale = scaleOf(await d.idleEnv())
  // A turn that started meanwhile ends the gap as `turn` (alive.ts): no stop row or hand-over here.
  if (s.keepWarmGen !== gen || s.keepWarm !== kw) return
  // A turn, a prompt arriving, a plugin turn or compaction under way: no fork, and no stop that
  // hands the record back beside it (the idle path would skip it as busy); a minute later. A stop
  // without a hand-over (`missed` at the 58-minute bound, among others) still ends the gap.
  const busy = busyNow(s)
  if (busy && (b === undefined || b.handover)) return again(d, kw, now, scale)
  if (kw.phase === 'armed') {
    if (b !== undefined) {
      kw.phase = 'off'
      return
    }
    if (!(await begin(d, kw, now))) return
  } else if (b !== undefined) return stop(d, kw, b.why, b.handover, now)
  if (kw.phase !== 'warming' || s.keepWarmGen !== gen) return
  let r: unknown
  try {
    r = await d.fork(KEEP_WARM_PROMPT)
  } catch {
    r = undefined
  }
  const t1 = await d.now()
  const o = forkOutcome(r)
  const live = s.keepWarmGen === gen && s.keepWarm === kw && kw.phase === 'warming'
  if (o.result === 'warm' && live) kw.pings++
  await log(d, kw.sid, 'keep_warm_ping', {
    n: kw.pings, result: o.result, cache_read: o.read, cache_creation: o.created,
    since_s: secs(now - kw.warm), gap_s: secs(now - kw.start), ms: t1 - now, ...(o.status !== undefined ? { status: o.status } : {}),
  })
  if (!live || s.keepWarmGen !== gen || s.keepWarm !== kw) return
  if (o.result === 'warm') {
    kw.warm = now
    kw.next = now + KEEP_WARM_PING_MS * scale
    // The held record follows: due at the next ping, anchored at this one (a reload fires it then).
    if (kw.deferred !== undefined && (await heldHere(d, kw.sid)) !== undefined && s.keepWarmGen === gen) {
      await holdIdle(d, kw.deferred, { due: kw.next, warm: kw.warm, start: kw.start, pings: kw.pings })
    }
    if (s.keepWarmGen !== gen) return
    tick(d, kw, t1)
    return
  }
  // No more pings in this gap, with the hand-over: `lapsed`, the ping wrote the cache again (the
  // idle path's own checks decide, as for a lapsed first ping that held nothing yet); `error`, a
  // fork the engine refused (a hook's deny), the cache as warm as the last ping left it.
  if (o.result === 'lapsed' || o.result === 'error') return stop(d, kw, o.result, true, t1)
  if (!busyNow(s)) {
    // No request of the main session out: there is no snapshot to fork, and a retry finds none either.
    if (o.result === 'nothing-to-fork') return stop(d, kw, 'nothing-to-fork', true, t1)
    // The held record goes back while it can still fire, rather than be dropped at `missed`.
    if (kw.deferred !== undefined && t1 + retryMs(scale) > heldDeadline(kw.deferred, kw.warm, scale)) return stop(d, kw, 'deadline', true, t1)
  }
  return again(d, kw, t1, scale)
}

const retryMs = (scale: number): number => Math.max(1000, KEEP_WARM_RETRY_MS * scale)

/** Try the ping again a minute later (D10-scaled); past the 58-minute bound the next tick stops `missed`. */
function again(d: Deps, kw: KeepWarm, now: number, scale: number): void {
  kw.next = now + retryMs(scale)
  tick(d, kw, now)
}
