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
//   failure), one `idle_silent` row counts the break, and the handoff turn runs while the cache is
//   still warm. While agents run (native never compacts then) the plugin compacts the main
//   session itself instead (owner 2026-10-27 03:4x "Compact (Recommended)", which replaces
//   xxxxxxxx-38 "Measure more first"). It is armed only while `idle_handoff_turn` is auto.
// - `off`: nothing (a headless load: no plugin turn and, until lane B1, no plugin compaction).
// One `idle_mode {native, plugin_turn, plugin_compact, compact_min?, served_hint?, cache_s?}` row
// whenever that policy changes for a session id; `served_hint` (2b) is Claude Code's cached server
// mode, logged only, never used to decide. The due is persisted (`idle_due:<sid>`, §3.1) with the
// load that holds it: a fire checks once that it still holds it (G1, D14), and every clear writes
// a short-lived tombstone, so a missing record reads as a lost write (`due-missing`), never as a
// takeover. A new load (hot reload, `--resume`, a supervisor move) adopts a record it finds and
// fires it late only within a bound (§3.4). When the turn's checks pass, one plugin-submitted
// handoff turn runs on the D-18 machinery (handoff-turn.ts); no plugin compaction and no continue
// follow it (DP-4; PR-2 P-56 is not reviewed); at most one per idle episode.
import type { Deps, IdleEnv, NativeIdle, Usage } from './deps'
import type { Effective } from './config'
import type { BoundaryResult } from './boundary'
import { boundary } from './boundary'
import { compactedSince, dispatchExists } from './compact'
import { effective } from './config'
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
/** Every rate-limit window must stay below this share (else `near-limit`). */
export const NEAR_LIMIT_PCT = 90
/** A tombstone outlives every timer that could still hold its record (§3.1): its due plus this. */
const TOMBSTONE_LIFE_MS = IDLE_LATE_MS + 60000
/** D15: the windows that show a subscription, so the one-hour main-thread cache. */
const PLAN_WINDOWS: readonly string[] = ['five_hour', 'seven_day']
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
 * `pct` are the context size, the cache (`1h` when a plan window was reported, D15) and the
 * highest window share at arm, which a new process reads before its first request reports any
 * (G10-G12); `cc` and `model` are the Claude Code version and main model at arm (G3a).
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
  ttl: '1h' | '5m' | null; pct: number | null; cc: string | null; model: string | null
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
    ttl: o.ttl === '1h' || o.ttl === '5m' ? o.ttl : null, pct: numOrNull(o.pct), cc: strOrNull(o.cc), model: strOrNull(o.model),
  }
}

/** G1's reading of the store: nothing there (a lost write), a tombstone, or a record. */
function readStored(v: unknown): 'missing' | 'tombstone' | Due {
  if (readTombstone(v)) return 'tombstone'
  return readDue(v) ?? 'missing'
}

const secs = (ms: number): number => Math.round(ms / 1000)

/** D10: the test seam's scale for every cache-derived time (1 without it). */
function scaleOf(env: IdleEnv): number {
  return env.cacheS === undefined ? 1 : env.cacheS / 3600
}

/** One idle skip row, with the timer's kind and, when late, by how much. */
async function idleSkip(d: Deps, sid: string, why: string, kind: IdleKind, lateS?: number): Promise<void> {
  await skipped(d, sid, why, null, 'idle', { kind, ...(lateS !== undefined ? { late_s: lateS } : {}) })
}

/** Cancels the timer (synchronous: safe before any await in a hook). */
export function cancelIdleTimer(d: Deps): void {
  d.state.idleTimer?.cancel()
  d.state.idleTimer = undefined
}

/**
 * Writes a tombstone over the record of `due` (§3.1) and deletes it once every timer that could
 * still hold that record has fired, if it is still this one then (the next arm overwrites it
 * anyway; `loadIdle` deletes an expired one of its own session id).
 */
async function writeTombstone(d: Deps, sid: string, due: number, at?: number): Promise<void> {
  const t: Tombstone = { cancelled: true, sid, load: d.state.loadId, due, at: at ?? (await d.now()) }
  await d.storeSet(dueKey(sid), t)
  d.after(Math.max(0, due + TOMBSTONE_LIFE_MS - t.at), () => {
    void (async () => {
      const v = readTombstone(await d.storeGet(dueKey(sid)))
      if (v && v.load === t.load && v.due === t.due && v.at === t.at) await d.storeDelete(dueKey(sid))
    })().catch(() => undefined)
  })
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

/** Lane A (§3.3): one wait to the due; a wait that fires late meets G3 `lapsed`. */
function schedule(d: Deps, rec: Due, now: number): void {
  cancelIdleTimer(d)
  d.state.idleTimer = d.after(Math.max(0, rec.due - now), () => {
    d.state.idleTimer = undefined
    d.state.inflight = (async () => fire(d, rec, await d.now()))().catch(() => undefined)
  })
}

async function persist(d: Deps, rec: Due): Promise<void> {
  const own: Due = { ...rec, load: d.state.loadId }
  await d.storeSet(dueKey(own.sid), own)
  d.state.idleDueSid = own.sid
  schedule(d, own, await d.now())
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
  const turnOn = d.cfg.idle_handoff_turn === 'auto' && !s.headless
  const compactOn = d.cfg.idle_compact === 'auto' && s.idleCompactOff === undefined && !s.headless
  const live = native === 'on' || native === 'unknown'
  const pluginTurn = live ? (turnOn ? 'check' : 'off') : turnOn ? 'on' : 'off'
  const pluginCompact = native === 'vetoed' ? (compactOn ? 'on' : (s.idleCompactOff ?? 'off')) : pluginTurn === 'check' ? 'agents' : 'off'
  const served = pluginTurn === 'check' ? await d.servedHint() : undefined
  const fields = {
    native, plugin_turn: pluginTurn, plugin_compact: pluginCompact,
    ...(pluginCompact === 'on' || pluginCompact === 'agents' ? { compact_min: env.compactMin } : {}),
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

/** §1.2: the kind a turn end at this context size arms. Tokens cannot grow without a main turn. */
function pickKind(p: Policy, tokens: number | undefined): IdleKind | 'off' {
  if (p.native === 'on' || p.native === 'unknown') return p.turnOn ? 'check' : 'off'
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
  if (kind === 'compact') {
    try {
      cc = (await d.version()).version
    } catch {
      cc = null
    }
    model = (await d.model()) ?? null
  }
  const limits = u?.rateLimits ?? []
  s.idleAdopted = false
  await persist(d, {
    due, sid, episode: s.idleEpisode ?? null, kind, end: endAt, answer: s.lastTurnAnswer, published: s.publishedSinceHuman,
    load: s.loadId, anchor, tokens: u?.tokens ?? null, ttl: u === undefined ? null : planOf(u).length > 0 ? '1h' : '5m',
    pct: limits.length > 0 ? Math.max(...limits.map(l => l.percentUsed)) : null, cc, model,
  })
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
  return rec.end !== null && now <= rec.end + IDLE_CHECK_MS * scale
}

/**
 * Once per load (AT-IC-14, §3.4): the persisted due of this sid is adopted (written back with this
 * load's id, so a timer of the process it came from finds it held elsewhere) and armed again; one
 * whose due passed fires at once within its late-fire bound, else it writes one `lapsed` row and
 * is cleared. A legacy record (no turn end) past its due, another sid's and a tombstone are
 * ignored; an expired tombstone of this sid is deleted.
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
  const own: Due = { ...rec, load: s.loadId }
  await d.storeSet(dueKey(sid), own)
  s.idleDueSid = sid
  schedule(d, own, now)
}

type Go = { tokens: number; allowance: number; native: number; calls: number }

type Use = { tokens: number | undefined; rateLimits: Usage['rateLimits'] } | undefined

/**
 * D15 / G11: no one-hour cache. A prompt-caching switch is set, or the usage reports no plan
 * window. A load that adopted the record has made no request of its own yet (the usage reports
 * none before the first response), so it goes by the record's reading at arm.
 */
function ttl5m(d: Deps, env: IdleEnv, u: Use, rec: Due): boolean {
  if (env.cacheOff) return true
  if (planOf(u).length > 0) return false
  return !(d.state.idleAdopted && rec.ttl === '1h')
}

/** G12: a window at the limit share or more (any kind, a gateway's too); none reported: the record's reading. */
function nearLimit(u: Use, rec: Due): boolean {
  const limits = u?.rateLimits ?? []
  if (limits.length > 0) return limits.some(l => !(l.percentUsed < NEAR_LIMIT_PCT))
  return rec.pct !== null && rec.pct >= NEAR_LIMIT_PCT
}

/** The checks of §9.4 "Fire" from `aborted` on, in order; the first that fails is the skip reason. */
async function laterChecks(d: Deps, sid: string, eff: Effective, u: Use, rec: Due): Promise<string | Go> {
  const s = d.state
  if (!s.lastTurnAnswer) return 'aborted'
  const tokens = u?.tokens ?? rec.tokens ?? undefined
  if (tokens === undefined || tokens < d.cfg.idle_handoff_min_tokens) return 'small'
  if (ttl5m(d, await d.idleEnv(), u, rec)) return 'ttl-5m'
  if (nearLimit(u, rec)) return 'near-limit'
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

function isBusy(s: Deps['state']): boolean {
  return s.mainTurnRunning || s.foreignPrompts > 0 || s.busy || s.handoffTurn !== undefined || s.ourSubmitPending
}

async function usageOrNone(d: Deps): Promise<Use> {
  try {
    return await d.usage()
  } catch {
    return undefined
  }
}

/**
 * The agents of this session still running (owner xxxxxxxx-38; the 2026-10-27 idle compaction):
 * the listed subagents and teammates that have not ended, with the agent loops whose turn is
 * running in this load (a workflow's agents are not listed).
 */
export async function agentsRunning(d: Deps): Promise<number> {
  const ids = new Set<string>(d.state.agentTurns)
  for (const id of (await d.agentsAlive()) ?? []) ids.add(id)
  return ids.size
}

/** The 49-min turn: the checks of §9.4 "Fire", in order (the session id is G2's, in `fire`). */
async function turnBlocked(d: Deps, sid: string, rec: Due): Promise<string | Go> {
  if (!d.cfg.triggers) return 'triggers-off'
  const eff = await effective(d, sid)
  if (eff.disabled) return 'small-window'
  if (isBusy(d.state)) return 'busy'
  return laterChecks(d, sid, eff, await usageOrNone(d), rec)
}

/** The plugin's own idle compaction while agents run (owner 2026-10-27): its `idle_compact` row. */
type Compact = { compact: true; gapS: number; tokens: number; agents: number }

/**
 * Owner 2026-10-27 03:4x ("Compact (Recommended)", replaces xxxxxxxx-38 "Measure more first"):
 * native idle compaction does not run while agents run (EXPERIMENT-RESULTS §11), so the check
 * compacts itself, as native would have: `triggers` on, a window large enough for plugin
 * compactions, a context at Claude Code's idle floor or more (below it native would not compact
 * either), not in halt mode (no plugin compactions there) and no question open.
 */
async function compactBlocked(d: Deps, sid: string, u: Use): Promise<string | undefined> {
  if (!d.cfg.triggers) return 'triggers-off'
  if ((await effective(d, sid)).disabled) return 'small-window'
  if (u?.tokens === undefined || u.tokens < NATIVE_IDLE_FLOOR) return 'small'
  if (d.state.halt.active) return 'halted'
  if (d.state.askOpen > 0) return 'asks-user'
  return undefined
}

/**
 * Owner xxxxxxxx-17: the 55.5-min outcome check. A check that fires more than a minute late is
 * `lapsed` (§3.4). A main compaction since the turn end stands down (`native-fired` for an idle
 * one, else `compacted`); a busy session is no idle break. Otherwise native stayed silent: one
 * `idle_silent` row at 200K and more, then, while agents run, the plugin's own idle compaction
 * (owner 2026-10-27) or its skip reason; else the checks of the turn.
 */
async function checkBlocked(d: Deps, sid: string, rec: Due, now: number, scale: number): Promise<string | Go | Compact> {
  if (d.cfg.idle_handoff_turn !== 'auto' || d.state.headless) return 'disabled'
  if (now - rec.due > IDLE_LATE_MS) return 'lapsed'
  const end = rec.end
  const c = end === null ? undefined : await compactedSince(d, sid, end)
  if (c !== undefined) return c.idle ? 'native-fired' : 'compacted'
  // A compaction other than ours still running (a slow summary call) is not silence either.
  if (isBusy(d.state) || d.state.nativeCompacting > 0) return 'busy'
  const u = await usageOrNone(d)
  const agents = await agentsRunning(d)
  const gap = end === null ? null : Math.round(((await d.now()) - end) / 1000)
  if (u?.tokens !== undefined && u.tokens >= NATIVE_IDLE_FLOOR) {
    const served = await d.servedHint()
    await log(d, sid, 'idle_silent', { gap_s: gap, tokens: u.tokens, agents, ...(served !== undefined ? { served_hint: served } : {}) })
  }
  if (agents > 0) {
    const why = await compactBlocked(d, sid, u)
    if (why !== undefined) return why
    // compactBlocked found the tokens; the gap is the timer's own (about 3,330 s) when unknown.
    return { compact: true, gapS: gap ?? Math.round((IDLE_CHECK_MS * scale) / 1000), tokens: u?.tokens ?? 0, agents }
  }
  if (!d.cfg.triggers) return 'triggers-off'
  const eff = await effective(d, sid)
  if (eff.disabled) return 'small-window'
  return laterChecks(d, sid, eff, u, rec)
}

/** `boundary()` for an idle compaction; a throw is a failed attempt (`error`). */
async function idleBoundary(d: Deps, opts: Parameters<typeof boundary>[1]): Promise<BoundaryResult> {
  try {
    return await boundary(d, opts)
  } catch {
    return { ran: true, ok: false, failClass: 'error' }
  }
}

/**
 * D7: a success resets the count of failed idle compactions; a failure of a counted class adds
 * one, and the second in a row turns the plugin's idle compaction off for the load (one
 * `idle_compact_off` row; the 49-min turn path takes over at the next turn end).
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
 * The timer fired (D14, §2.1 fire order). G1 once, first: a record another load holds (a later
 * armer or adopter, or a tombstone) leaves nothing to do here and no row, since the load that
 * holds it writes that episode's row; a record lost to a store write is `due-missing` (one row,
 * `lapsed` when the fire is also late). Then the record is cleared with a tombstone, G2 (the
 * session changed), and the path of the kind. Two processes that read it in the same moment can
 * both go on (the store has no compare-and-set).
 */
export async function fire(d: Deps, rec: Due, now: number): Promise<void> {
  const s = d.state
  const sid = rec.sid
  const stored = readStored(await d.storeGet(dueKey(sid)))
  if (stored === 'tombstone' || (stored !== 'missing' && (stored.load !== s.loadId || stored.due !== rec.due))) return
  if (s.idleDueSid === sid) s.idleDueSid = undefined
  if (stored === 'missing') {
    const late = now - rec.due > IDLE_LATE_MS
    await idleSkip(d, sid, late ? 'lapsed' : 'due-missing', rec.kind, late ? secs(now - rec.due) : undefined)
    return
  }
  await writeTombstone(d, sid, rec.due, now)
  if ((await d.sessionId()) !== sid) {
    await idleSkip(d, sid, 'session-changed', rec.kind)
    return
  }
  if (rec.kind === 'compact') {
    await fireCompact(d, rec, now)
    return
  }
  // The check reads its policy as armed (no `idle_mode` row at its fire); the turn reads it again.
  const scale = scaleOf(await d.idleEnv())
  if (rec.kind === 'turn') {
    // A 49-min turn that finds native idle on or unreadable now logs `native-on` / `native-unknown`
    // and checks the outcome at 55.5 min instead (owner xxxxxxxx-17).
    const p = await policy(d, sid)
    if (!p.turnOn) {
      await idleSkip(d, sid, 'disabled', 'turn')
      return
    }
    if (p.native === 'on' || p.native === 'unknown') {
      await idleSkip(d, sid, p.native === 'on' ? 'native-on' : 'native-unknown', 'turn')
      await rearmCheck(d, rec, now, scale)
      return
    }
    // §3.4: a turn starting after minute 55.5 (a late timer, a sleep) is lapsed.
    if (rec.end !== null && now > rec.end + IDLE_CHECK_MS * scale) {
      await idleSkip(d, sid, 'lapsed', 'turn', secs(now - rec.due))
      return
    }
  }
  const b = rec.kind === 'check' ? await checkBlocked(d, sid, rec, now, scale) : await turnBlocked(d, sid, rec)
  if (typeof b === 'string') {
    await idleSkip(d, sid, b, rec.kind, b === 'lapsed' ? secs(now - rec.due) : undefined)
    return
  }
  if ('compact' in b) {
    // Owner 2026-10-27: one shaped compaction instead of the turn. A rejection (a turn started,
    // or a headless host that cannot compact between turns) is one `compact_rejected` row from
    // boundary(), never retried: the next check comes only after another main turn end. A
    // refusal before the compaction is one skip row (D13).
    await log(d, sid, 'idle_compact', {
      gap_s: b.gapS, tokens: b.tokens, agents: b.agents, at: 'check', late_s: Math.max(0, secs(now - rec.due)), adopted: s.idleAdopted,
    })
    const r = await idleBoundary(d, { idle: { gapS: b.gapS } })
    if (!r.ran) await idleSkip(d, sid, r.why, 'check')
    return
  }
  const h = newTurn('idle', b.tokens, b.allowance, b.native, b.calls)
  if (rec.kind === 'check') h.idleMin = IDLE_CHECK_MIN_TEXT
  s.handoffTurn = h
  const ok = await openAndSubmit(d, sid, h, n => dispatchExists(d, sid, n))
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
 * check is armed for the same turn end, when that is still ahead and the check is on at all.
 */
async function rearmCheck(d: Deps, rec: Due, now: number, scale: number): Promise<void> {
  const end = rec.end
  if (end === null || end + IDLE_CHECK_MS * scale <= now) return
  await persist(d, { ...rec, due: end + IDLE_CHECK_MS * scale, kind: 'check', episode: d.state.idleEpisode ?? null, answer: d.state.lastTurnAnswer, published: d.state.publishedSinceHuman })
}

/**
 * The plugin's own idle compaction (kind `compact`, §2.1): after G1 and G2, G0a-G0c here, then
 * `compactGuards`; the first that fails is the one skip row (`handoff_skipped {why, reason: idle,
 * kind: compact, late_s?}`); then one `idle_compact` row and the compaction (boundary.ts, exempt
 * from halt for the auto-continue cap, D5), whose refusal is one more skip row (D13) and whose
 * failure counts for D7.
 */
async function fireCompact(d: Deps, rec: Due, now: number): Promise<void> {
  const s = d.state
  const sid = rec.sid
  const p = await policy(d, sid)
  const lateS = secs(now - rec.due)
  const skip = (why: string): Promise<void> => idleSkip(d, sid, why, 'compact', lateS > 0 || why === 'lapsed' ? lateS : undefined)
  // G0a: native came back on (or unreadable): the outcome check for the same turn end.
  if (p.native === 'on' || p.native === 'unknown') {
    await skip(p.native === 'on' ? 'native-on' : 'native-unknown')
    if (p.turnOn) await rearmCheck(d, rec, now, scaleOf(p.env))
    return
  }
  // G0b, G0c: automatic compaction switched off; the plugin's idle compaction off (the option,
  // D7, or a headless load: lane A has no headless path).
  if (p.native === 'compaction-off') return skip('compaction-off')
  if (!p.compactOn) return skip('disabled')
  const g = await compactGuards(d, sid, rec, now, p.env)
  if ('why' in g) return skip(g.why)
  const agents = await agentsRunning(d)
  const gapS = secs(now - (rec.end ?? now))
  await log(d, sid, 'idle_compact', { gap_s: gapS, tokens: g.tokens, agents, at: 'timer', late_s: Math.max(0, lateS), adopted: s.idleAdopted })
  const r = await idleBoundary(d, { idle: { gapS }, exemptHalt: s.halt.active && s.halt.reason === 'cap' })
  if (!r.ran) {
    await skip(r.why)
    return
  }
  await countIdleCompact(d, sid, r)
}

/**
 * G3-G14 of the plugin's idle compaction (§2.1), in order: the first that fails is the reason,
 * else the context size the compaction goes by. No G1 and no read of the due record (G1 ran once
 * at the top of `fire`, before the record was cleared). `adoptedOk` is ADOPTED_IDLE_COMPACT (a
 * parameter for its unit test).
 */
export async function compactGuards(d: Deps, sid: string, rec: Due, now: number, env: IdleEnv, adoptedOk = ADOPTED_IDLE_COMPACT): Promise<{ why: string } | { tokens: number }> {
  const s = d.state
  const no = (why: string) => ({ why })
  // G3: the cache has probably lapsed, or the timer came late (a sleep).
  if (now - rec.due > IDLE_LATE_MS || now - (rec.anchor ?? rec.end ?? rec.due) > IDLE_LAPSE_FRACTION * IDLE_CACHE_MS * scaleOf(env)) return no('lapsed')
  // G3a, G3b (D6): an adopted load compacts only on the same version and model, and only while
  // the L1-c4 gate allows adopted loads at all. A read that throws counts as changed.
  if (s.idleAdopted) {
    let cc: string | undefined
    try {
      cc = (await d.version()).version
    } catch {
      cc = undefined
    }
    const model = await d.model()
    if ((rec.cc !== null && rec.cc !== cc) || (rec.model !== null && rec.model !== model)) return no('prefix-changed')
    if (!adoptedOk) return no('adopted-cold')
  }
  // G4-G7: busy, a newer turn or request, a compaction since the turn end, a person at the prompt.
  if (isBusy(s) || s.nativeCompacting > 0 || s.ownCompact !== undefined) return no('busy')
  const end = rec.end ?? 0
  if ((s.lastTurnEndAt ?? 0) > end || (s.lastMainReqAt ?? 0) > (rec.anchor ?? end)) return no('newer-turn')
  if ((await compactedSince(d, sid, end)) !== undefined) return no('compacted')
  if (s.lastInputAt !== undefined && now - s.lastInputAt < IDLE_PRESENT_MS) return no('present')
  // G8-G14: triggers, the window, the minimum, the cache, the limits, halt, an open question.
  if (!d.cfg.triggers) return no('triggers-off')
  if ((await effective(d, sid)).disabled) return no('small-window')
  const u = await usageOrNone(d)
  const tokens = u?.tokens ?? rec.tokens ?? undefined
  if (tokens === undefined || tokens < env.compactMin) return no('small')
  if (ttl5m(d, env, u, rec)) return no('ttl-5m')
  if (nearLimit(u, rec)) return no('near-limit')
  if (s.halt.active && s.halt.reason !== 'cap') return no('halted')
  if (s.askOpen > 0) return no('asks-user')
  return { tokens }
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
