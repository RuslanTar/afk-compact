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
//   had lapsed: warming stops for the gap (`lapsed`), with no hand-over. `nothing-to-fork` (a main
//   request in flight), an API error or an abort cost nothing more: the ping is tried again a
//   minute later, within the 58-minute bound.
// - It stops when a main turn starts (`turn`), the session ends or changes, a compaction ran since
//   the gap began (`compacted`, Claude Code's own idle one included), no background job is open
//   (`no-jobs`), the cache is not the one-hour one any more (`ttl-5m`), a usage window reached 90%
//   (`near-limit`), or the cutoff came (`cutoff`: `keep_warm_hours` of cache hours since the gap
//   began). The last four hand the deferred idle record back with the cache warm.
// Rows: `keep_warm_start {jobs, gap_s, hours}`, one `keep_warm_ping {n, result, cache_read,
// cache_creation, since_s, gap_s, ms, status?}` per ping, one `keep_warm_stop {why, pings, gap_s,
// handover}` per gap that warmed. The state lives in this load only: a reload ends the gap's warming.
import type { Deps, RequestUsage } from './deps'
import type { Due } from './idle'
import { compactedSince } from './compact'
import { prefixRead } from './deps'
import { IDLE_CACHE_MS, IDLE_TICK_MS, NEAR_LIMIT_PCT, handOverIdle, isBusy, oneHourCache, scaleOf } from './idle'
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
/** Background task types that only watch or wake (a Monitor, a cron): not a job to keep warm for. */
const NOT_JOB = /monitor|cron/i
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

/** The background jobs of this session open now: agent loops running, listed agents not ended, the last Stop's tasks. */
export async function openJobs(d: Deps, sid: string): Promise<number> {
  const ids = new Set<string>(d.state.agentTurns)
  for (const id of (await d.agentsAlive()) ?? []) ids.add(id)
  if (d.state.bgTasks?.sid === sid) for (const id of d.state.bgTasks.ids) ids.add(id)
  return ids.size
}

/** Cancels the ping timer (synchronous: safe before any await in a hook); a tick reading the clock re-arms nothing. */
export function cancelKeepWarmTimer(d: Deps): void {
  d.state.keepWarmTimer?.cancel()
  d.state.keepWarmTimer = undefined
  d.state.keepWarmGen++
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
  const start = s.lastMainReqAt !== undefined && s.lastMainReqAt <= endAt ? s.lastMainReqAt : endAt
  const scale = scaleOf(await d.idleEnv())
  const kw: KeepWarm = { sid, start, warm: start, next: start + KEEP_WARM_PING_MS * scale, phase: 'armed', pings: 0, deferred: undefined }
  s.keepWarm = kw
  tick(d, kw, await d.now())
}

/** Ticks of at most a minute to the due, each re-reading the wall clock (as idle.ts `schedule`). */
function tick(d: Deps, kw: KeepWarm, now: number): void {
  const s = d.state
  cancelKeepWarmTimer(d)
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
 * idle record goes back to the idle path. `cutoff` only once warming has started.
 */
async function blocked(d: Deps, kw: KeepWarm, now: number): Promise<{ why: string; handover: boolean } | undefined> {
  const s = d.state
  const env = await d.idleEnv()
  const scale = scaleOf(env)
  if (d.cfg.keep_warm_hours <= 0 || s.headless) return { why: 'off', handover: true }
  if ((await d.sessionId()) !== kw.sid) return { why: 'session-changed', handover: false }
  if ((await compactedSince(d, kw.sid, kw.start)) !== undefined) return { why: 'compacted', handover: false }
  if (now - kw.warm > KEEP_WARM_LATEST_MS * scale) return { why: 'missed', handover: false }
  if ((await openJobs(d, kw.sid)) === 0) return { why: 'no-jobs', handover: true }
  let u: Awaited<ReturnType<Deps['usage']>> | undefined
  try {
    u = await d.usage()
  } catch {
    u = undefined
  }
  if (!(await oneHourCache(d, env, u))) return { why: 'ttl-5m', handover: true }
  // A window at the limit share or more; none reported (or no reading): this guard is skipped.
  if ((u?.rateLimits ?? []).some(l => !(l.percentUsed < NEAR_LIMIT_PCT))) return { why: 'near-limit', handover: true }
  if (kw.phase === 'warming' && now - kw.start >= d.cfg.keep_warm_hours * IDLE_CACHE_MS * scale) return { why: 'cutoff', handover: true }
  return undefined
}

/** Warming starts for this gap: one `keep_warm_start` row. */
async function begin(d: Deps, kw: KeepWarm, now: number): Promise<void> {
  kw.phase = 'warming'
  await log(d, kw.sid, 'keep_warm_start', { jobs: await openJobs(d, kw.sid), gap_s: secs(now - kw.start), hours: d.cfg.keep_warm_hours })
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
  if (kw.phase === 'armed') {
    if ((await blocked(d, kw, now)) !== undefined) {
      kw.phase = 'off'
      return false
    }
    await begin(d, kw, now)
  }
  if (kw.phase !== 'warming') return false
  if ((await compactedSince(d, kw.sid, kw.start)) !== undefined) {
    await stop(d, kw, 'compacted', false, now)
    return false
  }
  kw.deferred = rec
  return true
}

/**
 * Warming ends for this gap: one `keep_warm_stop` row (only for a gap that warmed), and, with
 * `handover` and a deferred idle record, that record goes back to the idle path at once, anchored
 * at the last warm request (idle.ts `handOverIdle`); the next gap then warms only after a turn
 * not of the plugin's own.
 */
async function stop(d: Deps, kw: KeepWarm, why: string, handover: boolean, now: number): Promise<void> {
  const s = d.state
  if (s.keepWarm === kw) cancelKeepWarmTimer(d)
  const was = kw.phase
  kw.phase = 'stopped'
  if (was !== 'warming') return
  const rec = kw.deferred
  kw.deferred = undefined
  const back = handover && rec !== undefined
  await log(d, kw.sid, 'keep_warm_stop', { why, pings: kw.pings, gap_s: secs(now - kw.start), handover: back })
  if (back && rec) {
    s.keepWarmSpent = true
    await handOverIdle(d, rec, kw.warm, now)
  }
}

/**
 * A main turn starts (alive.ts `onTurnStart`) or the session ends (`session-end`): the gap's
 * warming stops with no hand-over (the idle timer is cancelled there too). A turn not of the
 * plugin's own lets the next gap warm again.
 */
export async function stopKeepWarm(d: Deps, why: 'turn' | 'session-end', ours = false): Promise<void> {
  const s = d.state
  const kw = s.keepWarm
  cancelKeepWarmTimer(d)
  s.keepWarm = undefined
  if (why === 'session-end' || !ours) s.keepWarmSpent = false
  if (kw) await stop(d, kw, why, false, await d.now())
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
  if (kw.phase === 'armed') {
    if (b !== undefined) {
      kw.phase = 'off'
      return
    }
    await begin(d, kw, now)
  } else if (b !== undefined) return stop(d, kw, b.why, b.handover, now)
  if (kw.phase !== 'warming' || s.keepWarmGen !== gen) return
  const scale = scaleOf(await d.idleEnv())
  // A turn, a prompt arriving, a plugin turn or compaction under way: no fork beside it; a minute later.
  if (isBusy(s) || s.nativeCompacting > 0 || s.ownCompact !== undefined) return again(d, kw, now, scale)
  if (s.keepWarmGen !== gen) return
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
  if (!live) return
  if (o.result === 'warm') {
    kw.warm = now
    kw.next = now + KEEP_WARM_PING_MS * scale
    tick(d, kw, t1)
    return
  }
  if (o.result === 'lapsed') return stop(d, kw, 'lapsed', false, t1)
  // A fork the engine refused (a hook's deny): no more pings in this gap; the cache is as warm as the last ping left it.
  if (o.result === 'error') return stop(d, kw, 'error', true, t1)
  return again(d, kw, t1, scale)
}

/** Try the ping again a minute later (D10-scaled); past the 58-minute bound the next tick stops `missed`. */
function again(d: Deps, kw: KeepWarm, now: number, scale: number): void {
  kw.next = now + Math.max(1000, KEEP_WARM_RETRY_MS * scale)
  tick(d, kw, now)
}
