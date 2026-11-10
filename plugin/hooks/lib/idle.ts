// What the plugin does with an idle main session (MOD-SPEC §9.4, IC-1 D5; settings
// `idle_handoff_turn` and `idle_compact`, both default auto). At every main turn end the mod
// (re)arms one timer, of one kind, from how Claude Code's own idle compaction reads in the merged
// settings and its environment (deps.nativeIdle, IDLE-COMPACT-SPEC §1.1, §1.2):
// - `compact` (native `vetoed`: `"idleCompaction": false`, automatic compaction on; IDLE-COMPACT
//   D1, D2): the plugin compacts the session itself about 54 minutes after the last main-thread
//   request (0.9 of the one-hour prompt cache, native's own fraction), with a floor of the turn
//   end plus a minute (D3), at Claude Code's idle minimum or more (`CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS`,
//   200,000 by default). One shaped compaction through the same self-call as the plugin's other
//   compactions (boundary.ts), an idle dispatch record and resume block, no continue after it
//   (`idle_compact` row). It replaces the 49-min turn (D2): no turn runs before it or after a
//   failed attempt. Its guards (§2.1, `fireCompact`) mirror native's where the mod can see them.
//   Two failed attempts in a row turn it off for the load (D7).
// - `turn` (native `compaction-off`, or `vetoed` below the minimum, with `idle_compact: off`, or
//   after D7): the handoff turn 49 minutes after the turn end (the measured native idle time of
//   54 minutes less a 5-minute lead). With `compaction-off` the plugin never compacts against an
//   explicit switch.
// - `check` (native `on`, or `unknown`: O-9 "unreadable means check what happened"; owner
//   xxxxxxxx-17 "Check outcome at 55.5m"): an outcome check 55.5 minutes after the turn end.
//   Native fires 54:00 after the last request and the cache lasts to minute 60. When the plugin's
//   own records show a main compaction since that turn end it stands down (`native-fired`);
//   otherwise native stayed silent for whatever reason (served `off`, a keypress, a dialog, a
//   failure, agents running), one `idle_silent` row counts the break, and, with `idle_compact`
//   auto, the plugin compacts the main session itself while the cache is still warm: always while
//   agents run (native never compacts then; owner 2026-10-27 03:4x "Compact (Recommended)", which
//   replaces xxxxxxxx-38 "Measure more first"), and at Claude Code's idle minimum or more when
//   none run (owner 18:54 Q2: compact instead of the handoff turn). The same guards as `compact`
//   (`compactGuards`, IDLE-COMPACT D4), the same failure count (D7). Below that minimum, or with
//   `idle_compact: off`, the handoff turn runs (`agents-running` while agents run). Armed while
//   `idle_handoff_turn` or `idle_compact` is auto (lane B).
// - `off`: nothing (a headless load: no plugin turn and, until lane B1, no plugin compaction).
// Every timer re-reads the wall clock at least once a minute (D12 ticks), so a computer that
// wakes before the due fires on time; one that wakes after it meets the lapsed bound.
// One `idle_mode {native, plugin_turn, plugin_compact, compact_min?, served_hint?, cache_s?}` row
// whenever that policy changes for a session id; `served_hint` (2b) is Claude Code's cached server
// mode, logged only, never used to decide. The due is persisted (`idle_due:<sid>`, §3.1) with the
// load that holds it: a fire checks once that it still holds it (G1, D14), and every clear writes
// a short-lived tombstone, so a missing record reads as a lost write (`due-missing`), never as a
// takeover. A new load (hot reload, `--resume`, a supervisor move) adopts a record it finds and
// fires it late only within a bound (§3.4). When the turn's checks pass, one plugin-submitted
// handoff turn runs on the D-18 machinery (handoff-turn.ts); no plugin compaction and no continue
// follow it (DP-4; PR-2 P-56 is not reviewed); at most one per idle episode.
// Keep-warm (D-14, keepwarm.ts): while the gap warms (a background job of this session open, the
// one-hour cache), every kind's fire waits (`keep-warm`) and its record goes back here when warming
// stops with the cache warm (`handOverIdle`), anchored at the last warm ping (`warm`). A gap with no
// record armed or held (both paths off, or no kind at this size) or with `triggers` off never warms
// (`no-idle-path`): no path here would take it over after the pings.
import type { CacheTtl, Deps, IdleEnv, NativeIdle, Usage } from './deps'
import type { Effective } from './config'
import type { BoundaryResult } from './boundary'
import { boundary } from './boundary'
import { compactedSince, dispatchExists } from './compact'
import { effective } from './config'
import { cacheTtlOf } from './deps'
import { forkMissed, keepWarmHolds, resultJobOpen } from './keepwarm'
import { laneAtCheck } from './lane'
import { limitCtx, tierFields, verdictOf } from './limits'
import { MIN_ALLOWANCE, OPTIONAL_PER_HOUR, SPENT_MARGIN, dropDeferred, maxCalls, newTurn, openAndSubmit, recentTurns, skipped } from './handoff-turn'
import { log } from './log'

/** The one-hour prompt cache every idle time below is a share of (scaled by the D10 test seam). */
export const IDLE_CACHE_MS = 3600000
/** Native `NVo`: the compaction fires at this share of the cache life after the last request. */
export const IDLE_COMPACT_FRACTION = 0.9
/** The cache counts as lapsed this far into its life (58 min): no compaction from a cold cache. */
export const IDLE_LAPSE_FRACTION = 58 / 60
/** Native `jVo`: a timer that comes this much later than its due is `lapsed`. */
export const IDLE_LATE_MS = 60000
/** Native `M5e`: a person seen at the prompt this recently is present (G7). */
export const IDLE_PRESENT_MS = 60000
/** D3: the compaction never fires sooner than this after the turn end. */
export const IDLE_AFTER_END_MS = 60000
/** D12 (lane B): the longest wait of an idle timer; each tick re-reads the wall clock (not scaled). */
export const IDLE_TICK_MS = 60000
/** D7: failed idle compactions in a row that turn the plugin's idle compaction off for the load. */
export const IDLE_COMPACT_FAILS_MAX = 2
/**
 * D6 (b), the ship gate of live probe L1-c4: an adopted load (a new process on the same session,
 * same Claude Code version and model) compacts. `false` if L1-c4's summary read share is below 0.8:
 * every adopted load then skips `adopted-cold`.
 */
export const ADOPTED_IDLE_COMPACT = true
/** 54 − 5 minutes after the turn end (IC-1 F3, F6; no key: tuned from P-IC-1 / E-1 `idle_gap_s`). */
export const IDLE_FIRE_MS = 49 * 60000
/** `@idle_min@`: the minutes the `[submit-idle]` text names. */
export const IDLE_MIN_TEXT = '49'
/**
 * Owner xxxxxxxx-17: the outcome check, about 55.5 minutes after the turn end (native fired 54:00
 * after the last request in 5 of 5 cases, within 15 s; its boundary lands 6–16 s later; the
 * 1-hour cache lasts to minute 60).
 */
export const IDLE_CHECK_MS = 55.5 * 60000
/** `@idle_min@` of a handoff turn the outcome check runs. */
export const IDLE_CHECK_MIN_TEXT = '55'
/** Claude Code's default idle floor (`CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS`, IC-1 F3): `idle_silent` rows from here up only. */
export const NATIVE_IDLE_FLOOR = 200000
/**
 * The idle handoff turn's limit share (`near-limit`): only with `idle_handoff_near_limit: skip`
 * (owner xxxxxxxx, 2026-10-30: "I want the handoff anyway", so the default `run` does not check
 * it), and with `skip-spend` only the spend-limit windows (owner xxxxxxxx, 0.1.2: configurable,
 * `run` the default). Plugin idle compaction and keep-warm go by limits.ts (D-80: 90%, or the band
 * above it while a job is open); a record with no window reported reads its share at arm here.
 */
export const NEAR_LIMIT_PCT = 90

/**
 * D-76: the `windows` of a near-limit row (`handoff_skipped`, `keep_warm_stop`, a trial skip
 * record): every window the usage reports, in its order, as `kind:percent` (whole percent, rounded
 * down); none reported, the record's reading at arm that decided, as `arm:percent`. Claude Code
 * reports a window's kind and share only (`five_hour`, `seven_day`, a gateway's `spend_limit`), no
 * model it applies to, so a row cannot name a per-model window.
 */
export function limitWindows(limits: Usage['rateLimits'], armPct: number | null = null): string[] {
  const pct = (p: number): string => (Number.isFinite(p) ? String(Math.floor(p)) : 'unknown')
  if (limits.length > 0) return limits.map(l => `${l.kind || 'unknown'}:${pct(l.percentUsed)}`)
  return armPct === null ? [] : [`arm:${pct(armPct)}`]
}
/** A tombstone outlives every timer that could still hold its record (§3.1): its due plus this. */
const TOMBSTONE_LIFE_MS = IDLE_LATE_MS + 60000
/** D15: the windows that show a subscription, so the one-hour main-thread cache. */
const PLAN_WINDOWS: readonly string[] = ['five_hour', 'seven_day']
/** The window a Claude gateway reports for its money spend cap (not a plan's usage allowance). */
const SPEND_WINDOW = 'spend_limit'
/** D7: the failure classes of `BoundaryResult` that count (a person's turn or a headless host do not). */
const COUNTED_FAILS: readonly string[] = ['skipped', 'other', 'failed', 'unclaimed', 'error']

function dueKey(sid: string): string {
  return `idle_due:${sid}`
}

/**
 * `turn`: the 49-min handoff turn; `check`: the 55.5-min outcome check (native on or unreadable);
 * `compact`: the plugin's own idle compaction (native vetoed).
 */
export type IdleKind = 'turn' | 'check' | 'compact'

/**
 * The persisted timer (§3.1): when it fires, its kind, the turn end it was armed at, the idle
 * episode it belongs to, whether that turn ended `answer`, and whether a handoff was published
 * since the last human-origin turn (@bg). `load` is the load that armed or adopted it (G1).
 * `anchor` is the start of the last main request at arm (null: use `end`); `tokens`, `ttl` and
 * `pct` are the context size, the cache (Claude Code's TTL switch when one is set, `5m` with
 * caching off, else `1h` when a plan window was reported, D15) and the highest window share at
 * arm, which a new process reads before its first request reports any (G10-G12); `spct` the
 * highest spend-limit share at arm (null: none reported), for `idle_handoff_near_limit: skip-spend`;
 * `cc` and `model` are the Claude Code version and main model at arm (G3a). `warm` is the start of
 * the last keep-warm ping of a record handed back by keep-warm (`handOverIdle`): the cache counts
 * from there, not from the turn end, for the turn's 55.5-min bound and the check re-armed after it.
 * `held` marks a record keep-warm holds while the gap warms (`holdIdle`: due at its next ping,
 * anchored at the last warm one, with the gap's start and its warm pings so far); no timer of the
 * holding load runs for it, and a load that adopts it (a reload while warming) ends that warming
 * (`keep_warm_stop {why: reload}`) and fires it at that due, while the cache is still warm.
 * `job` marks a record keep-warm handed back with a job still open (D-79: an agent's, a workflow's
 * or a working teammate's result turn would read the conversation cold; a background shell may never
 * end, and it counts all the same): plugin idle compaction takes it from `idle_handoff_min_tokens` up
 * (`compactFloor`).
 * A load that re-arms the timer has seen no turn end of its own, so the `aborted` and `published`
 * checks and `gap_s` read the turn from here. Such a load is a background session the supervisor
 * moved to a new version (no SessionEnd), a `claude respawn` or a process ended by a signal
 * (SessionEnd `other`, which keeps the due: onSessionEnd), each one then resumed under its id;
 * after `/exit` (`prompt_input_exit`), `/clear`, `resume` or `logout` the due is cleared. A record
 * written before a field reads it as null, not answered (the old verdict) and not published.
 */
export type Due = {
  due: number; sid: string; episode: { since: number; done: boolean } | null
  kind: IdleKind; end: number | null
  answer: boolean; published: boolean
  load: string | null; anchor: number | null; tokens: number | null
  ttl: '1h' | '5m' | null; pct: number | null; spct: number | null; cc: string | null; model: string | null
  warm?: number | null
  held?: { start: number; pings: number }
  job?: true
}

/** Every clear of a record (§3.1): which load cleared which due, and when. */
type Tombstone = { cancelled: true; sid: string; load: string; due: number; at: number }

const numOrNull = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null)
const strOrNull = (v: unknown): string | null => (typeof v === 'string' ? v : null)

function readTombstone(v: unknown): Tombstone | undefined {
  if (typeof v !== 'object' || v === null) return undefined
  const o = v as Record<string, unknown>
  if (o.cancelled !== true) return undefined
  return { cancelled: true, sid: String(o.sid ?? ''), load: String(o.load ?? ''), due: numOrNull(o.due) ?? 0, at: numOrNull(o.at) ?? 0 }
}

/** The record, or undefined for a tombstone, a cleared key or anything else. */
function readDue(v: unknown): Due | undefined {
  if (typeof v !== 'object' || v === null) return undefined
  const o = v as Record<string, unknown>
  if (o.cancelled === true || typeof o.due !== 'number' || typeof o.sid !== 'string') return undefined
  const e = o.episode as Record<string, unknown> | null | undefined
  const episode = e && typeof e.since === 'number' && typeof e.done === 'boolean' ? { since: e.since, done: e.done } : null
  // A record written before the outcome check has no kind: it is the 49-min turn.
  const kind: IdleKind = o.kind === 'check' ? 'check' : o.kind === 'compact' ? 'compact' : 'turn'
  return {
    due: o.due, sid: o.sid, episode, kind, end: numOrNull(o.end), answer: o.answer === true, published: o.published === true,
    load: strOrNull(o.load), anchor: numOrNull(o.anchor), tokens: numOrNull(o.tokens),
    ttl: o.ttl === '1h' || o.ttl === '5m' ? o.ttl : null, pct: numOrNull(o.pct), spct: numOrNull(o.spct),
    cc: strOrNull(o.cc), model: strOrNull(o.model),
    ...(numOrNull(o.warm) !== null ? { warm: numOrNull(o.warm) } : {}),
    ...(readHeld(o.held) ?? {}),
    ...(o.job === true ? { job: true as const } : {}),
  }
}

function readHeld(v: unknown): { held: { start: number; pings: number } } | undefined {
  if (typeof v !== 'object' || v === null) return undefined
  const h = v as Record<string, unknown>
  const start = numOrNull(h.start)
  const pings = numOrNull(h.pings)
  return start !== null && pings !== null ? { held: { start, pings } } : undefined
}

/** The moment a record's turn-time bounds count from: its last keep-warm ping, else its turn end. */
function baseOf(rec: Due): number | null {
  return rec.warm ?? rec.end
}

/** G1's reading of the store: nothing there (a lost write), a tombstone, or a record. */
function readStored(v: unknown): 'missing' | 'tombstone' | Due {
  if (readTombstone(v)) return 'tombstone'
  return readDue(v) ?? 'missing'
}

const secs = (ms: number): number => Math.round(ms / 1000)

/** D10: the test seam's scale for every cache-derived time (1 without it). */
export function scaleOf(env: IdleEnv): number {
  return env.cacheS === undefined ? 1 : env.cacheS / 3600
}

/**
 * One idle skip row, with the timer's kind, when late by how much, and a near-limit skip's windows
 * and rule (D-80, with the plan words Claude Code's environment has).
 */
async function idleSkip(d: Deps, sid: string, why: string, kind: IdleKind, lateS?: number, windows?: string[], rule?: string): Promise<void> {
  await skipped(d, sid, why, null, 'idle', {
    kind, ...(lateS !== undefined ? { late_s: lateS } : {}), ...(windows !== undefined ? { windows } : {}),
    ...(rule !== undefined ? { rule, ...(await tierFields(d)) } : {}),
  })
}

/** A skip reason with the windows its row names (`near-limit`, D-76) and the rule that decided (D-80). */
type Skip = { why: string; windows: string[]; rule?: string }

/**
 * Cancels the timer (synchronous: safe before any await in a hook). The generation goes up, so a
 * tick that is reading the clock right now re-arms nothing (D12).
 */
export function cancelIdleTimer(d: Deps): void {
  d.state.idleTimer?.cancel()
  d.state.idleTimer = undefined
  d.state.idleGen++
}

/** Cancels the pending delete of this load's last tombstone of `sid`: a newer write replaces it. */
function dropTombDelete(d: Deps, sid: string): void {
  d.state.idleTombDeletes.get(sid)?.cancel()
  d.state.idleTombDeletes.delete(sid)
}

/**
 * Writes a tombstone over the record of `due` (§3.1) and deletes it once every timer that could
 * still hold that record has fired, if it is still this one then (the next arm overwrites it
 * anyway; `loadIdle` deletes an expired one of its own session id). One pending delete per
 * session id: the next tombstone or record of the sid cancels this one's.
 */
async function writeTombstone(d: Deps, sid: string, due: number, at?: number): Promise<void> {
  const t: Tombstone = { cancelled: true, sid, load: d.state.loadId, due, at: at ?? (await d.now()) }
  await d.storeSet(dueKey(sid), t)
  dropTombDelete(d, sid)
  const h = d.after(Math.max(0, due + TOMBSTONE_LIFE_MS - t.at), () => {
    if (d.state.idleTombDeletes.get(sid) === h) d.state.idleTombDeletes.delete(sid)
    void (async () => {
      const v = readTombstone(await d.storeGet(dueKey(sid)))
      if (v && v.load === t.load && v.due === t.due && v.at === t.at) await d.storeDelete(dueKey(sid))
    })().catch(() => undefined)
  })
  d.state.idleTombDeletes.set(sid, h)
}

/** A record's tombstone (§3.1); nothing when the key is already empty or a tombstone. */
async function clearDue(d: Deps, sid: string): Promise<void> {
  const v = readStored(await d.storeGet(dueKey(sid)))
  if (v === 'missing' || v === 'tombstone') return
  await writeTombstone(d, sid, v.due)
}

/**
 * Cancels the timer and clears the persisted due with a tombstone (a turn started, a prompt
 * entered, the session ended), so a reload of the same sid re-arms nothing already cancelled
 * (AT-IC-14), and a timer of another process on the same sid finds it held elsewhere (§3.5).
 * Callers may have cancelled the timer already (cancelIdleTimer before any await); the due is
 * cleared all the same.
 */
export async function cancelIdle(d: Deps, sid: string): Promise<void> {
  cancelIdleTimer(d)
  const held = d.state.idleDueSid
  d.state.idleDueSid = undefined
  if (held !== undefined && held !== sid) await clearDue(d, held)
  await clearDue(d, sid)
}

/**
 * D12 (lane B, §3.3): ticks of at most a minute to the due, each re-reading the wall clock, so a
 * wait that the computer's sleep stretched (a monotonic clock, INFERRED) fires on time when it
 * wakes before the due; the last tick is exact, and one that comes late meets G3 `lapsed`. A
 * cancel (turn start, entering prompt, session end) while a tick reads the clock stops it from
 * re-arming (`idleGen`). `atLoad`: the due had already passed when this load adopted the record
 * (§3.4 late-fire), so G7 applies to the fire of every kind, not only `compact`. Exported for
 * its unit test (AT-IC-C35: the kit cannot hold `$.clock.now` while a tick reads it).
 */
export function schedule(d: Deps, rec: Due, now: number, atLoad = false): void {
  cancelIdleTimer(d)
  const gen = d.state.idleGen
  d.state.idleAtLoad = atLoad
  d.state.idleTimer = d.after(Math.max(0, Math.min(rec.due - now, IDLE_TICK_MS)), () => {
    d.state.idleTimer = undefined
    d.state.inflight = (async () => {
      const t = await d.now()
      if (d.state.idleGen !== gen) return
      if (t < rec.due) return schedule(d, rec, t, atLoad)
      d.state.idleFiring++
      try {
        await fire(d, rec, t, atLoad)
      } finally {
        d.state.idleFiring--
      }
    })().catch(() => undefined)
  })
}

/**
 * A prompt entering that started no turn (a hook dropped it, or its submit threw): the idle timer
 * `prompt.submit` cancelled runs again for the record this load still has in the store, as it was
 * armed (its due, its `atLoad`). Without it the record would stay there with no timer behind it:
 * keep-warm would read an idle path that never comes, and its hand-over would be lost. Nothing for
 * a record keep-warm holds (no timer of this load runs for it), one cleared or held by another
 * load, or while a fire of this load runs (it takes the record); a turn, a prompt or an arm that
 * comes during the read decides instead.
 */
export async function resumeIdle(d: Deps): Promise<void> {
  const s = d.state
  const sid = s.idleDueSid
  if (sid === undefined || s.idleTimer !== undefined || s.idleFiring > 0) return
  const gen = s.idleGen
  const v = readStored(await d.storeGet(dueKey(sid)))
  if (v === 'missing' || v === 'tombstone' || v.sid !== sid || v.load !== s.loadId || v.held !== undefined) return
  const now = await d.now()
  if (s.idleGen !== gen || s.idleTimer !== undefined || s.idleFiring > 0 || s.idleDueSid !== sid) return
  schedule(d, v, now, s.idleAtLoad)
}

async function persist(d: Deps, rec: Due): Promise<void> {
  const { held: _held, ...plain } = rec
  const own: Due = { ...plain, load: d.state.loadId }
  await d.storeSet(dueKey(own.sid), own)
  dropTombDelete(d, own.sid)
  d.state.idleDueSid = own.sid
  schedule(d, own, await d.now())
}

/**
 * Keep-warm (D-14) hands the record it held back to the idle path with the cache still warm: due
 * now, anchored at the start of the last warm ping (`anchor` for the compaction's lapse guard,
 * `warm` for the turn's), with the episode, the turn's end and the published flag as they are now.
 * `job` (D-79, owner 2026-11-08 23:22: "after the last keep-warm ... you would actually compact to
 * avoid re-reading the cold cache"): a stop with a job still open (the cutoff, the deadline, the
 * limit band) compacts from `idle_handoff_min_tokens` up, since the job's result turn would read
 * a cold cache after an idle handoff turn, which does not compact; a 49-min turn record becomes
 * the compaction where the plugin may compact (native vetoed, `idle_compact` on), never against
 * `"autoCompactEnabled": false` or `idle_compact: false`.
 */
export async function handOverIdle(d: Deps, rec: Due, warm: number, now: number, job = false): Promise<void> {
  const s = d.state
  let kind = rec.kind
  if (job && kind === 'turn' && idleSwitches(d).compactOn && (await d.nativeIdle()) === 'vetoed') kind = 'compact'
  await persist(d, {
    ...rec, kind, due: now, anchor: warm, warm, episode: s.idleEpisode ?? null, answer: s.lastTurnAnswer, published: s.publishedSinceHuman,
    ...(job ? { job: true as const } : {}),
  })
}

/**
 * The smallest context plugin idle compaction takes for this record: Claude Code's idle minimum,
 * or for a record keep-warm handed back with a job open (D-79) `idle_handoff_min_tokens` when lower.
 */
function compactFloor(d: Deps, rec: Due, env: IdleEnv): number {
  return rec.job === true ? Math.min(env.compactMin, d.cfg.idle_handoff_min_tokens) : env.compactMin
}

/**
 * Keep-warm (D-14): the latest moment a record it holds still fires on the idle path once handed
 * back anchored at `warm`: the turn's 55.5-min bound (`fire`), else the compaction's lapse guard
 * (G3, 58 min; the check compacts by the same guards).
 */
export function heldDeadline(rec: Due, warm: number, scale: number): number {
  return warm + (rec.kind === 'turn' ? IDLE_CHECK_MS : IDLE_LAPSE_FRACTION * IDLE_CACHE_MS) * scale
}

/**
 * Keep-warm (D-14) holds the record while its gap warms: it stays in the store (not a tombstone),
 * due at the next ping and anchored at the last warm request, so a load that adopts it after a
 * reload (a hot reload, `claude respawn`, a supervisor move, SessionEnd `other`) still fires it
 * while the cache is warm. No timer of this load runs for it: keep-warm hands it back
 * (`handOverIdle`) or releases it (`releaseHeld`).
 */
export async function holdIdle(d: Deps, rec: Due, h: { due: number; warm: number; start: number; pings: number }): Promise<void> {
  const s = d.state
  const own: Due = { ...rec, due: h.due, anchor: h.warm, warm: h.warm, load: s.loadId, held: { start: h.start, pings: h.pings } }
  await d.storeSet(dueKey(rec.sid), own)
  dropTombDelete(d, rec.sid)
  s.idleDueSid = rec.sid
}

/** The record keep-warm holds for `sid` in the store, when this load still holds it (G1's reading). */
export async function heldHere(d: Deps, sid: string): Promise<Due | undefined> {
  const v = readStored(await d.storeGet(dueKey(sid)))
  return v !== 'missing' && v !== 'tombstone' && v.held !== undefined && v.load === d.state.loadId ? v : undefined
}

/**
 * Keep-warm (D-14): an idle record of `sid` is in the store, armed or held (not a tombstone), so an
 * idle path (the handoff turn, the plugin's compaction or the 55.5-min check) can take the gap over.
 */
export async function idleArmed(d: Deps, sid: string): Promise<boolean> {
  const v = readStored(await d.storeGet(dueKey(sid)))
  return v !== 'missing' && v !== 'tombstone' && v.sid === sid
}

/**
 * Keep-warm stopped with no hand-over: the record it held is cleared (a tombstone), or with `keep`
 * (SessionEnd `other`, whose next process resumes the session) left for that process as a plain
 * record due at the next ping. Nothing when another load holds it now.
 */
export async function releaseHeld(d: Deps, sid: string, keep: boolean): Promise<void> {
  const v = await heldHere(d, sid)
  if (!v) return
  if (d.state.idleDueSid === sid) d.state.idleDueSid = undefined
  if (!keep) return writeTombstone(d, sid, v.due)
  const { held: _held, ...plain } = v
  await d.storeSet(dueKey(sid), plain)
}

/** The policy at this moment (§1.2): Claude Code's own idle compaction and the plugin's paths. */
type Policy = { native: NativeIdle; turnOn: boolean; compactOn: boolean; env: IdleEnv }

/**
 * IA-3, owner xxxxxxxx-17 and IDLE-COMPACT §1.2: the policy, with one `idle_mode` row when its
 * tuple differs from the last one this load wrote for this session id (so a `/clear` in the same
 * load gets its own). The served hint (2b) is read only where it could matter (the check), and
 * only logged.
 */
async function policy(d: Deps, sid: string): Promise<Policy> {
  const s = d.state
  const native = await d.nativeIdle()
  const env = await d.idleEnv()
  // A headless session submits no model turn, and (until lane B1) gets no idle compaction.
  const { turnOn, compactOn } = idleSwitches(d)
  const live = native === 'on' || native === 'unknown'
  const pluginTurn = live ? (turnOn ? 'check' : 'off') : turnOn ? 'on' : 'off'
  // `check` (lane B): the 55.5-min check compacts itself when Claude Code stayed silent (with
  // agents running, or at the minimum or more with none: owner Q2). Lane A wrote `agents` there.
  const pluginCompact = native === 'compaction-off' ? 'off' : compactOn ? (live ? 'check' : 'on') : (s.idleCompactOff ?? 'off')
  const served = live && (turnOn || compactOn) ? await d.servedHint() : undefined
  const fields = {
    native, plugin_turn: pluginTurn, plugin_compact: pluginCompact,
    ...(pluginCompact === 'on' || pluginCompact === 'check' ? { compact_min: env.compactMin } : {}),
    ...(served !== undefined ? { served_hint: served } : {}),
    ...(env.cacheS !== undefined ? { cache_s: env.cacheS } : {}),
  }
  const tuple = JSON.stringify(fields)
  if (s.idleMode?.sid !== sid || s.idleMode.tuple !== tuple) {
    s.idleMode = { sid, tuple }
    await log(d, sid, 'idle_mode', fields)
  }
  return { native, turnOn, compactOn, env }
}

/**
 * The plugin's two idle paths as the options and this load allow them: the handoff turn
 * (`idle_handoff_turn`) and its own idle compaction (`idle_compact`, off for the load after D7).
 * A headless load has neither (no model turn; lane B1 has the headless compaction).
 */
function idleSwitches(d: Deps): { turnOn: boolean; compactOn: boolean } {
  const s = d.state
  return {
    turnOn: d.cfg.idle_handoff_turn === 'auto' && !s.headless,
    compactOn: d.cfg.idle_compact === 'auto' && s.idleCompactOff === undefined && !s.headless,
  }
}

/** §1.2: the kind a turn end at this context size arms. Tokens cannot grow without a main turn. */
function pickKind(p: Policy, tokens: number | undefined): IdleKind | 'off' {
  // Lane B: the check is armed for the turn, or for the plugin's compaction at it, which needs
  // Claude Code's idle minimum (with agents running too: G10).
  if (p.native === 'on' || p.native === 'unknown') {
    if (p.turnOn) return 'check'
    return p.compactOn && (tokens === undefined || tokens >= p.env.compactMin) ? 'check' : 'off'
  }
  if (p.native === 'vetoed' && p.compactOn && (tokens === undefined || tokens >= p.env.compactMin)) return 'compact'
  return p.turnOn ? 'turn' : 'off'
}

/** No kind at all (any context size) under this policy. */
function policyOff(p: Policy): boolean {
  return pickKind(p, undefined) === 'off' && pickKind(p, 0) === 'off'
}

/** D15: the five-hour and seven-day windows the usage reports (a gateway's `spend_limit` is not one). */
function planOf(u: Use): Usage['rateLimits'] {
  return (u?.rateLimits ?? []).filter(l => PLAN_WINDOWS.includes(l.kind))
}

/**
 * Main `turn.complete` (any origin): (re)arms the timer for the kind the policy gives (§1.2):
 * `compact` at `max(anchor + 54 min, end + 60 s)`, `turn` at `end + 49 min`, `check` at
 * `end + 55.5 min`; `off` arms nothing and drops a timer armed before.
 */
export async function armIdle(d: Deps, sid: string, endAt: number): Promise<void> {
  const s = d.state
  const p = await policy(d, sid)
  const u = await usageOrNone(d)
  const kind = pickKind(p, u?.tokens)
  if (kind === 'off') {
    if (s.idleTimer !== undefined || s.idleDueSid !== undefined) await cancelIdle(d, sid)
    return
  }
  const scale = scaleOf(p.env)
  // D3: the cache is refreshed when a request reads it, so the compaction counts from the start
  // of the last main request; a turn that ended long after it (an aborted tool run) gets a minute.
  const anchor = s.lastMainReqAt !== undefined && s.lastMainReqAt <= endAt ? s.lastMainReqAt : endAt
  const due = kind === 'compact'
    ? Math.max(anchor + IDLE_COMPACT_FRACTION * IDLE_CACHE_MS * scale, endAt + IDLE_AFTER_END_MS)
    : endAt + (kind === 'turn' ? IDLE_FIRE_MS : IDLE_CHECK_MS) * scale
  let cc: string | null = null
  let model: string | null = null
  // G3a: the check may compact too (lane B), so it keeps the prefix it was armed with as well.
  if (kind === 'compact' || kind === 'check') {
    try {
      cc = (await d.version()).version
    } catch {
      cc = null
    }
    model = (await d.model()) ?? null
  }
  const limits = u?.rateLimits ?? []
  const spend = limits.filter(l => l.kind === SPEND_WINDOW)
  // The cache this load writes (D15, G11): caching off or a TTL switch first, else the plan windows.
  const set = p.env.cacheOff ? '5m' : await explicitTtl(d, p.env)
  s.idleAdopted = false
  await persist(d, {
    due, sid, episode: s.idleEpisode ?? null, kind, end: endAt, answer: s.lastTurnAnswer, published: s.publishedSinceHuman,
    load: s.loadId, anchor, tokens: u?.tokens ?? null, ttl: set ?? (u === undefined ? null : planOf(u).length > 0 ? '1h' : '5m'),
    pct: limits.length > 0 ? Math.max(...limits.map(l => l.percentUsed)) : null,
    spct: spend.length > 0 ? Math.max(...spend.map(l => l.percentUsed)) : null, cc, model,
  })
}

/**
 * G11: the main conversation's cache TTL as Claude Code's own switches set it (`FORCE_PROMPT_CACHING_5M`,
 * `CLAUDE_CODE_PROMPT_CACHE_TTL`, the `promptCacheTtl` setting, `ENABLE_PROMPT_CACHING_1H`,
 * `CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL`), or undefined when none is set (automatic).
 */
async function explicitTtl(d: Deps, env: IdleEnv): Promise<CacheTtl | undefined> {
  return cacheTtlOf(env.ttl, await d.promptCacheTtl())
}

/**
 * A handoff was just published (handoff-turn.ts, at the end of the turn that wrote it, after that
 * turn armed its due): the persisted due records it, so a load that re-arms it skips `published`.
 */
export async function markIdlePublished(d: Deps, sid: string): Promise<void> {
  const rec = readDue(await d.storeGet(dueKey(sid)))
  if (!rec || rec.sid !== sid || rec.published) return
  await d.storeSet(dueKey(sid), { ...rec, published: true })
}

/** §3.4: a due that passed while no process held it still fires at load within these bounds. */
function lateFireOk(rec: Due, now: number, scale: number): boolean {
  if (rec.kind === 'compact') {
    return now - rec.due <= IDLE_LATE_MS && now - (rec.anchor ?? rec.end ?? rec.due) <= IDLE_LAPSE_FRACTION * IDLE_CACHE_MS * scale
  }
  if (rec.kind === 'check') return now - rec.due <= IDLE_LATE_MS
  // A handoff turn up to minute 55.5 is accepted practice: the check runs one there.
  const base = baseOf(rec)
  return base !== null && now <= base + IDLE_CHECK_MS * scale
}

/**
 * Once per load (AT-IC-14, §3.4): the persisted due of this sid is adopted (written back with this
 * load's id, so a timer of the process it came from finds it held elsewhere) and armed again; one
 * whose due passed fires at once within its late-fire bound, where G7 (`present`) applies to
 * every kind (an interactive `session.start` stamps presence before this runs), else it writes
 * one `lapsed` row and is cleared. A legacy record (no turn end) past its due, another sid's and a
 * tombstone are ignored; an expired tombstone of this sid is deleted. A hot reload of this module
 * raises `session.start` again (Claude Code 2.1.311), whose `prepare` brings it here.
 */
export async function loadIdle(d: Deps, sid: string): Promise<void> {
  const s = d.state
  const p = await policy(d, sid)
  const stored = await d.storeGet(dueKey(sid))
  const now = await d.now()
  const t = readTombstone(stored)
  if (t) {
    if (t.sid === sid && now > t.due + TOMBSTONE_LIFE_MS) await d.storeDelete(dueKey(sid))
    return
  }
  const rec = readDue(stored)
  if (!rec || rec.sid !== sid || policyOff(p)) return
  if (rec.due <= now) {
    if (rec.end === null) return
    if (!lateFireOk(rec, now, scaleOf(p.env))) {
      if (rec.held !== undefined && rec.load !== s.loadId) {
        await log(d, sid, 'keep_warm_stop', { why: 'reload', pings: rec.held.pings, gap_s: secs(now - rec.held.start), handover: false })
      }
      await idleSkip(d, sid, 'lapsed', rec.kind, secs(now - rec.due))
      await writeTombstone(d, sid, rec.due, now)
      return
    }
  }
  if (rec.episode && !s.idleEpisode) s.idleEpisode = rec.episode
  // No turn ended in this load yet: the last turn is the one the record was armed at.
  if (s.lastTurnEndAt === undefined) {
    s.lastTurnAnswer = rec.answer
    if (rec.end !== null) s.lastTurnEndAt = rec.end
    if (rec.published) s.publishedSinceHuman = true
  }
  s.idleAdopted = rec.load !== s.loadId
  // Keep-warm (D-14): a record its gap held while warming in another load ends that warming here
  // (the load that pinged is gone), and goes on as a plain record at the due it holds.
  const { held, ...plain } = rec
  if (held !== undefined && rec.load !== s.loadId) {
    await log(d, sid, 'keep_warm_stop', { why: 'reload', pings: held.pings, gap_s: secs(now - held.start), handover: true })
  }
  const own: Due = { ...plain, load: s.loadId }
  await d.storeSet(dueKey(sid), own)
  s.idleDueSid = sid
  schedule(d, own, now, rec.due <= now)
}

type Go = { tokens: number; allowance: number; native: number; calls: number }

type Use = { tokens: number | undefined; rateLimits: Usage['rateLimits'] } | undefined

/**
 * D15 / G11: no one-hour cache. Prompt caching is off (`DISABLE_PROMPT_CACHING*`); else Claude
 * Code's own TTL switch decides when one is set (`5m`: skip; `1h`: a one-hour cache, plan window or
 * not); else the usage reports no plan window. A load that adopted the record has made no request
 * of its own yet (the usage reports none before the first response), so it goes by the record's
 * reading at arm.
 */
async function ttl5m(d: Deps, env: IdleEnv, u: Use, rec: Due): Promise<boolean> {
  if (env.cacheOff) return true
  const set = await explicitTtl(d, env)
  if (set !== undefined) return set === '5m'
  if (planOf(u).length > 0) return false
  return !(d.state.idleAdopted && rec.ttl === '1h')
}

/**
 * Keep-warm (D-14): the main conversation's cache is the one-hour one: caching on, and Claude
 * Code's own TTL switch says `1h`, or none is set and the usage reports a plan window (D15).
 */
export async function oneHourCache(d: Deps, env: IdleEnv, u: Use): Promise<boolean> {
  if (env.cacheOff) return false
  const set = await explicitTtl(d, env)
  if (set !== undefined) return set === '1h'
  return planOf(u).length > 0
}

/**
 * G12: a window at the limit share or more (any kind, a gateway's too; `spendOnly`: a gateway's
 * spend limit only, plan windows ignored); none reported: the record's reading at arm. Near the
 * limit: the windows its row names (`limitWindows`); else undefined.
 */
function nearLimit(u: Use, rec: Due, spendOnly = false): string[] | undefined {
  const limits = u?.rateLimits ?? []
  if (limits.length > 0) {
    return limits.some(l => (!spendOnly || l.kind === SPEND_WINDOW) && !(l.percentUsed < NEAR_LIMIT_PCT)) ? limitWindows(limits) : undefined
  }
  const pct = spendOnly ? rec.spct : rec.pct
  return pct !== null && pct >= NEAR_LIMIT_PCT ? limitWindows([], pct) : undefined
}

/** The idle handoff turn's own near-limit skip (`idle_handoff_near_limit`): never under `run`. */
function turnNearLimit(d: Deps, u: Use, rec: Due): string[] | undefined {
  const mode = d.cfg.idle_handoff_near_limit
  return mode === 'run' ? undefined : nearLimit(u, rec, mode === 'skip-spend')
}

/**
 * G12 of plugin idle compaction (D-80, limits.ts): the windows reported, by the adaptive rule (a
 * window that reset counts for nothing); none reported, the record's highest share at arm (an old
 * reading: 90%, rule `arm-90`). A skip, or the band's rule for the `idle_compact` row, or nothing.
 */
async function compactLimit(d: Deps, sid: string, u: Use, rec: Due, now: number): Promise<Skip | { rule?: string }> {
  const limits = u?.rateLimits ?? []
  if (limits.length === 0) {
    return rec.pct !== null && !(rec.pct < NEAR_LIMIT_PCT) ? { why: 'near-limit', windows: limitWindows([], rec.pct), rule: 'arm-90' } : {}
  }
  const v = verdictOf(limits, await limitCtx(d, await resultJobOpen(d, sid), now))
  if (!v.ok) return { why: 'near-limit', windows: v.windows, rule: v.rule }
  return v.band ? { rule: 'band' } : {}
}

/** The checks of §9.4 "Fire" from `aborted` on, in order; the first that fails is the skip reason. */
async function laterChecks(d: Deps, sid: string, eff: Effective, u: Use, rec: Due): Promise<string | Skip | Go> {
  const s = d.state
  if (!s.lastTurnAnswer) return 'aborted'
  // A keep-warm ping since the last main request found the cache cold (keepwarm.ts): no turn on it.
  if (forkMissed(s, sid)) return 'fork-miss'
  const tokens = u?.tokens ?? rec.tokens ?? undefined
  // 0.1.5 D-3 (owner 2026-11-07, "3. yes"; session xxxxxxxx, ~166k tokens, finished and logged
  // `small` at every check): a lane that reads finished gets the turn below the floor too; every
  // other limit stands. Unknown tokens still skip: the turn's allowance below needs the size.
  if (tokens === undefined || (tokens < d.cfg.idle_handoff_min_tokens && (await laneAtCheck(d, sid)) !== 'finished')) return 'small'
  if (await ttl5m(d, await d.idleEnv(), u, rec)) return 'ttl-5m'
  const near = turnNearLimit(d, u, rec)
  if (near) return { why: 'near-limit', windows: near, rule: d.cfg.idle_handoff_near_limit === 'skip' ? 'option-skip' : 'option-skip-spend' }
  const ep = s.idleEpisode
  if (!ep || ep.done) return 'episode'
  if (s.publishedSinceHuman) return 'published'
  if ((await recentTurns(d, sid, await d.now())).length >= OPTIONAL_PER_HOUR) return 'cap'
  const c = maxCalls()
  if (c === undefined) return 'no-asset'
  const allowance = Math.min(d.cfg.handoff_turn_max_tokens, eff.native_trigger - SPENT_MARGIN - tokens)
  if (allowance < MIN_ALLOWANCE) return 'headroom'
  return { tokens, allowance, native: eff.native_trigger, calls: c }
}

export function isBusy(s: Deps['state']): boolean {
  return s.mainTurnRunning || s.foreignPrompts > 0 || s.busy || s.handoffTurn !== undefined || s.ourSubmitPending
}

/** G5: a main turn ended, or a main request started, after the ones the record was armed at. */
function newerTurn(s: Deps['state'], rec: Due): boolean {
  const end = rec.end ?? 0
  return (s.lastTurnEndAt ?? 0) > end || (s.lastMainReqAt ?? 0) > (rec.anchor ?? end)
}

/** G7 (D11): a person was seen at the prompt in the last minute. */
function present(s: Deps['state'], now: number): boolean {
  return s.lastInputAt !== undefined && now - s.lastInputAt < IDLE_PRESENT_MS
}

async function usageOrNone(d: Deps): Promise<Use> {
  try {
    return await d.usage()
  } catch {
    return undefined
  }
}

/**
 * The agents of this session at work (owner xxxxxxxx-38; the 2026-10-27 idle compaction): the
 * listed subagents and teammates at work (D-82: an idle teammate, which waits for a message, is
 * no running agent), with the agent loops whose turn is running in this load (a workflow's agents
 * are not listed). Keep-warm's open jobs and the lane's Basis count read agents the same way.
 */
export async function agentsRunning(d: Deps): Promise<number> {
  const ids = new Set<string>(d.state.agentTurns)
  for (const id of (await d.agentsWorking()) ?? []) ids.add(id)
  return ids.size
}

/**
 * The 49-min turn: the checks of §9.4 "Fire", in order (the session id is G2's, in `fire`). A
 * turn this load fires late at its start (`atLoad`, §3.4) also skips `present` (G7): a person who
 * just launched or resumed the session gets no plugin turn submitted in front of them.
 */
async function turnBlocked(d: Deps, sid: string, rec: Due, now: number, atLoad: boolean): Promise<string | Skip | Go> {
  if (!d.cfg.triggers) return 'triggers-off'
  const eff = await effective(d, sid)
  if (eff.disabled) return 'small-window'
  if (isBusy(d.state)) return 'busy'
  if (atLoad && present(d.state, now)) return 'present'
  return laterChecks(d, sid, eff, await usageOrNone(d), rec)
}

/** The plugin's own idle compaction at the check (owner 2026-10-27, owner Q2): its `idle_compact` row (`rule`: the limit band's, D-80). */
type Compact = { compact: true; gapS: number; tokens: number; agents: number; rule?: string }

/**
 * Owner xxxxxxxx-17: the 55.5-min outcome check. A check that fires more than a minute late is
 * `lapsed` (§3.4). A main compaction since the turn end stands down (`native-fired` for an idle
 * one, else `compacted`); a busy session is no idle break. A check this load fires late at its
 * start (`atLoad`, §3.4) skips `present` (G7): a person who just launched or resumed the session
 * gets neither a turn nor a compaction in front of them. Otherwise native stayed silent: one
 * `idle_silent` row at 200K and more, then, with `idle_compact` auto, the plugin's own idle
 * compaction behind the guards it shares with the `compact` timer (`compactGuards`, D4: lane A
 * had a shorter list here, without the cache and the limits): while agents run (owner 2026-10-27
 * 03:4x; native never compacts then), and with none running at Claude Code's idle minimum or
 * more, or with the turn off (owner Q2, 18:54: compact instead of the turn; a refusal is the
 * check's one row, no turn after it, as D2 rules for `compact`). Before the guards it reads
 * Claude Code's automatic compaction once more (G0b, as the `compact` timer does at its fire):
 * switched off since the arm, it never compacts (D1). Two refusals still give the turn, as before
 * lane B, when no agents run and the turn is on (root call on Q2, 2026-10-27): `halted` (a thrash
 * or bad-summary halt stops plugin compactions, not the turn; with `idle_handoff_near_limit: run`
 * also when `near-limit` came before it, root call NL-2, and with `skip-spend` when no spend limit
 * is at the share) and `compaction-off` (D1 keeps the
 * turn there). Else the turn's checks, or `agents-running` while agents run (the skip of before
 * 2026-10-27, with `idle_compact: off`).
 */
async function checkBlocked(d: Deps, sid: string, rec: Due, now: number, scale: number, atLoad: boolean): Promise<string | Skip | Go | Compact> {
  const on = idleSwitches(d)
  if (!on.turnOn && !on.compactOn) return 'disabled'
  if (now - rec.due > IDLE_LATE_MS) return 'lapsed'
  const end = rec.end
  const c = end === null ? undefined : await compactedSince(d, sid, end)
  if (c !== undefined) return c.idle ? 'native-fired' : 'compacted'
  // A compaction other than ours still running (a slow summary call) is not silence either.
  if (isBusy(d.state) || d.state.nativeCompacting > 0) return 'busy'
  if (atLoad && present(d.state, now)) return 'present'
  const u = await usageOrNone(d)
  const agents = await agentsRunning(d)
  const gap = end === null ? null : Math.round(((await d.now()) - end) / 1000)
  if (u?.tokens !== undefined && u.tokens >= NATIVE_IDLE_FLOOR) {
    const served = await d.servedHint()
    await log(d, sid, 'idle_silent', { gap_s: gap, tokens: u.tokens, agents, ...(served !== undefined ? { served_hint: served } : {}) })
  }
  const env = await d.idleEnv()
  const tokens = u?.tokens ?? rec.tokens ?? undefined
  if (on.compactOn && (agents > 0 || !on.turnOn || tokens === undefined || tokens >= compactFloor(d, rec, env))) {
    // G0b: the check's policy is the one it was armed with (no `idle_mode` row at its fire), but
    // `"autoCompactEnabled": false` set since then (`/config`, another session's settings write)
    // is an explicit user switch: no compaction.
    const g = (await d.nativeIdle()) === 'compaction-off' ? { why: 'compaction-off' } : await compactGuards(d, sid, rec, now, env)
    // The gap is the timer's own (about 3,330 s) when the turn end is unknown.
    if (!('why' in g)) return { compact: true, gapS: gap ?? Math.round((IDLE_CHECK_MS * scale) / 1000), tokens: g.tokens, agents, ...(g.rule !== undefined ? { rule: g.rule } : {}) }
    // Root call NL-2 (0.1.2): `near-limit` comes before `halted` in the guards, so under
    // `idle_handoff_near_limit: run` a halt that stops the compaction anyway (not the cap) falls
    // back to the turn the same way; `skip` keeps the near-limit skip, and `skip-spend` keeps it
    // only when a spend limit is at the share (plan windows alone fall back as under `run`).
    const haltedToo = g.why === 'near-limit' && turnNearLimit(d, u, rec) === undefined && d.state.halt.active && d.state.halt.reason !== 'cap'
    if (agents > 0 || !on.turnOn || (g.why !== 'halted' && g.why !== 'compaction-off' && !haltedToo)) return 'windows' in g ? g : g.why
  }
  if (agents > 0) return 'agents-running'
  if (!d.cfg.triggers) return 'triggers-off'
  const eff = await effective(d, sid)
  if (eff.disabled) return 'small-window'
  // Keep-warm (D-14): a record handed back anchored at its last warm request submits no turn past
  // the 58-minute lapse bound from it (the cache may have lapsed), as its compaction (G3) does not.
  if (typeof rec.warm === 'number' && now > rec.warm + IDLE_LAPSE_FRACTION * IDLE_CACHE_MS * scale) return 'lapsed'
  return laterChecks(d, sid, eff, u, rec)
}

/**
 * `boundary()` for an idle compaction. A throw is a failed attempt (`error`) with one skip row of
 * its own after the `idle_compact` row, so the fire still writes its one outcome (§2.3).
 */
async function idleBoundary(d: Deps, sid: string, kind: IdleKind, opts: Parameters<typeof boundary>[1]): Promise<BoundaryResult> {
  try {
    return await boundary(d, opts)
  } catch {
    await idleSkip(d, sid, 'error', kind)
    return { ran: true, ok: false, failClass: 'error' }
  }
}

/**
 * D7: a success resets the count of failed idle compactions; a failure of a counted class adds
 * one, and the second in a row turns the plugin's idle compaction off for the load (one
 * `idle_compact_off` row; the 49-min turn path takes over at the next turn end, and the check's
 * turn, or `agents-running`, at the next check). The timer's and the check's compactions count
 * together (lane B, D4).
 */
export async function countIdleCompact(d: Deps, sid: string, r: BoundaryResult): Promise<void> {
  const s = d.state
  if (!r.ran) return
  if (r.ok) {
    s.idleCompactFails = 0
    return
  }
  if (!COUNTED_FAILS.includes(r.failClass ?? 'error')) return
  s.idleCompactFails++
  if (s.idleCompactFails >= IDLE_COMPACT_FAILS_MAX && s.idleCompactOff === undefined) {
    s.idleCompactOff = 'failed'
    await log(d, sid, 'idle_compact_off', { why: 'failed', fails: s.idleCompactFails })
  }
}

/**
 * A fire's outcome (§2.3): `done` once its one row is written, a path that writes its own took
 * over (the `idle_compact` row and the compaction, the handoff turn), or G1 found the record held
 * elsewhere (no row by rule). A throw before that is the fire's one `error` row.
 */
type FireOut = { done: boolean }

/**
 * The timer fired (D14, §2.1 fire order). G1 once, first: a record another load holds (a later
 * armer or adopter, or a tombstone) leaves nothing to do here and no row, since the load that
 * holds it writes that episode's row; a record lost to a store write is `due-missing` (one row,
 * `lapsed` when the fire is also late). Then the record is cleared with a tombstone, G2 (the
 * session changed), and the path of the kind. Two processes that read it in the same moment can
 * both go on (the store has no compare-and-set). Every other fire of every kind writes exactly
 * one outcome: a throw anywhere before it, G1's own read included, is one `[error, kind]` row.
 * `atLoad`: the due had passed when this load adopted the record (§3.4).
 */
export async function fire(d: Deps, rec: Due, now: number, atLoad = false): Promise<void> {
  const out: FireOut = { done: false }
  try {
    await fireOnce(d, rec, now, atLoad, out)
  } catch {
    if (out.done) return
    const lateS = secs(now - rec.due)
    await idleSkip(d, rec.sid, 'error', rec.kind, rec.kind === 'compact' && lateS > 0 ? lateS : undefined).catch(() => undefined)
  }
}

async function fireOnce(d: Deps, rec: Due, now: number, atLoad: boolean, out: FireOut): Promise<void> {
  const s = d.state
  const sid = rec.sid
  const skip = (why: string, lateS?: number, windows?: string[], rule?: string): Promise<void> => {
    out.done = true
    return idleSkip(d, sid, why, rec.kind, lateS, windows, rule)
  }
  const stored = readStored(await d.storeGet(dueKey(sid)))
  if (stored === 'tombstone' || (stored !== 'missing' && (stored.load !== s.loadId || stored.due !== rec.due))) {
    out.done = true
    return
  }
  if (s.idleDueSid === sid) s.idleDueSid = undefined
  if (stored === 'missing') {
    const late = now - rec.due > IDLE_LATE_MS
    return skip(late ? 'lapsed' : 'due-missing', late ? secs(now - rec.due) : undefined)
  }
  await writeTombstone(d, sid, rec.due, now)
  if ((await d.sessionId()) !== sid) return skip('session-changed')
  // Keep-warm (D-14): while the gap warms, the record waits there (no turn, no compaction yet).
  if (await keepWarmHolds(d, rec, now)) return skip('keep-warm')
  if (rec.kind === 'compact') return fireCompact(d, rec, now, out)
  // The check writes no `idle_mode` row at its fire: it keeps its policy as armed and reads again
  // only automatic compaction (G0b, checkBlocked) before it compacts; the turn reads the full
  // policy again.
  const scale = scaleOf(await d.idleEnv())
  if (rec.kind === 'turn') {
    // A 49-min turn that finds native idle on or unreadable now logs `native-on` / `native-unknown`
    // and checks the outcome at 55.5 min instead (owner xxxxxxxx-17).
    const p = await policy(d, sid)
    if (!p.turnOn) return skip('disabled')
    if (p.native === 'on' || p.native === 'unknown') {
      await skip(p.native === 'on' ? 'native-on' : 'native-unknown')
      await rearmCheck(d, rec, now, scale)
      return
    }
    // §3.4: a turn starting after minute 55.5 (a late timer, a sleep) is lapsed.
    const base = baseOf(rec)
    if (base !== null && now > base + IDLE_CHECK_MS * scale) return skip('lapsed', secs(now - rec.due))
  }
  const b = rec.kind === 'check' ? await checkBlocked(d, sid, rec, now, scale, atLoad) : await turnBlocked(d, sid, rec, now, atLoad)
  if (typeof b === 'string') return skip(b, b === 'lapsed' ? secs(now - rec.due) : undefined)
  if ('why' in b) return skip(b.why, undefined, b.windows, b.rule)
  if ('compact' in b) {
    // Owner 2026-10-27 and owner Q2: one shaped compaction instead of the turn, run as the
    // `compact` timer runs its own (D4): asked once more after the checkpoint (`idleRecheck`),
    // exempt from halt for the auto-continue cap (D5), its failures counted (D7). A rejection (a
    // turn started, or a headless host that cannot compact between turns) is one
    // `compact_rejected` row from boundary(), never retried: the next check comes only after
    // another main turn end. A refusal before the compaction is one skip row (D13).
    out.done = true
    await log(d, sid, 'idle_compact', {
      gap_s: b.gapS, tokens: b.tokens, agents: b.agents, at: 'check', late_s: Math.max(0, secs(now - rec.due)), adopted: s.idleAdopted,
      ...(b.rule !== undefined ? { rule: b.rule, ...(await tierFields(d)) } : {}),
    })
    const r = await idleBoundary(d, sid, 'check', { idle: { gapS: b.gapS }, idleRecheck: recheckOf(d, sid, rec), exemptHalt: capHalt(s) })
    if (!r.ran) await idleSkip(d, sid, r.why, 'check')
    else await countIdleCompact(d, sid, r)
    return
  }
  const h = newTurn('idle', b.tokens, b.allowance, b.native, b.calls)
  if (rec.kind === 'check') h.idleMin = IDLE_CHECK_MIN_TEXT
  s.handoffTurn = h
  let ok: boolean
  try {
    ok = await openAndSubmit(d, sid, h, n => dispatchExists(d, sid, n))
  } catch (err) {
    // Nothing went out and no person's turn took it over: the attempt ends with the fire's error
    // row. Otherwise the handoff turn's own rows (a submit, `user-turn`) stand for it.
    if (s.handoffTurn === h && h.phase === 'delay' && !s.mainTurnRunning && s.foreignPrompts === 0) {
      s.handoffTurn = undefined
      throw err
    }
    out.done = true
    return
  }
  out.done = true
  if (!ok) {
    if (s.handoffTurn === h) s.handoffTurn = undefined
    return
  }
  if (h.phase === 'delay') {
    // A user prompt came first (it entered, or its turn started): the user is back.
    await dropDeferred(d, sid, h)
    return
  }
  // One per idle episode, whatever the turn's end (§9.4 `episode`).
  if (s.idleEpisode) s.idleEpisode.done = true
}

/**
 * The AT-IA-03 pattern (G0a): native idle came back on since the timer was armed, so the outcome
 * check is armed for the same turn end, when that is still ahead and the check is on at all (its
 * turn or, lane B, the plugin's compaction at it).
 */
async function rearmCheck(d: Deps, rec: Due, now: number, scale: number): Promise<void> {
  const end = baseOf(rec)
  if (end === null || end + IDLE_CHECK_MS * scale <= now) return
  await persist(d, { ...rec, due: end + IDLE_CHECK_MS * scale, kind: 'check', episode: d.state.idleEpisode ?? null, answer: d.state.lastTurnAnswer, published: d.state.publishedSinceHuman })
}

/**
 * The plugin's own idle compaction (kind `compact`, §2.1): after G1 and G2, G0a-G0c here, then
 * `compactGuards`; the first that fails is the one skip row (`handoff_skipped {why, reason: idle,
 * kind: compact, late_s?}`); then one `idle_compact` row and the compaction (boundary.ts, exempt
 * from halt for the auto-continue cap, D5), whose refusal is one more skip row (D13) and whose
 * failure counts for D7. A guard that throws is one `error` skip row: the record is already
 * cleared, so the episode ends here either way (§2.3); `out` tells `fire` when the outcome is
 * written, so a throw elsewhere is its one `error` row too.
 */
async function fireCompact(d: Deps, rec: Due, now: number, out: FireOut): Promise<void> {
  const s = d.state
  const sid = rec.sid
  const lateS = secs(now - rec.due)
  const skip = (why: string, windows?: string[], rule?: string): Promise<void> => {
    out.done = true
    return idleSkip(d, sid, why, 'compact', lateS > 0 || why === 'lapsed' ? lateS : undefined, windows, rule)
  }
  let p: Policy
  try {
    p = await policy(d, sid)
  } catch {
    return skip('error')
  }
  // G0a: native came back on (or unreadable): the outcome check for the same turn end.
  if (p.native === 'on' || p.native === 'unknown') {
    await skip(p.native === 'on' ? 'native-on' : 'native-unknown')
    if (p.turnOn || p.compactOn) await rearmCheck(d, rec, now, scaleOf(p.env))
    return
  }
  // G0b, G0c: automatic compaction switched off; the plugin's idle compaction off (the option,
  // D7, or a headless load: lane A has no headless path).
  if (p.native === 'compaction-off') return skip('compaction-off')
  if (!p.compactOn) return skip('disabled')
  let g: { why: string } | Skip | { tokens: number; rule?: string }
  try {
    g = await compactGuards(d, sid, rec, now, p.env)
  } catch {
    g = { why: 'error' }
  }
  if ('why' in g) return skip(g.why, 'windows' in g ? g.windows : undefined, 'rule' in g ? g.rule : undefined)
  const agents = await agentsRunning(d)
  const gapS = secs(now - (rec.end ?? now))
  out.done = true
  await log(d, sid, 'idle_compact', {
    gap_s: gapS, tokens: g.tokens, agents, at: 'timer', late_s: Math.max(0, lateS), adopted: s.idleAdopted,
    ...(g.rule !== undefined ? { rule: g.rule, ...(await tierFields(d)) } : {}),
  })
  const r = await idleBoundary(d, sid, 'compact', { idle: { gapS }, idleRecheck: recheckOf(d, sid, rec), exemptHalt: capHalt(s) })
  if (!r.ran) {
    await skip(r.why)
    return
  }
  await countIdleCompact(d, sid, r)
}

/** D5: halt for the auto-continue cap does not stop an idle compaction (no continue follows it). */
function capHalt(s: Deps['state']): boolean {
  return s.halt.active && s.halt.reason === 'cap'
}

/**
 * §2.4 `idleRecheck` for the plugin's idle compaction, at the timer and at the check (lane B, D4):
 * G4 (a turn, or a compaction other than ours: the boundary's own native check looks only after
 * a handoff turn), G5, G6 and G7 once more after the checkpoint, which can take seconds: a person
 * who came back meanwhile, or a `/compact` typed or sent meanwhile, is not compacted over (one
 * skip row from the boundary's result).
 */
function recheckOf(d: Deps, sid: string, rec: Due): () => Promise<string | undefined> {
  const s = d.state
  return async () => {
    if (s.mainTurnRunning || s.foreignPrompts > 0 || s.handoffTurn !== undefined || s.ourSubmitPending) return 'busy'
    if (s.nativeCompacting > 0 || s.ownCompact !== undefined) return 'busy'
    if (newerTurn(s, rec)) return 'newer-turn'
    if ((await compactedSince(d, sid, rec.end ?? 0)) !== undefined) return 'compacted'
    if (present(s, await d.now())) return 'present'
    return undefined
  }
}

/**
 * G3-G14 of the plugin's idle compaction (§2.1), in order: the first that fails is the reason,
 * else the context size the compaction goes by. The `compact` timer and the 55.5-min check's
 * compaction (lane B, D4: one compaction, one rule set) both call it. No G1 and no read of the
 * due record (G1 ran once at the top of `fire`, before the record was cleared). `adoptedOk` is
 * ADOPTED_IDLE_COMPACT (a parameter for its unit test).
 */
export async function compactGuards(d: Deps, sid: string, rec: Due, now: number, env: IdleEnv, adoptedOk = ADOPTED_IDLE_COMPACT): Promise<{ why: string } | Skip | { tokens: number; rule?: string }> {
  const s = d.state
  const no = (why: string) => ({ why })
  // G3: the cache has probably lapsed, or the timer came late (a sleep).
  if (now - rec.due > IDLE_LATE_MS || now - (rec.anchor ?? rec.end ?? rec.due) > IDLE_LAPSE_FRACTION * IDLE_CACHE_MS * scaleOf(env)) return no('lapsed')
  // G3a (D6 a): the prompt prefix changed since the arm, so the cache is cold: another Claude Code
  // version (an adopted load) or another main model (an adopted load, or `/model` in this one,
  // which sends no request and so re-arms nothing). A read that throws counts as changed.
  let cc: string | undefined
  try {
    cc = (await d.version()).version
  } catch {
    cc = undefined
  }
  const model = await d.model()
  if ((rec.cc !== null && rec.cc !== cc) || (rec.model !== null && rec.model !== model)) return no('prefix-changed')
  // A keep-warm ping since the last main request missed the main prefix: the cache is cold (keepwarm.ts).
  if (forkMissed(s, sid)) return no('fork-miss')
  // G3b (D6 b): an adopted load compacts only while the L1-c4 gate allows adopted loads at all.
  if (s.idleAdopted && !adoptedOk) return no('adopted-cold')
  // G4-G7: busy, a newer turn or request, a compaction since the turn end, a person at the prompt.
  if (isBusy(s) || s.nativeCompacting > 0 || s.ownCompact !== undefined) return no('busy')
  if (newerTurn(s, rec)) return no('newer-turn')
  if ((await compactedSince(d, sid, rec.end ?? 0)) !== undefined) return no('compacted')
  if (present(s, now)) return no('present')
  // G8-G14: triggers, the window, the minimum, the cache, the limits, halt, an open question.
  if (!d.cfg.triggers) return no('triggers-off')
  if ((await effective(d, sid)).disabled) return no('small-window')
  const u = await usageOrNone(d)
  const tokens = u?.tokens ?? rec.tokens ?? undefined
  if (tokens === undefined || tokens < compactFloor(d, rec, env)) return no('small')
  if (await ttl5m(d, env, u, rec)) return no('ttl-5m')
  const lim = await compactLimit(d, sid, u, rec, now)
  if ('why' in lim) return lim
  if (s.halt.active && s.halt.reason !== 'cap') return no('halted')
  if (s.askOpen > 0) return no('asks-user')
  return { tokens, ...lim }
}

/** The seconds since the last main turn end, for `handoff_turn_start.gap_s`. */
export async function gapSeconds(d: Deps): Promise<number | null> {
  const t = d.state.lastTurnEndAt
  return t === undefined ? null : Math.round(((await d.now()) - t) / 1000)
}

/** One `submit_dropped {why}` row: a submit site found the session changed (IC-1 D7 (ii)). */
export async function submitDropped(d: Deps, sid: string, site: string): Promise<void> {
  await log(d, sid, 'submit_dropped', { why: 'session-changed', site })
}
